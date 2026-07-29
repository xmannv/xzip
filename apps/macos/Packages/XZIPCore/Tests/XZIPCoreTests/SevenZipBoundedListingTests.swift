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
        let runner = ScriptedProcessController(
            events: [.stdout(Self.listing(paths: [
                "one.txt", "two.txt", "three.txt",
            ]))],
            finishesAfterEvents: false,
            terminationBehavior: .controllerInduced,
            terminationRequestExpectation: terminated
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

    func testReadCommentStopsAfterHeaderWithoutCancellationError() async throws {
        let terminated = expectation(description: "comment stream terminated early")
        let runner = ScriptedProcessController(
            events: [.stdout(Data(
                "Comment = hello\n----------\nPath = huge\n".utf8
            ))],
            finishesAfterEvents: false,
            terminationBehavior: .controllerInduced,
            terminationRequestExpectation: terminated
        )
        let engine = makeEngine(runner: runner)

        let comment = try await engine.readComment(
            archive: URL(fileURLWithPath: "/tmp/archive.7z"),
            password: nil
        )

        XCTAssertEqual(comment, "hello")
        await fulfillment(of: [terminated], timeout: 1)
    }


    func testReadCommentDoesNotHidePendingNonZeroTerminal() async {
        let runner = ScriptedProcessController(
            events: [
                .stdout(Data("Comment = hello\n----------\n".utf8)),
                .stderr(Data("fatal listing error".utf8)),
                .terminated(ProcessResult(
                    exitCode: 2,
                    standardOutput: "",
                    standardError: "fatal listing error"
                )),
            ],
            finishesAfterEvents: true
        )
        let engine = makeEngine(runner: runner)

        do {
            _ = try await engine.readComment(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil
            )
            XCTFail("Expected nonzero terminal failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("fatal listing error"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBoundedListingDoesNotHidePendingNonZeroTerminal() async {
        let runner = ScriptedProcessController(
            events: [
                .stdout(Self.listing(paths: ["one.txt", "two.txt"])),
                .stderr(Data("fatal listing error".utf8)),
                .terminated(ProcessResult(
                    exitCode: 2,
                    standardOutput: "",
                    standardError: "fatal listing error"
                )),
            ],
            finishesAfterEvents: true
        )
        let engine = makeEngine(runner: runner)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil,
                limit: 1
            )
            XCTFail("Expected nonzero terminal failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("fatal listing error"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFullListingRejectsStreamWithoutTerminalEvent() async {
        let runner = ScriptedProcessController(
            events: [.stdout(Self.listing(paths: ["one.txt"]))],
            finishesAfterEvents: true
        )
        let engine = makeEngine(runner: runner)

        do {
            _ = try await engine.list(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil
            )
            XCTFail("Expected missing-terminal failure")
        } catch ProcessRunnerError.launchFailed(let message) {
            XCTAssertEqual(
                message,
                "Process stream ended without a terminal result."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationDuringDeliberateCommentStopIsNotSuccess() async {
        let terminationRequested = expectation(
            description: "comment termination requested"
        )
        let runner = ScriptedProcessController(
            events: [.stdout(Data("Comment = hello\n----------\n".utf8))],
            finishesAfterEvents: false,
            terminationRequestExpectation: terminationRequested
        )
        let engine = makeEngine(runner: runner)
        let task = Task {
            try await engine.readComment(
                archive: URL(fileURLWithPath: "/tmp/archive.7z"),
                password: nil
            )
        }

        await fulfillment(of: [terminationRequested], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
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

    private func makeEngine(runner: any ProcessControlling) -> SevenZipEngine {
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

private final class FakeRawProcessRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
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

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: makeEventStream())
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
        makeRawStream()
    }

    private func makeEventStream() -> AsyncThrowingStream<ProcessEvent, Error> {
        let rawStream = makeRawStream()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in rawStream {
                        switch chunk {
                        case .stdout(let data): continuation.yield(.stdout(data))
                        case .stderr(let data): continuation.yield(.stderr(data))
                        }
                    }
                    continuation.yield(.terminated(ProcessResult(
                        exitCode: 0,
                        standardOutput: "",
                        standardError: ""
                    )))
                    continuation.finish()
                } catch ProcessRunnerError.nonZeroExit(let code, let standardError) {
                    continuation.yield(.terminated(ProcessResult(
                        exitCode: code,
                        standardOutput: "",
                        standardError: standardError
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeRawStream() -> AsyncThrowingStream<ProcessOutputChunk, Error> {
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


private final class ScriptedProcessController: ProcessControlling, @unchecked Sendable {
    enum TerminationBehavior {
        case none
        case controllerInduced
    }

    private let events: [ProcessEvent]
    private let finishesAfterEvents: Bool
    private let terminationBehavior: TerminationBehavior
    private let terminationRequestExpectation: XCTestExpectation?

    init(
        events: [ProcessEvent],
        finishesAfterEvents: Bool,
        terminationBehavior: TerminationBehavior = .none,
        terminationRequestExpectation: XCTestExpectation? = nil
    ) {
        self.events = events
        self.finishesAfterEvents = finishesAfterEvents
        self.terminationBehavior = terminationBehavior
        self.terminationRequestExpectation = terminationRequestExpectation
    }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        let source = ScriptedProcessEventSource(
            events: events,
            finishesAfterEvents: finishesAfterEvents,
            terminationBehavior: terminationBehavior,
            terminationRequestExpectation: terminationRequestExpectation
        )
        return ProcessOutputStream(
            adapting: source.makeStream(),
            onTerminationRequest: { source.requestTermination() },
            onCancel: { source.cancel() }
        )
    }
}

private final class ScriptedProcessEventSource: @unchecked Sendable {
    private let lock = NSLock()
    private let events: [ProcessEvent]
    private let finishesAfterEvents: Bool
    private let terminationBehavior: ScriptedProcessController.TerminationBehavior
    private let terminationRequestExpectation: XCTestExpectation?
    private var continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
    private var didRequestTermination = false
    private var isFinished = false

    init(
        events: [ProcessEvent],
        finishesAfterEvents: Bool,
        terminationBehavior: ScriptedProcessController.TerminationBehavior,
        terminationRequestExpectation: XCTestExpectation?
    ) {
        self.events = events
        self.finishesAfterEvents = finishesAfterEvents
        self.terminationBehavior = terminationBehavior
        self.terminationRequestExpectation = terminationRequestExpectation
    }

    func makeStream() -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            for event in events { continuation.yield(event) }
            if finishesAfterEvents {
                finish()
            }
        }
    }

    func requestTermination() {
        let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
        lock.lock()
        guard !didRequestTermination, !isFinished else {
            lock.unlock()
            return
        }
        didRequestTermination = true
        continuation = self.continuation
        lock.unlock()

        terminationRequestExpectation?.fulfill()
        switch terminationBehavior {
        case .none:
            break
        case .controllerInduced:
            continuation?.yield(.terminated(ProcessResult(
                exitCode: 15,
                standardOutput: "",
                standardError: "",
                wasTerminatedByRequest: true
            )))
            finish()
        }
    }

    func cancel() {
        finish(throwing: ProcessRunnerError.cancelled)
    }

    private func finish(throwing error: Error? = nil) {
        let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

private enum FakeRunnerError: Error {
    case unexpectedBufferedRun
    case unexpectedLineStreamingRun
}
