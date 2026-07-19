import Darwin
import Foundation
import XCTest
@testable import XZIPCore

final class RawProcessStreamingTests: XCTestCase {
    func testRawStreamingPreservesBytes() async throws {
        let expected = Data([0x61, 0x0D, 0x62, 0x0A, 0x0A, 0xC3, 0xA9, 0x08])
        var received = Data()

        let stream = FoundationProcessRunner().runRawStreaming(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\141\\015\\142\\012\\012\\303\\251\\010'"],
            workingDirectory: nil,
            environment: nil
        )

        for try await chunk in stream {
            if case .stdout(let data) = chunk {
                received.append(data)
            }
        }

        XCTAssertEqual(received, expected)
    }

    func testRawStreamingNonZeroExitKeepsBoundedStderrTail() async {
        let marker = "XZIP-END-MARKER"
        let stream = FoundationProcessRunner().runRawStreaming(
            executable: "/bin/sh",
            arguments: ["-c", "yes x | head -c 70000 >&2; printf '\(marker)' >&2; exit 7"],
            workingDirectory: nil,
            environment: nil
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected non-zero exit")
        } catch ProcessRunnerError.nonZeroExit(let code, let standardError) {
            XCTAssertEqual(code, 7)
            XCTAssertLessThanOrEqual(Data(standardError.utf8).count, 65_536)
            XCTAssertTrue(standardError.hasSuffix(marker))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRawStreamingCancellationTerminatesChild() async {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let stream = FoundationProcessRunner().runRawStreaming(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                "sh",
                pidURL.path,
            ],
            workingDirectory: nil,
            environment: nil
        )
        let task = Task {
            for try await _ in stream {}
        }

        let launchStart = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: pidURL.path),
              launchStart.duration(to: .now) < .seconds(1) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.cancel()
            XCTFail("Child did not publish its process ID")
            return
        }

        let cancelStart = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        while kill(pid, 0) == 0,
              cancelStart.duration(to: .now) < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotEqual(kill(pid, 0), 0, "Child process is still running")
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }


    func testRawStreamingCancellationEscalatesWhenChildIgnoresSIGTERM() async {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidURL) }

        let task = Task {
            for try await _ in FoundationProcessRunner().runRawStreaming(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                    "sh",
                    pidURL.path,
                ],
                workingDirectory: nil,
                environment: nil
            ) {}
        }

        let launchStart = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: pidURL.path),
              launchStart.duration(to: .now) < .seconds(1) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.cancel()
            XCTFail("Child did not publish its process ID")
            return
        }

        task.cancel()
        _ = try? await task.value
        let cancelStart = ContinuousClock.now
        while kill(pid, 0) == 0,
              cancelStart.duration(to: .now) < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let isStillRunning = kill(pid, 0) == 0
        if isStillRunning { _ = kill(pid, SIGKILL) }
        XCTAssertFalse(isStillRunning, "Child ignored cancellation indefinitely")
    }

    func testRawStreamingFeedsStandardInput() async throws {
        let expected = Data([0x70, 0x61, 0x73, 0x73, 0x0A])
        var received = Data()

        let stream = FoundationProcessRunner().runRawStreaming(
            executable: "/bin/cat",
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            standardInput: "pass\n"
        )

        for try await chunk in stream {
            if case .stdout(let data) = chunk {
                received.append(data)
            }
        }

        XCTAssertEqual(received, expected)
    }


    func testRawStreamingReturnsBeforeChildReadsLargeStandardInput() async {
        let returnedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: returnedURL) }

        let byteCount = 1_048_576
        let task = Task { () throws -> Int in
            let stream = FoundationProcessRunner().runRawStreaming(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 1; /bin/cat >/dev/null"],
                workingDirectory: nil,
                environment: nil,
                standardInput: String(repeating: "i", count: byteCount)
            )
            try Data().write(to: returnedURL)

            var received = 0
            for try await chunk in stream {
                if case .stdout(let data) = chunk {
                    received += data.count
                }
            }
            return received
        }

        let returnStart = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: returnedURL.path),
              returnStart.duration(to: .now) < .milliseconds(500) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let returnedPromptly = FileManager.default.fileExists(atPath: returnedURL.path)

        do {
            let received = try await task.value
            XCTAssertTrue(returnedPromptly, "runRawStreaming blocked while writing stdin")
            XCTAssertEqual(received, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    func testRawStreamingBackpressuresProducerUntilConsumerCancels() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pidURL = directory.appendingPathComponent("pid")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstChunk = expectation(description: "received first stdout chunk")
        let (resumeStream, resumeContinuation) = AsyncStream.makeStream(of: Void.self)
        let stream = FoundationProcessRunner().runRawStreaming(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s' \"$$\" > \"$1\"; exec /usr/bin/head -c 16777216 /dev/zero",
                "sh",
                pidURL.path,
            ],
            workingDirectory: nil,
            environment: nil
        )

        let task = Task {
            var didPause = false
            for try await chunk in stream {
                if !didPause, case .stdout(let data) = chunk, !data.isEmpty {
                    didPause = true
                    firstChunk.fulfill()
                    var iterator = resumeStream.makeAsyncIterator()
                    _ = await iterator.next()
                }
            }
        }

        await fulfillment(of: [firstChunk], timeout: 2)
        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.cancel()
            resumeContinuation.finish()
            XCTFail("Child did not publish its process ID")
            return
        }

        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(
            kill(pid, 0),
            0,
            "Producer finished while the consumer was paused"
        )

        let cancelStart = ContinuousClock.now
        task.cancel()
        resumeContinuation.finish()
        _ = try? await task.value
        while kill(pid, 0) == 0,
              cancelStart.duration(to: .now) < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotEqual(kill(pid, 0), 0, "Child process is still running")
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }
}
