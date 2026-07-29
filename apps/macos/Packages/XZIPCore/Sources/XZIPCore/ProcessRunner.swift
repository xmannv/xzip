import Darwin
import Foundation
import XZIPDomain

/// Result of a finished subprocess.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let wasTerminatedByRequest: Bool

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        wasTerminatedByRequest: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.wasTerminatedByRequest = wasTerminatedByRequest
    }

    public var isSuccess: Bool { exitCode == 0 }
}

/// A line emitted by a running subprocess, tagged by stream.
public enum ProcessOutputLine: Sendable {
    case stdout(String)
    case stderr(String)
}


public enum ProcessOutputChunk: Sendable {
    case stdout(Data)
    case stderr(Data)
}

/// Errors raised while running a subprocess.
public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case nonZeroExit(code: Int32, standardError: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch process: \(msg)"
        case .nonZeroExit(let code, let err):
            return "Process exited with code \(code): \(err)"
        case .cancelled: return "Operation was cancelled."
        }
    }
}

/// Abstraction over subprocess execution.
///
/// Design: protocol (Strategy) so engines depend on an interface, not on
/// `Foundation.Process`. Tests can supply a fake runner that returns canned
/// output without spawning real processes.
public protocol ProcessRunning: Sendable {
    /// Run to completion, buffering all output.
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult

    /// Run to completion, feeding `standardInput` (if any) to the process's
    /// stdin. Used by tools that read from stdin (e.g. `zip -z` for comments).
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult

    /// Run while streaming output lines as they are produced. The stream
    /// finishes when the process exits; the terminal `ProcessResult` is
    /// returned once the stream is fully consumed. `standardInput`, if given, is
    /// written to the process's stdin and the pipe is then closed — used to feed
    /// 7-Zip a password interactively (via its `Enter password:` prompt) instead
    /// of exposing it in argv where `ps` could read it.
    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error>

    /// Run while preserving stdout and stderr as unmodified byte chunks.
    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error>
}

public extension ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    /// Default: ignore stdin. Concrete runners that support piping override this.
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: String?
    ) async throws -> ProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    /// Convenience: stream without feeding stdin.
    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        runStreaming(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: nil
        )
    }

    /// Convenience: raw stream without feeding stdin.
    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        runRawStreaming(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: nil
        )
    }
}

/// Concrete runner backed by `Foundation.Process`.
///
/// Notes on security: arguments are passed as an array (never shell-interpreted),
/// which prevents command injection. Callers must still be mindful that some
/// tools (e.g. 7-Zip) expose passwords via argv; see `SevenZipEngine`.
extension ProcessControlling {
    func runBuffered(_ request: ProcessRequest) async throws -> ProcessResult {
        let stream = run(request)
        for try await event in stream {
            try Task.checkCancellation()
            if case .terminated(let result) = event {
                return result
            }
        }
        throw ProcessRunnerError.launchFailed(
            "Process stream ended without a terminal result."
        )
    }

    func runRawStreaming(
        _ request: ProcessRequest
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        let adapter = LegacyRawProcessAdapterState(stream: run(request))
        return AsyncThrowingStream(unfolding: {
            try await adapter.next()
        })
    }

    func runLineStreaming(
        _ request: ProcessRequest
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        let stream = run(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stdoutReader = LineReader { line in
                    continuation.yield(.stdout(line))
                }
                let stderrReader = LineReader { line in
                    continuation.yield(.stderr(line))
                }

                do {
                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .stdout(let data):
                            stdoutReader.feed(data)
                        case .stderr(let data):
                            stderrReader.feed(data)
                        case .terminated(let result):
                            stdoutReader.flush()
                            stderrReader.flush()
                            if result.isSuccess {
                                continuation.finish()
                            } else {
                                continuation.finish(throwing: ProcessRunnerError.nonZeroExit(
                                    code: result.exitCode,
                                    standardError: result.standardError
                                ))
                            }
                            return
                        }
                    }
                    continuation.finish(throwing: ProcessRunnerError.launchFailed(
                        "Process stream ended without a terminal result."
                    ))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    task.cancel()
                    stream.cancel()
                }
            }
        }
    }
}

extension ProcessRequest {
    init(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        workload: ProcessWorkload
    ) {
        self.init(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput.map { Data($0.utf8) },
            workload: workload
        )
    }
}

