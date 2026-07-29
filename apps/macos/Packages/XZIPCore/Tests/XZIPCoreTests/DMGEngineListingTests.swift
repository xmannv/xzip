import Foundation
import XCTest
@testable import XZIPCore

final class DMGEngineListingTests: XCTestCase {
    func testBoundedListingReadsOnlyLimitPlusOneURLs() async throws {
        let iterator = CountingDMGDirectoryIterator(
            urls: (0..<10).map { URL(fileURLWithPath: "/tmp/item-\($0)") }
        )
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(runner: runner, iterator: iterator)

        let result = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
            password: nil,
            limit: 2
        )

        XCTAssertEqual(result.entries.map(\.path), ["item-0", "item-1"])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(iterator.nextURLCallCount, 3)
        XCTAssertEqual(runner.detachCount, 1)
    }

    func testExactLimitIsNotTruncated() async throws {
        let iterator = CountingDMGDirectoryIterator(urls: [
            URL(fileURLWithPath: "/tmp/one"),
            URL(fileURLWithPath: "/tmp/two"),
        ])
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(runner: runner, iterator: iterator)

        let result = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
            password: nil,
            limit: 2
        )

        XCTAssertEqual(result.entries.map(\.path), ["one", "two"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(iterator.nextURLCallCount, 3)
        XCTAssertEqual(runner.detachCount, 1)
    }

    func testEnumerationErrorStillDetaches() async {
        let iterator = CountingDMGDirectoryIterator(
            urls: [],
            error: DMGEnumerationTestError.failed
        )
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(runner: runner, iterator: iterator)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 2
            )
            XCTFail("Expected enumeration failure")
        } catch DMGEnumerationTestError.failed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }

    func testCancellationStillDetaches() async {
        let enumerationStarted = expectation(description: "enumeration started")
        let iterator = CancellationWaitingDMGDirectoryIterator(
            startExpectation: enumerationStarted
        )
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(runner: runner, iterator: iterator)
        let task = Task {
            try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 2
            )
        }

        await fulfillment(of: [enumerationStarted], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }


    func testAttachFailureStillAttemptsDetach() async {
        let runner = FakeDMGProcessRunner(
            attachOutcome: .nonZero("attach failed")
        )
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: [])
        )

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
            XCTFail("Expected attach failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("attach failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }


    func testThrownAttachStillAttemptsDetach() async {
        let runner = FakeDMGProcessRunner(
            attachOutcome: .failure(.attachFailed)
        )
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: [])
        )

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
            XCTFail("Expected attach failure")
        } catch DMGEnumerationTestError.attachFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }

    func testCancellationDuringAttachWaitsForTerminalThenDetaches() async {
        let gate = DMGProcessGate()
        let runner = FakeDMGProcessRunner(attachGate: gate)
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: [])
        )
        let task = Task {
            try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
        }

        await gate.waitUntilStarted()
        task.cancel()
        XCTAssertEqual(runner.detachCount, 0)
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }


    func testCancellationAfterAttachTerminalBeforeReturnDetaches() async {
        let afterTerminalGate = DMGProcessGate()
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: []),
            afterAttachTermination: {
                await afterTerminalGate.markStarted()
                await afterTerminalGate.waitUntilReleased()
            }
        )
        let task = Task {
            try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
        }

        await afterTerminalGate.waitUntilStarted()
        task.cancel()
        XCTAssertEqual(runner.detachCount, 0)
        await afterTerminalGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }


    func testPendingAttachFailureIsNotMaskedByCancellation() async {
        let afterTerminalGate = DMGProcessGate()
        let runner = FakeDMGProcessRunner(
            attachOutcome: .nonZero("attach failed")
        )
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: []),
            afterAttachTermination: {
                await afterTerminalGate.markStarted()
                await afterTerminalGate.waitUntilReleased()
            }
        )
        let task = Task {
            try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
        }

        await afterTerminalGate.waitUntilStarted()
        task.cancel()
        await afterTerminalGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected attach failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("attach failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.detachCount, 1)
    }

    func testNonZeroDetachFailsListing() async {
        let runner = FakeDMGProcessRunner(
            detachOutcome: .nonZero("detach failed")
        )
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: [])
        )

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
            XCTFail("Expected detach failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("detach failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(runner.detachCount, 1)
    }

    func testThrownDetachFailsListing() async {
        let runner = FakeDMGProcessRunner(
            detachOutcome: .failure(.detachFailed)
        )
        let engine = makeEngine(
            runner: runner,
            iterator: CountingDMGDirectoryIterator(urls: [])
        )

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: 1
            )
            XCTFail("Expected detach failure")
        } catch DMGEnumerationTestError.detachFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(runner.detachCount, 1)
    }

    func testNegativeLimitFailsBeforeAttach() async {
        let iterator = CountingDMGDirectoryIterator(urls: [])
        let runner = FakeDMGProcessRunner()
        let engine = makeEngine(runner: runner, iterator: iterator)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.dmg"),
                password: nil,
                limit: -1
            )
            XCTFail("Expected invalid-limit failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertEqual(message, "Listing limit must be non-negative.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.attachCount, 0)
    }

    private func makeEngine(
        runner: FakeDMGProcessRunner,
        iterator: any DMGDirectoryIterating,
        afterAttachTermination: @escaping @Sendable () async -> Void = {}
    ) -> DMGEngine {
        DMGEngine(
            runner: runner,
            makeDirectoryIterator: { _, _ in iterator },
            afterAttachTermination: afterAttachTermination
        )
    }
}

