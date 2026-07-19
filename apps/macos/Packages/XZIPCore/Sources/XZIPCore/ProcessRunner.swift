import Darwin
import Foundation

/// Result of a finished subprocess.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

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
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Cancelled before we start: resume now WITHOUT spinning up the
                // pipe readers. The child never runs, so its pipe write-ends never
                // close and a blocking readDataToEndOfFile would hang the reader
                // thread (and the Pipe it retains) forever.
                if cancelFlag.isCancelled {
                    continuation.resume(throwing: ProcessRunnerError.cancelled)
                    return
                }
                // Read pipes concurrently to avoid deadlock on large output.
                let outData = UnsafeDataBox()
                let errData = UnsafeDataBox()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    outData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.terminationHandler = { proc in
                    group.wait()
                    // A process we terminated in response to cancellation must
                    // surface as `.cancelled`, not as a spurious non-zero-exit
                    // "7-Zip failed" error.
                    if cancelFlag.isCancelled {
                        continuation.resume(throwing: ProcessRunnerError.cancelled)
                        return
                    }
                    let out = String(decoding: outData.value, as: UTF8.self)
                    let err = String(decoding: errData.value, as: UTF8.self)
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            standardOutput: out,
                            standardError: err
                        )
                    )
                }

                do {
                    try process.run()
                    // Cancel that raced in during launch: terminate now so the
                    // termination handler reports `.cancelled` (the readers get
                    // EOF once the process is terminated, so nothing leaks).
                    if cancelFlag.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            cancelFlag.cancel()
            // `terminate()` on a process that never launched (cancelled before
            // `process.run()`) raises NSInvalidArgumentException, crashing the app.
            if process.isRunning { process.terminate() }
        }
    }

    public func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if standardInput != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        }

        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Cancelled before we start: resume without spinning up the pipe
                // readers, which would otherwise block forever (see the buffered
                // overload above).
                if cancelFlag.isCancelled {
                    continuation.resume(throwing: ProcessRunnerError.cancelled)
                    return
                }
                let outData = UnsafeDataBox()
                let errData = UnsafeDataBox()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    outData.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.terminationHandler = { proc in
                    group.wait()
                    if cancelFlag.isCancelled {
                        continuation.resume(throwing: ProcessRunnerError.cancelled)
                        return
                    }
                    let out = String(decoding: outData.value, as: UTF8.self)
                    let err = String(decoding: errData.value, as: UTF8.self)
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            standardOutput: out,
                            standardError: err
                        )
                    )
                }

                do {
                    try process.run()
                    if let input = standardInput, let stdinPipe {
                        let handle = stdinPipe.fileHandleForWriting
                        // The throwing `write(contentsOf:)` turns a broken pipe
                        // (process exited early, e.g. `zip -z` on bad input) into
                        // a catchable error instead of an uncatchable SIGPIPE/ObjC
                        // exception that would crash the app.
                        try? handle.write(contentsOf: Data(input.utf8))
                        try? handle.close()
                    }
                    if cancelFlag.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            cancelFlag.cancel()
            // `terminate()` on a process that never launched (cancelled before
            // `process.run()`) raises NSInvalidArgumentException, crashing the app.
            if process.isRunning { process.terminate() }
        }
    }

    public func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory { process.currentDirectoryURL = workingDirectory }
            if let environment { process.environment = environment }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Feed a password to 7-Zip's `Enter password:` prompt via stdin so it
            // never appears in argv. Always attach a stdin pipe when caller passed
            // a value (even ""): closing it sends EOF, which 7zz treats as an
            // empty password and fails fast instead of blocking on the prompt.
            var stdinPipe: Pipe?
            if standardInput != nil {
                let p = Pipe()
                process.standardInput = p
                stdinPipe = p
            }

            // 7zz redraws its progress line with backspaces when piped (no
            // carriage returns at all), so LineReader also splits on 0x08 to
            // surface incremental progress. See LineReaderTests.
            let stdoutReader = LineReader { line in
                continuation.yield(.stdout(line))
            }
            let stderrReader = LineReader { line in
                continuation.yield(.stderr(line))
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutReader.feed(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrReader.feed(data)
                }
            }

            process.terminationHandler = { proc in
                // Drain whatever is still buffered in the pipes before finishing.
                // The readabilityHandler races with termination, so the tail of
                // the output (e.g. 7zz's "Wrong password" stderr line) can be lost
                // if we finish without reading the remainder — which would map a
                // password error to a generic failure.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailOut.isEmpty { stdoutReader.feed(tailOut) }
                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailErr.isEmpty { stderrReader.feed(tailErr) }
                stdoutReader.flush()
                stderrReader.flush()
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(
                        throwing: ProcessRunnerError.nonZeroExit(
                            code: proc.terminationStatus,
                            standardError: ""
                        )
                    )
                }
            }

            let cancelFlag = CancelFlag()
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    cancelFlag.cancel()
                    if process.isRunning { process.terminate() }
                }
            }

            // Cancelled before launch: don't start an orphan that would run to
            // completion after the consumer has already stopped listening.
            if cancelFlag.isCancelled {
                continuation.finish(throwing: ProcessRunnerError.cancelled)
                return
            }
            do {
                try process.run()
                if let input = standardInput, let stdinPipe {
                    let handle = stdinPipe.fileHandleForWriting
                    // Throwing write turns a broken pipe (7zz didn't need a
                    // password / exited early) into a caught no-op instead of a
                    // SIGPIPE crash. Closing sends EOF.
                    try? handle.write(contentsOf: Data(input.utf8))
                    try? handle.close()
                }
                if cancelFlag.isCancelled, process.isRunning { process.terminate() }
            } catch {
                continuation.finish(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
            }
        }
    }


    public func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        let state = RawProcessStreamState(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading
        )
        state.start(
            standardInput: standardInput,
            stdinHandle: stdinPipe?.fileHandleForWriting,
            stdoutWriteHandle: stdoutPipe.fileHandleForWriting,
            stderrWriteHandle: stderrPipe.fileHandleForWriting
        )

        return AsyncThrowingStream(unfolding: {
            try await state.next()
        })
    }
}


