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
        iterator: any DMGDirectoryIterating
    ) -> DMGEngine {
        DMGEngine(
            runner: runner,
            makeDirectoryIterator: { _, _ in iterator }
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

private final class FakeDMGProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _attachCount = 0
    private var _detachCount = 0

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

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        record(arguments: arguments)
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        record(arguments: arguments)
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
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

    private func record(arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        switch arguments.first {
        case "attach": _attachCount += 1
        case "detach": _detachCount += 1
        default: break
        }
    }
}

private enum DMGEnumerationTestError: Error {
    case failed
    case unexpectedStreamingRun
}