private final class CountingDMGDirectoryIterator: DMGDirectoryIterating, @unchecked Sendable {
    private let urls: [URL]
    private let error: Error?
    private let lock = NSLock()
    private var index = 0
    private var _nextURLCallCount = 0

    var nextURLCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _nextURLCallCount
    }

    init(urls: [URL], error: Error? = nil) {
        self.urls = urls
        self.error = error
    }

    func nextURL() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        _nextURLCallCount += 1
        if let error { throw error }
        guard index < urls.count else { return nil }
        defer { index += 1 }
        return urls[index]
    }
}

private final class CancellationWaitingDMGDirectoryIterator: DMGDirectoryIterating, @unchecked Sendable {
    private let startExpectation: XCTestExpectation

    init(startExpectation: XCTestExpectation) {
        self.startExpectation = startExpectation
    }

    func nextURL() throws -> URL? {
        startExpectation.fulfill()
        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CancellationError()
    }
}

private final class FakeDMGProcessRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    enum Outcome {
        case success
        case nonZero(String)
        case failure(DMGEnumerationTestError)
    }

    private let lock = NSLock()
    private let attachOutcome: Outcome
    private let detachOutcome: Outcome
    private let attachGate: DMGProcessGate?
    private var _attachCount = 0
    private var _detachCount = 0

    init(
        attachOutcome: Outcome = .success,
        detachOutcome: Outcome = .success,
        attachGate: DMGProcessGate? = nil
    ) {
        self.attachOutcome = attachOutcome
        self.detachOutcome = detachOutcome
        self.attachGate = attachGate
    }

    var attachCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _attachCount
    }

    var detachCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _detachCount
    }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await execute(arguments: request.arguments)
                    continuation.yield(.terminated(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try await execute(arguments: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try await execute(arguments: arguments)
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DMGEnumerationTestError.unexpectedStreamingRun)
        }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DMGEnumerationTestError.unexpectedStreamingRun)
        }
    }

    private func execute(arguments: [String]) async throws -> ProcessResult {
        let outcome: Outcome
        switch arguments.first {
        case "attach":
            lock.withLock { _attachCount += 1 }
            if let attachGate {
                await attachGate.markStarted()
                await attachGate.waitUntilReleased()
            }
            outcome = attachOutcome
        case "detach":
            lock.withLock { _detachCount += 1 }
            outcome = detachOutcome
        default:
            throw DMGEnumerationTestError.unexpectedStreamingRun
        }

        switch outcome {
        case .success:
            return ProcessResult(
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            )
        case .nonZero(let message):
            return ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: message
            )
        case .failure(let error):
            throw error
        }
    }
}


private actor DMGProcessGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private enum DMGEnumerationTestError: Error {
    case failed
    case attachFailed
    case detachFailed
    case unexpectedStreamingRun
}