/// Pull-driven bridge from process pipes to `AsyncThrowingStream`.
/// Each `next()` arms one fixed-size read per pipe, so unread output remains in
/// the OS pipes and backpressures the child instead of growing an in-memory queue.

private final class RawProcessStreamState: @unchecked Sendable {
    private enum Channel: Sendable {
        case stdout
        case stderr
    }

    private typealias NextContinuation = CheckedContinuation<ProcessOutputChunk?, Error>
    private typealias NextResult = Result<ProcessOutputChunk?, Error>

    private static let chunkSize = 64 * 1024

    private let process: Process
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let cancelFlag = CancelFlag()
    private let stderrTail = BoundedDataTail(limit: 65_536)
    private let lock = NSLock()

    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutArmed = false
    private var stderrArmed = false
    private var stdoutPending: Data?
    private var stderrPending: Data?
    private var readyChannels: [Channel] = []
    private var waiter: NextContinuation?
    private var terminationStatus: Int32?
    private var streamError: Error?
    private var stdinHandle: FileHandle?
    private var terminationEscalationScheduled = false
    private var isClosed = false

    init(
        process: Process,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    deinit {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle?.close()
        terminateProcessIfNeeded()
    }

    func start(
        standardInput: String?,
        stdinHandle: FileHandle?,
        stdoutWriteHandle: FileHandle,
        stderrWriteHandle: FileHandle
    ) {
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        if Task.isCancelled {
            cancel()
            try? stdinHandle?.close()
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            return
        }

        do {
            try process.run()
            if let standardInput, let stdinHandle {
                _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
                lock.lock()
                self.stdinHandle = stdinHandle
                lock.unlock()

                // The child may fill stdout before reading stdin. Write off the
                // caller thread so the consumer can start draining output.
                let input = Data(standardInput.utf8)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    try? stdinHandle.write(contentsOf: input)
                    try? stdinHandle.close()
                    self?.stdinDidClose(stdinHandle)
                }
            }
            if Task.isCancelled { cancel() }
        } catch {
            try? stdinHandle?.close()
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            recordStreamError(
                Task.isCancelled
                    ? ProcessRunnerError.cancelled
                    : ProcessRunnerError.launchFailed(error.localizedDescription)
            )
        }
    }


    private func stdinDidClose(_ handle: FileHandle) {
        lock.lock()
        if stdinHandle === handle {
            stdinHandle = nil
        }
        lock.unlock()
    }

    func next() async throws -> ProcessOutputChunk? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        cancelFlag.cancel()

        let waiting: NextContinuation?
        lock.lock()
        waiting = waiter
        waiter = nil
        readyChannels.removeAll(keepingCapacity: false)
        stdoutPending = nil
        stderrPending = nil
        closeLocked()
        lock.unlock()