func processVolumeIDs(for urls: [URL]) -> Set<UInt64> {
    Set(urls.compactMap { url in
        var candidate = url.standardizedFileURL
        while true {
            var info = stat()
            let status = candidate.path.withCString { path in
                fstatat(AT_FDCWD, path, &info, 0)
            }
            if status == 0 {
                return volumeIdentifierBitPattern(for: info.st_dev)
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    })
}

public struct FoundationProcessRunner: ProcessRunning, ProcessControlling {
    private let controller: any ProcessControlling

    public init() {
        self.controller = ProcessController(
            policy: .legacyRawProcess,
            permits: LocalProcessPermitPool(limit: 1)
        )
    }

    public init(controller: any ProcessControlling) {
        self.controller = controller
    }

    public func run(_ request: ProcessRequest) -> ProcessOutputStream {
        controller.run(request)
    }

    public func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: nil
        )
    }

    public func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try await controller.runBuffered(ProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput.map { Data($0.utf8) },
            workload: .metadata(volumeIDs: [])
        ))
    }

    public func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        controller.runLineStreaming(ProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput.map { Data($0.utf8) },
            workload: .metadata(volumeIDs: [])
        ))
    }

    public func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        controller.runRawStreaming(ProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput.map { Data($0.utf8) },
            workload: .metadata(volumeIDs: [])
        ))
    }
}

private final class LegacyRawProcessAdapterState: @unchecked Sendable {
    private let stream: ProcessOutputStream
    private let stderrTail = BoundedDataTail(limit: 65_536)

    init(stream: ProcessOutputStream) {
        self.stream = stream
    }

    deinit {
        stream.cancel()
    }

    func next() async throws -> ProcessOutputChunk? {
        while let event = try await stream.nextForLegacyAdapter() {
            switch event {
            case .stdout(let data):
                return .stdout(data)
            case .stderr(let data):
                stderrTail.append(data)
                return .stderr(data)
            case .terminated(let result):
                if result.isSuccess { return nil }
                throw ProcessRunnerError.nonZeroExit(
                    code: result.exitCode,
                    standardError: stderrTail.string()
                )
            }
        }
        throw ProcessRunnerError.launchFailed(
            "Process stream ended without a terminal result."
        )
    }

}

private extension ArchiveResourcePolicy {
    static let legacyRawProcess: ArchiveResourcePolicy = {
        let base = ArchiveResourcePolicy.production
        return ArchiveResourcePolicy(
            listing: base.listing,
            output: base.output,
            process: ArchiveResourcePolicy.Process(
                stdoutBufferByteCap: base.process.stdoutBufferByteCap,
                stderrTailByteCap: base.process.stderrTailByteCap,
                rawChunkByteCap: base.process.rawChunkByteCap,
                progressEventBufferCount: base.process.progressEventBufferCount,
                progressInterval: base.process.progressInterval,
                terminationGracePeriod: 0.25
            ),
            cache: base.cache,
            split: base.split,
            command: base.command,
            journal: base.journal,
            scheduling: base.scheduling
        )
    }()
}


/// Pull-driven bridge from process pipes to `AsyncThrowingStream`.
/// Each `next()` arms one fixed-size read per pipe, so unread output remains in
/// the OS pipes and backpressures the child instead of growing an in-memory queue.



/// Splits an incoming byte stream into lines, handling both `\n` and `\r`
/// so progress updates (which use `\r`) are emitted promptly.
/// Splits a byte stream into logical segments. Splits on \n, \r AND
/// backspace (0x08): when writing to a pipe, 7zz redraws its progress line
/// using backspace runs — with no \r at all — so backspaces are the only
/// incremental boundary available while an operation runs.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    // Count of leading bytes already scanned in which no delimiter was found, so
    // the next feed resumes from here instead of re-scanning the whole buffer
    // (which made a long delimiter-free run O(n²)).
    private var scanned = 0
    private let onLine: (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")
        let backspace: UInt8 = 0x08
        // Single forward pass over only the not-yet-scanned bytes; emit each
        // segment as a slice and drop all consumed bytes in ONE removeSubrange
        // at the end (the old code did a front removeSubrange per delimiter,
        // memmoving the tail every time).
        let count = buffer.count
        var lineStart = 0
        var i = scanned
        while i < count {
            let byte = buffer[i]
            if byte == newline || byte == carriage || byte == backspace {
                if i > lineStart {
                    onLine(String(decoding: buffer[lineStart..<i], as: UTF8.self))
                }
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart > 0 {
            buffer.removeSubrange(0..<lineStart)
        }
        // The surviving tail (from the last delimiter onward) is delimiter-free
        // and now fully scanned.
        scanned = buffer.count
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        scanned = 0
    }
}

/// Mutable box to collect pipe data across a dispatch group boundary.
private final class UnsafeDataBox: @unchecked Sendable {
    var value = Data()
}

/// Thread-safe one-shot cancellation flag shared between a run's cancellation
/// handler and its launch/termination code, so a cancel that arrives before or
/// during `process.run()` is not lost (which would otherwise leave the child
/// running to completion and report success instead of cancellation).
