import Foundation
import XCTest
@testable import XZIPCore

final class SevenZipBoundedListingTests: XCTestCase {
    func testBelowLimitReturnsEveryEntryWithoutTruncation() async throws {
        let runner = FakeRawProcessRunner(
            chunks: [.stdout(Self.listing(paths: ["one.txt", "two.txt"]))],
            completion: .finish
        )
        let engine = makeEngine(runner: runner)

        let result = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/archive.7z"),
            password: nil,
            limit: 3
        )

        XCTAssertEqual(result.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertFalse(result.truncated)
    }

    func testExactLimitIsNotTruncated() async throws {
        let runner = FakeRawProcessRunner(
            chunks: [.stdout(Self.listing(paths: ["one.txt", "two.txt"]))],
            completion: .finish
        )
        let engine = makeEngine(runner: runner)

        let result = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/archive.7z"),
            password: nil,
            limit: 2
        )

        XCTAssertEqual(result.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertFalse(result.truncated)
    }

    func testLimitPlusOneReturnsBoundedEntriesAndTerminatesStream() async throws {
        let terminated = expectation(description: "raw stream terminated early")
        let runner = FakeRawProcessRunner(
            chunks: [.stdout(Self.listing(paths: ["one.txt", "two.txt", "three.txt"]))],
            completion: .pending,
            terminationExpectation: terminated
        )
        let engine = makeEngine(runner: runner)

        let result = try await engine.list(
            archive: URL(fileURLWithPath: "/tmp/archive.7z"),
            password: nil,
            limit: 2
        )

        XCTAssertEqual(result.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertTrue(result.truncated)
        await fulfillment(of: [terminated], timeout: 1)
    }

    func testWrongPasswordErrorIsMapped() async {
        let runner = FakeRawProcessRunner(
            chunks: [],
            completion: .fail(.nonZeroExit(
                code: 2,
                standardError: "ERROR: Wrong password"
            ))
        )
        let engine = makeEngine(runner: runner)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: "incorrect",
                limit: 1
            )
            XCTFail("Expected wrong-password failure")
        } catch ArchiveEngineError.wrongPassword {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesRawStream() async {
        let started = expectation(description: "raw stream started")
        let terminated = expectation(description: "raw stream cancelled")
        let runner = FakeRawProcessRunner(
            chunks: [],
            completion: .pending,
            startExpectation: started,
            terminationExpectation: terminated
        )
        let engine = makeEngine(runner: runner)
        let task = Task {
            try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil,
                limit: 10
            )
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [terminated], timeout: 1)
    }

    func testNegativeLimitFailsBeforeStartingRunner() async {
        let runner = FakeRawProcessRunner(chunks: [], completion: .finish)
        let engine = makeEngine(runner: runner)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil,
                limit: -1
            )
            XCTFail("Expected invalid-limit failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertEqual(message, "Listing limit must be non-negative.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.rawRunCount, 0)
    }

    private func makeEngine(runner: FakeRawProcessRunner) -> SevenZipEngine {
        SevenZipEngine(runner: runner, locator: StaticBinaryLocator())
    }

    private static func listing(paths: [String]) -> Data {
        var text = "----------\n"
        for path in paths {
            text += "Path = \(path)\n"
            text += "Size = 1\n"
            text += "Packed Size = 1\n"
            text += "Attributes = A\n\n"
        }
        return Data(text.utf8)
    }
}

private struct StaticBinaryLocator: BinaryLocating {
    func path(for binary: BundledBinary) -> String? {
        "/usr/bin/7zz"
    }
}

private final class FakeRawProcessRunner: ProcessRunning, @unchecked Sendable {
    enum Completion {
        case finish
        case fail(ProcessRunnerError)
        case pending
    }

    private let chunks: [ProcessOutputChunk]
    private let completion: Completion
    private let startExpectation: XCTestExpectation?
    private let terminationExpectation: XCTestExpectation?
    private let lock = NSLock()
    private var _rawRunCount = 0

    var rawRunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _rawRunCount
    }

    init(
        chunks: [ProcessOutputChunk],
        completion: Completion,
        startExpectation: XCTestExpectation? = nil,
        terminationExpectation: XCTestExpectation? = nil
    ) {
        self.chunks = chunks
        self.completion = completion
        self.startExpectation = startExpectation
        self.terminationExpectation = terminationExpectation
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        throw FakeRunnerError.unexpectedBufferedRun
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        throw FakeRunnerError.unexpectedBufferedRun
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FakeRunnerError.unexpectedLineStreamingRun)
        }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        lock.lock()
        _rawRunCount += 1
        lock.unlock()

        return AsyncThrowingStream { continuation in
            startExpectation?.fulfill()
            continuation.onTermination = { [weak self] _ in
                self?.terminationExpectation?.fulfill()
            }
            for chunk in chunks {
                continuation.yield(chunk)
            }
            switch completion {
            case .finish:
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .pending:
                break
            }
        }
    }
}

private enum FakeRunnerError: Error {
    case unexpectedBufferedRun
    case unexpectedLineStreamingRun
}