        terminateProcessIfNeeded()
        waiting?.resume(throwing: ProcessRunnerError.cancelled)
    }

    private func register(_ continuation: NextContinuation) {
        let immediate: NextResult?

        lock.lock()
        if cancelFlag.isCancelled {
            immediate = .failure(ProcessRunnerError.cancelled)
        } else if let chunk = popPendingLocked() {
            immediate = .success(chunk)
        } else if let terminal = terminalResultLocked() {
            closeLocked()
            immediate = terminal
        } else if isClosed {
            immediate = .success(nil)
        } else {
            precondition(waiter == nil, "Concurrent raw stream iteration is unsupported")
            waiter = continuation
            armReadsLocked()
            immediate = nil
        }
        lock.unlock()

        if let immediate {
            continuation.resume(with: immediate)
        }
    }

    private func armReadsLocked() {
        guard waiter != nil, !isClosed else { return }

        if !stdoutEOF, stdoutPending == nil, !stdoutArmed {
            stdoutArmed = true
            stdoutHandle.readabilityHandler = { [weak self] handle in
                self?.handleReadable(.stdout, from: handle)
            }
        }
        if !stderrEOF, stderrPending == nil, !stderrArmed {
            stderrArmed = true
            stderrHandle.readabilityHandler = { [weak self] handle in
                self?.handleReadable(.stderr, from: handle)
            }
        }
    }

    private func handleReadable(_ channel: Channel, from handle: FileHandle) {
        lock.lock()
        guard !isClosed, isArmedLocked(channel) else {
            lock.unlock()
            return
        }
        setArmedLocked(channel, false)
        handle.readabilityHandler = nil
        lock.unlock()

        do {
            guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else {
                reachedEOF(channel)
                return
            }
            received(data, from: channel)
        } catch {
            recordStreamError(error)
        }
    }

    private func received(_ data: Data, from channel: Channel) {
        let waiting: NextContinuation?
        let chunk: ProcessOutputChunk

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }

        switch channel {
        case .stdout:
            chunk = .stdout(data)
        case .stderr:
            stderrTail.append(data)
            chunk = .stderr(data)
        }

        if let current = waiter {
            waiter = nil
            waiting = current
        } else {
            setPendingLocked(data, for: channel)
            readyChannels.append(channel)
            waiting = nil
        }
        lock.unlock()

        waiting?.resume(returning: chunk)
    }

    private func reachedEOF(_ channel: Channel) {
        let completion: (NextContinuation, NextResult)?

        lock.lock()
        switch channel {
        case .stdout: stdoutEOF = true
        case .stderr: stderrEOF = true
        }
        completion = takeTerminalWaiterLocked()
        lock.unlock()

        if let completion {
            completion.0.resume(with: completion.1)
        }
    }

    private func processDidTerminate(status: Int32) {
        let completion: (NextContinuation, NextResult)?

        lock.lock()
        terminationStatus = status
        completion = takeTerminalWaiterLocked()
        lock.unlock()

        if let completion {
            completion.0.resume(with: completion.1)
        }
    }

    private func recordStreamError(_ error: Error) {
        let waiting: NextContinuation?

        lock.lock()
        guard streamError == nil, !isClosed else {
            lock.unlock()
            return
        }
        streamError = error
        waiting = waiter
        waiter = nil
        if waiting != nil { closeLocked() }
        lock.unlock()

        terminateProcessIfNeeded()
        waiting?.resume(throwing: error)
    }

    private func takeTerminalWaiterLocked() -> (NextContinuation, NextResult)? {
        guard let waiter, let result = terminalResultLocked() else { return nil }
        self.waiter = nil
        closeLocked()
        return (waiter, result)
    }

    private func terminalResultLocked() -> NextResult? {
        if cancelFlag.isCancelled {
            return .failure(ProcessRunnerError.cancelled)
        }
        if let streamError {
            return .failure(streamError)
        }
        guard readyChannels.isEmpty,
              stdoutEOF,
              stderrEOF,
              let terminationStatus else {
            return nil
        }
        if terminationStatus == 0 {
            return .success(nil)
        }
        return .failure(
            ProcessRunnerError.nonZeroExit(
                code: terminationStatus,
                standardError: stderrTail.string()
            )
        )
    }

    private func popPendingLocked() -> ProcessOutputChunk? {
        while !readyChannels.isEmpty {
            switch readyChannels.removeFirst() {
            case .stdout:
                if let data = stdoutPending {
                    stdoutPending = nil
                    return .stdout(data)
                }
            case .stderr:
                if let data = stderrPending {
                    stderrPending = nil
                    return .stderr(data)
                }
            }
        }
        return nil
    }

    private func setPendingLocked(_ data: Data, for channel: Channel) {
        switch channel {
        case .stdout:
            precondition(stdoutPending == nil)
            stdoutPending = data
        case .stderr:
            precondition(stderrPending == nil)
            stderrPending = data
        }
    }

    private func isArmedLocked(_ channel: Channel) -> Bool {
        switch channel {
        case .stdout: stdoutArmed
        case .stderr: stderrArmed
        }
    }

    private func setArmedLocked(_ channel: Channel, _ armed: Bool) {
        switch channel {
        case .stdout: stdoutArmed = armed
        case .stderr: stderrArmed = armed
        }
    }

    private func terminateProcessIfNeeded() {
        let pid: pid_t

        lock.lock()
        guard !terminationEscalationScheduled, process.isRunning else {
            lock.unlock()
            return
        }
        terminationEscalationScheduled = true
        pid = process.processIdentifier
        lock.unlock()

        let processToMonitor = process
        if processToMonitor.isRunning { processToMonitor.terminate() }
        // Prevent a direct child that ignores SIGTERM from surviving cancellation.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if processToMonitor.isRunning {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private func closeLocked() {
        isClosed = true
        stdoutArmed = false
        stderrArmed = false
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
    }
}

private final class BoundedDataTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        if chunk.count >= limit {
            data = Data(chunk.suffix(limit))
            return
        }

        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

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
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
