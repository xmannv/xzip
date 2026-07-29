import Foundation
import XCTest
@testable import XZIPCore

/// Tests for the DMG mount lifecycle and the privacy of its scratch directories.
final class DMGMountLifecycleTests: XCTestCase {

    /// The mount point of an encrypted image exposes its *decrypted* contents for
    /// as long as it stays mounted. It was created with the default mode (0755
    /// after a typical umask), so on a shared Mac every local user could read it.
    func testScratchDirectoryIsPrivateToTheOwningUser() throws {
        let directory = try DMGEngine.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var info = stat()
        XCTAssertEqual(stat(directory.path, &info), 0)
        let mode = info.st_mode & 0o777
        XCTAssertEqual(
            mode, 0o700,
            "expected 0700, got \(String(mode, radix: 8)): group/other must not reach a mount point"
        )
    }

    /// A successful mount must be released exactly once — not zero times (which
    /// leaks an attached volume past process exit) and not twice.
    ///
    /// Deliberately no companion test asserting that a *failed* attach skips the
    /// detach: that would be wrong. A failed `hdiutil attach` does not prove
    /// nothing was mounted, since attach can create the device node and then fail
    /// later, and cancellation can kill it after the volume is attached. The
    /// best-effort detach on failure is cleanup for those partial states, and
    /// `DMGEngineListingTests` already pins it down for both failure and
    /// cancellation.
    func testSuccessfulMountIsDetachedExactlyOnce() async throws {
        let runner = FakeMountRunner(attachFails: false)
        let engine = DMGEngine(runner: runner)

        _ = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/plain.dmg"),
            password: nil
        )

        XCTAssertEqual(runner.attachCount, 1)
        XCTAssertEqual(runner.detachCount, 1)
    }
}

/// Fake `hdiutil` that counts attach/detach and can fail the attach.
private final class FakeMountRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    private let attachFails: Bool
    private let lock = NSLock()
    private var _attachCount = 0
    private var _detachCount = 0

    init(attachFails: Bool) {
        self.attachFails = attachFails
    }

    var attachCount: Int { lock.withLock { _attachCount } }
    var detachCount: Int { lock.withLock { _detachCount } }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            do {
                continuation.yield(.terminated(try execute(arguments: request.arguments)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        })
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeMountError.unexpectedInvocation) }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeMountError.unexpectedInvocation) }
    }

    private func execute(arguments: [String]) throws -> ProcessResult {
        switch arguments.first {
        case "attach":
            lock.withLock { _attachCount += 1 }
            guard attachFails else {
                return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
            }
            return ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "hdiutil: attach: Authentication error"
            )
        case "detach":
            lock.withLock { _detachCount += 1 }
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        default:
            throw FakeMountError.unexpectedInvocation
        }
    }
}

private enum FakeMountError: Error {
    case unexpectedInvocation
}
