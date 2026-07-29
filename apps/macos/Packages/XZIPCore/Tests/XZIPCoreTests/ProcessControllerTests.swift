import Darwin
import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

final class ProcessControllerTests: XCTestCase {
    private func makeController() -> ProcessController {
        ProcessController(
            policy: .production,
            permits: LocalProcessPermitPool(limit: 1)
        )
    }

    private func request(
        executable: String,
        arguments: [String] = [],
        standardInput: Data? = nil
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: nil,
            environment: nil,
            standardInput: standardInput,
            workload: .metadata(volumeIDs: [])
        )
    }

    private func collect(_ stream: ProcessOutputStream) async throws -> [ProcessEvent] {
        var events: [ProcessEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func publishedPID(at url: URL) async -> pid_t? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitForExit(_ pid: pid_t, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return kill(pid, 0) != 0
    }

    func testInvalidExecutableThrowsAndCompletesOnce() async {
        let stream = makeController().run(request(
            executable: "/definitely/missing/xzip-process-controller"
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected launch failure")
        } catch ProcessRunnerError.launchFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }

    func testCancellationBeforeFirstReadCompletesOnce() async {
        let stream = makeController().run(request(
            executable: "/bin/sleep",
            arguments: ["10"]
        ))

        stream.cancel()
        _ = try? await collect(stream)

        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }

    func testStandardInputClosesAndCatTerminatesWithIdenticalStdout() async throws {
        let payload = Data([0x00, 0x61, 0x0A, 0xFF, 0x62])
        let stream = makeController().run(request(
            executable: "/bin/cat",
            standardInput: payload
        ))

        let events = try await collect(stream)
        var stdout = Data()
        var terminalResults: [ProcessResult] = []
        for event in events {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr: break
            case .terminated(let result): terminalResults.append(result)
            }
        }

        XCTAssertEqual(stdout, payload)
        XCTAssertEqual(terminalResults.count, 1)
        XCTAssertEqual(terminalResults.first?.exitCode, 0)
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }

    func testEarlyConsumerStopTerminatesChildAndCompletesOnce() async {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let stream = makeController().run(request(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s' \"$$\" > \"$1\"; printf ready; exec /bin/sleep 10",
                "sh",
                pidURL.path,
            ]
        ))

        let consumer = Task {
            for try await event in stream {
                if case .stdout(let data) = event, !data.isEmpty { break }
            }
        }

        guard let pid = await publishedPID(at: pidURL) else {
            consumer.cancel()
            stream.cancel()
            XCTFail("Child did not publish its process ID")
            return
        }
        let stopStart = ContinuousClock.now
        _ = try? await consumer.value

        let didExit = await waitForExit(pid)
        XCTAssertTrue(didExit, "Child process is still running")
        XCTAssertLessThan(
            stopStart.duration(to: .now),
            .seconds(3),
            "Early consumer stop waited for natural child exit"
        )
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }


    func testRequestedTerminationPreservesTerminalAndReleasesPermit() async throws {
        let pool = LocalProcessPermitPool(limit: 1)
        let controller = ProcessController(policy: .production, permits: pool)
        let stream = controller.run(request(
            executable: "/bin/sh",
            arguments: ["-c", "printf ready; exec /bin/sleep 10"]
        ))
        var iterator = stream.makeAsyncIterator()

        var observedOutput = false
        while let event = try await iterator.next() {
            if case .stdout(let data) = event, !data.isEmpty {
                observedOutput = true
                break
            }
        }
        XCTAssertTrue(observedOutput)

        stream.requestTermination()

        var terminal: ProcessResult?
        while let event = try await iterator.next() {
            if case .terminated(let result) = event {
                terminal = result
                break
            }
        }
        XCTAssertNotNil(terminal)
        XCTAssertFalse(terminal?.isSuccess ?? true)
        XCTAssertTrue(terminal?.wasTerminatedByRequest ?? false)
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif

        let followupEvents = try await collect(controller.run(request(
            executable: "/bin/sh",
            arguments: ["-c", "printf followup"]
        )))
        XCTAssertTrue(followupEvents.contains { event in
            if case .terminated(let result) = event {
                return result.isSuccess
            }
            return false
        })
    }

    func testNormalTerminationEmitsExactOutputAndOneTerminalEvent() async throws {
        let stream = makeController().run(request(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"]
        ))

        let events = try await collect(stream)
        var stdout = Data()
        var stderr = Data()
        var terminalResults: [ProcessResult] = []
        for event in events {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            case .terminated(let result): terminalResults.append(result)
            }
        }

        XCTAssertEqual(stdout, Data("out".utf8))
        XCTAssertEqual(stderr, Data("err".utf8))
        XCTAssertEqual(terminalResults.count, 1)
        XCTAssertEqual(terminalResults.first?.exitCode, 7)
        XCTAssertEqual(terminalResults.first?.standardOutput, "out")
        XCTAssertEqual(terminalResults.first?.standardError, "err")
        XCTAssertEqual(events.count(where: {
            if case .terminated = $0 { return true }
            return false
        }), 1)
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }


    func testLineAdapterRejectsStreamWithoutTerminalEvent() async {
        struct MissingTerminalController: ProcessControlling {
            func run(_ request: ProcessRequest) -> ProcessOutputStream {
                ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
                    continuation.yield(.stdout(Data("partial\n".utf8)))
                    continuation.finish()
                })
            }
        }

        let stream = MissingTerminalController().runLineStreaming(ProcessRequest(
            executable: "/bin/true",
            arguments: [],
            workload: .metadata(volumeIDs: [])
        ))

        do {
            for try await _ in stream {}
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


    func testRawAdapterRejectsStreamWithoutTerminalEvent() async {
        struct MissingTerminalController: ProcessControlling {
            func run(_ request: ProcessRequest) -> ProcessOutputStream {
                ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
                    continuation.yield(.stdout(Data("partial".utf8)))
                    continuation.finish()
                })
            }
        }

        let stream = MissingTerminalController().runRawStreaming(ProcessRequest(
            executable: "/bin/true",
            arguments: [],
            workload: .metadata(volumeIDs: [])
        ))

        do {
            for try await _ in stream {}
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
}
