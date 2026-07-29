import Darwin
import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

final class ProcessControllerStressTests: XCTestCase {
    private enum TimeoutError: Error {
        case expired
    }

    private actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private final class BlockingGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let resume = DispatchSemaphore(value: 0)

        func pause() {
            entered.signal()
            resume.wait()
        }

        func waitUntilEntered(timeout: TimeInterval = 2) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(
                        returning: self.entered.wait(timeout: .now() + timeout) == .success
                    )
                }
            }
        }

        func continueExecution() {
            resume.signal()
        }
    }

    private final class ReadObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var readingHandleID: Int?
        private var result: (count: Int, errorNumber: Int32)?
        private var closedReadingHandleBeforeCompletion = false

        func beginRead(handleID: Int) {
            lock.withLock {
                readingHandleID = handleID
            }
        }

        func recordClose(handleID: Int) {
            lock.withLock {
                if readingHandleID == handleID, result == nil {
                    closedReadingHandleBeforeCompletion = true
                }
            }
        }

        func record(count: Int, errorNumber: Int32) {
            lock.withLock {
                result = (count, errorNumber)
            }
        }

        func waitForResult(timeout: Duration = .seconds(2)) async
            -> (count: Int, errorNumber: Int32, closedBeforeCompletion: Bool)? {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let snapshot = snapshot() { return snapshot }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return snapshot()
        }

        private func snapshot()
            -> (count: Int, errorNumber: Int32, closedBeforeCompletion: Bool)? {
            lock.withLock {
                guard let result else { return nil }
                return (
                    result.count,
                    result.errorNumber,
                    closedReadingHandleBeforeCompletion
                )
            }
        }
    }

    private actor PermitGrantGate {
        private var didGrant = false
        private var grantWaiters: [CheckedContinuation<Void, Never>] = []
        private var resumeContinuation: CheckedContinuation<Void, Never>?

        func pauseAfterGrant() async {
            didGrant = true
            let waiters = grantWaiters
            grantWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }

        func waitUntilGranted() async {
            if didGrant { return }
            await withCheckedContinuation { continuation in
                grantWaiters.append(continuation)
            }
        }

        func continueAfterGrant() {
            let continuation = resumeContinuation
            resumeContinuation = nil
            continuation?.resume()
        }
    }

    private struct PausingPermitAcquirer: ProcessPermitAcquiring {
        let pool: LocalProcessPermitPool
        let gate: PermitGrantGate

        func acquire(_ request: ProcessPermitRequest) async throws -> ProcessPermit {
            let permit = try await pool.acquire(request)
            await gate.pauseAfterGrant()
            return permit
        }
    }

    private func policy(
        stderrTailByteCap: Int = 1_024 * 1_024,
        rawChunkByteCap: Int = 256 * 1_024,
        terminationGracePeriod: TimeInterval = 2
    ) -> ArchiveResourcePolicy {
        let base = ArchiveResourcePolicy.production
        return ArchiveResourcePolicy(
            listing: base.listing,
            output: base.output,
            process: ArchiveResourcePolicy.Process(
                stdoutBufferByteCap: base.process.stdoutBufferByteCap,
                stderrTailByteCap: stderrTailByteCap,
                rawChunkByteCap: rawChunkByteCap,
                progressEventBufferCount: base.process.progressEventBufferCount,
                progressInterval: base.process.progressInterval,
                terminationGracePeriod: terminationGracePeriod
            ),
            cache: base.cache,
            split: base.split,
            command: base.command,
            journal: base.journal,
            scheduling: base.scheduling
        )
    }

    private func controller(
        policy: ArchiveResourcePolicy = .production,
        permits: any ProcessPermitAcquiring = LocalProcessPermitPool(limit: 2)
    ) -> ProcessController {
        ProcessController(policy: policy, permits: permits)
    }

    private func request(
        executable: String,
        arguments: [String] = [],
        workload: ProcessWorkload = .metadata(volumeIDs: [])
    ) -> ProcessRequest {
        ProcessRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: nil,
            environment: nil,
            standardInput: nil,
            workload: workload
        )
    }

    private func collect(_ stream: ProcessOutputStream) async throws -> [ProcessEvent] {
        var events: [ProcessEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError.expired
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError.expired }
            return result
        }
    }

    private func waitForFile(_ url: URL, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func publishedPID(at url: URL) async -> pid_t? {
        guard await waitForFile(url, timeout: .seconds(2)) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForExit(_ pid: pid_t, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return kill(pid, 0) != 0
    }

    private func launchTermIgnoringChildAndDropStream(
        controller: ProcessController,
        pidURL: URL
    ) async throws -> pid_t {
        let stream = controller.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%d' $$ > \"$1\"; trap '' TERM; printf ready; while :; do sleep 1; done",
                "sh",
                pidURL.path,
            ],
            workingDirectory: nil,
            environment: nil,
            standardInput: nil,
            workload: .heavyIO(volumeIDs: [])
        ))
        var iterator = stream.makeAsyncIterator()
        guard case .stdout(let data)? = try await iterator.next() else {
            XCTFail("Expected child readiness output")
            throw ProcessRunnerError.cancelled
        }
        XCTAssertEqual(data, Data("ready".utf8))
        guard let pid = await publishedPID(at: pidURL) else {
            XCTFail("Child did not publish PID")
            throw ProcessRunnerError.cancelled
        }
        return pid
    }

    private func waitForQueuedWaiterCount(
        _ expectedCount: Int,
        in pool: LocalProcessPermitPool,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await pool.debugQueuedWaiterCount == expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await pool.debugQueuedWaiterCount == expectedCount
    }

    private func fileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private func threadCount() -> Int {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                getpid(),
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        return result == expectedSize ? Int(info.pti_threadnum) : -1
    }

    func testStderrTailIsBoundedWithoutLosingRawEvents() async throws {
        let marker = "XZIP-TAIL-END"
        let byteCount = 4_096
        let stream = controller(policy: policy(stderrTailByteCap: 1_024)).run(request(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "i=0; while [ $i -lt $1 ]; do printf x >&2; i=$((i + 1)); done; printf '%s' \"$2\" >&2; exit 9",
                "sh",
                String(byteCount),
                marker,
            ]
        ))

        let events = try await collect(stream)
        var rawStderr = Data()
        var result: ProcessResult?
        for event in events {
            switch event {
            case .stdout: break
            case .stderr(let data): rawStderr.append(data)
            case .terminated(let terminal): result = terminal
            }
        }

        XCTAssertEqual(rawStderr.count, byteCount + marker.utf8.count)
        XCTAssertEqual(result?.exitCode, 9)
        XCTAssertLessThanOrEqual(Data((result?.standardError ?? "").utf8).count, 1_024)
        XCTAssertTrue(result?.standardError.hasSuffix(marker) == true)
    }

    func testSlowConsumerKeepsAtMostOnePendingChunkPerChannel() async throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pidURL = directory.appendingPathComponent("pid")
        let doneURL = directory.appendingPathComponent("done")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
        import os, sys, threading
        open(sys.argv[1], "w").write(str(os.getpid()))
        payload = b"x" * 4096
        def write_many(fd):
            for _ in range(4096):
                os.write(fd, payload)
        worker = threading.Thread(target=write_many, args=(2,))
        worker.start()
        write_many(1)
        worker.join()
        open(sys.argv[2], "wb").close()
        """
        let stream = controller(policy: policy(rawChunkByteCap: 4_096)).run(request(
            executable: python,
            arguments: ["-c", script, pidURL.path, doneURL.path]
        ))

        let receivedBothChannels = expectation(description: "received one chunk from each channel")
        let (resume, resumeContinuation) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            var sawStdout = false
            var sawStderr = false
            var paused = false
            for try await event in stream {
                switch event {
                case .stdout(let data): sawStdout = sawStdout || !data.isEmpty
                case .stderr(let data): sawStderr = sawStderr || !data.isEmpty
                case .terminated: break
                }
                if sawStdout, sawStderr, !paused {
                    paused = true
                    receivedBothChannels.fulfill()
                    var iterator = resume.makeAsyncIterator()
                    _ = await iterator.next()
                }
            }
        }

        await fulfillment(of: [receivedBothChannels], timeout: 2)
        guard let pid = await publishedPID(at: pidURL) else {
            stream.cancel()
            resumeContinuation.finish()
            XCTFail("Child did not publish its process ID")
            return
        }

        let finishedWhilePaused = await waitForFile(doneURL, timeout: .milliseconds(300))
        XCTAssertFalse(finishedWhilePaused, "Producer completed while consumer was paused")
        XCTAssertEqual(kill(pid, 0), 0, "Producer is not backpressured and alive")

        stream.cancel()
        resumeContinuation.finish()
        _ = try? await consumer.value
        let didExit = await waitForExit(pid)
        XCTAssertTrue(didExit, "Cancelled producer is still running")
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }

    func testCancellationEscalatesFromTERMToSIGKILLAfterPolicyTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pidURL = directory.appendingPathComponent("pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gracePeriod: TimeInterval = 0.3
        let stream = controller(policy: policy(
            rawChunkByteCap: 4_096,
            terminationGracePeriod: gracePeriod
        )).run(request(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; printf '%s' \"$$\" > \"$1\"; printf ready; exec /bin/sleep 10",
                "sh",
                pidURL.path,
            ]
        ))

        let receivedOutput = expectation(description: "child installed TERM trap")
        let (resume, resumeContinuation) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            var paused = false
            for try await event in stream {
                if case .stdout(let data) = event, !data.isEmpty, !paused {
                    paused = true
                    receivedOutput.fulfill()
                    var iterator = resume.makeAsyncIterator()
                    _ = await iterator.next()
                }
            }
        }

        await fulfillment(of: [receivedOutput], timeout: 2)
        guard let pid = await publishedPID(at: pidURL) else {
            stream.cancel()
            resumeContinuation.finish()
            XCTFail("Child did not publish its process ID")
            return
        }

        let cancelStart = ContinuousClock.now
        stream.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(kill(pid, 0), 0, "SIGKILL occurred before the grace period")

        let didExit = await waitForExit(pid, timeout: .seconds(2))
        let elapsed = cancelStart.duration(to: .now)
        XCTAssertTrue(didExit, "TERM-ignoring child survived cancellation timeout")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(250))
        XCTAssertLessThan(elapsed, .seconds(2))

        resumeContinuation.finish()
        _ = try? await consumer.value
        #if DEBUG
        XCTAssertEqual(stream.debugCompletionCount, 1)
        #endif
    }

    func testRepeatedInvalidLaunchDoesNotLeakFileDescriptorsOrThreads() async {
        let processController = controller()
        let invalidRequest = request(executable: "/definitely/missing/xzip-stress")

        for _ in 0..<3 {
            _ = try? await collect(processController.run(invalidRequest))
        }
        let baselineFDs = fileDescriptorCount()
        let baselineThreads = threadCount()
        XCTAssertGreaterThanOrEqual(baselineFDs, 0)
        XCTAssertGreaterThanOrEqual(baselineThreads, 0)

        for _ in 0..<50 {
            do {
                _ = try await collect(processController.run(invalidRequest))
                XCTFail("Expected launch failure")
            } catch ProcessRunnerError.launchFailed {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var finalFDs = fileDescriptorCount()
        var finalThreads = threadCount()
        while ContinuousClock.now < deadline,
              finalFDs > baselineFDs + 2 || finalThreads > baselineThreads + 4 {
            try? await Task.sleep(for: .milliseconds(20))
            finalFDs = fileDescriptorCount()
            finalThreads = threadCount()
        }

        XCTAssertLessThanOrEqual(finalFDs, baselineFDs + 2, "FD tolerance: +2")
        XCTAssertLessThanOrEqual(finalThreads, baselineThreads + 4, "thread tolerance: +4")
    }

    func testCallbackCancellationDefersHandleCloseUntilReadCompletes() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-process-controller-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let gate = BlockingGate()
        let readObservation = ReadObservation()
        let pool = LocalProcessPermitPool(limit: 1)
        let controller = ProcessController(
            policy: policy(terminationGracePeriod: 0.2),
            permits: pool,
            testHooks: ProcessControllerTestHooks(
                readHandle: { handleID in
                    readObservation.beginRead(handleID: handleID)
                },
                beforeRead: { gate.pause() },
                afterRead: { count, errorNumber in
                    readObservation.record(count: count, errorNumber: errorNumber)
                },
                beforeClose: { handleID in
                    readObservation.recordClose(handleID: handleID)
                }
            )
        )
        let stream = controller.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%d' $$ > \"$1\"; printf ready; trap '' TERM; while :; do sleep 1; done",
                "sh",
                pidURL.path,
            ],
            workingDirectory: nil,
            environment: nil,
            standardInput: nil,
            workload: .metadata(volumeIDs: [])
        ))
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        let callbackEntered = await gate.waitUntilEntered()
        XCTAssertTrue(callbackEntered, "stdout callback did not reach deterministic read barrier")
        guard let pid = await publishedPID(at: pidURL) else {
            XCTFail("Child did not publish PID")
            gate.continueExecution()
            return
        }

        stream.cancel()
        gate.continueExecution()
        _ = try? await consumer.value

        guard let readResult = await readObservation.waitForResult() else {
            XCTFail("read callback did not publish result")
            return
        }
        XCTAssertFalse(
            readResult.closedBeforeCompletion,
            "cancel closed callback handle before in-flight read completed"
        )
        XCTAssertGreaterThanOrEqual(
            readResult.count,
            0,
            "read used a closed descriptor (errno \(readResult.errorNumber))"
        )

        let exited = await waitForExit(pid, timeout: .seconds(3))
        XCTAssertTrue(exited, "cancelled child should terminate after callback/read race")
        XCTAssertEqual(stream.debugCompletionCount, 1)

        let recoveredPermit = try await withTimeout(.seconds(2)) {
            try await pool.acquire(ProcessPermitRequest(workload: .metadata(volumeIDs: [])))
        }
        await recoveredPermit.release()
    }

    func testCancellationAfterPermitGrantReleasesPreLaunchPermit() async throws {
        let pool = LocalProcessPermitPool(limit: 1)
        let gate = PermitGrantGate()
        let controller = ProcessController(
            policy: policy(),
            permits: PausingPermitAcquirer(pool: pool, gate: gate)
        )
        let stream = controller.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            workingDirectory: nil,
            environment: nil,
            standardInput: nil,
            workload: .metadata(volumeIDs: [])
        ))

        await gate.waitUntilGranted()
        stream.cancel()
        await gate.continueAfterGrant()

        do {
            for try await _ in stream {}
        } catch {
            guard case ProcessRunnerError.cancelled = error else {
                XCTFail("Expected cancellation, got \(error)")
                return
            }
        }
        XCTAssertEqual(stream.debugCompletionCount, 1)

        let recoveredPermit = try await withTimeout(.seconds(2)) {
            try await pool.acquire(ProcessPermitRequest(workload: .metadata(volumeIDs: [])))
        }
        await recoveredPermit.release()
    }

    func testDroppedCancelledStreamRetainsPermitUntilForcedTermination() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-process-controller-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let pool = LocalProcessPermitPool(limit: 1)
        let controller = ProcessController(
            policy: policy(terminationGracePeriod: 0.2),
            permits: pool
        )

        let pid = try await launchTermIgnoringChildAndDropStream(
            controller: controller,
            pidURL: pidURL
        )
        let exited = await waitForExit(pid, timeout: .seconds(3))
        XCTAssertTrue(exited, "dropped stream child should reach forced termination")

        let recoveredPermit = try await withTimeout(.seconds(2)) {
            try await pool.acquire(ProcessPermitRequest(workload: .metadata(volumeIDs: [])))
        }
        await recoveredPermit.release()
    }

    func testPermitContentionCancellationAndOneShotRelease() async throws {
        let counter = Counter()
        let oneShot = ProcessPermit {
            await counter.increment()
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { await oneShot.release() }
            }
        }
        let releaseCount = await counter.value
        XCTAssertEqual(releaseCount, 1)

        let pool = LocalProcessPermitPool(limit: 1)
        let permitRequest = ProcessPermitRequest(workload: .metadata(volumeIDs: []))
        let first = try await pool.acquire(permitRequest)
        let cancelledWaiter = Task {
            try await pool.acquire(permitRequest)
        }
        let cancelledWaiterQueued = await waitForQueuedWaiterCount(1, in: pool)
        XCTAssertTrue(cancelledWaiterQueued, "cancelled waiter never entered permit queue")

        let survivingWaiter = Task {
            try await pool.acquire(permitRequest)
        }
        let bothWaitersQueued = await waitForQueuedWaiterCount(2, in: pool)
        XCTAssertTrue(bothWaitersQueued, "surviving waiter never entered FIFO queue")

        cancelledWaiter.cancel()
        do {
            let unexpectedPermit = try await cancelledWaiter.value
            await unexpectedPermit.release()
            XCTFail("Cancelled waiter acquired a permit")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let cancelledWaiterRemoved = await waitForQueuedWaiterCount(1, in: pool)
        XCTAssertTrue(cancelledWaiterRemoved, "cancelled waiter was not removed from permit queue")

        await first.release()
        let survivingPermit = try await withTimeout(.seconds(1)) {
            try await survivingWaiter.value
        }
        await survivingPermit.release()
        let queueDrained = await waitForQueuedWaiterCount(0, in: pool)
        XCTAssertTrue(queueDrained, "permit queue did not drain")

        let recoveredPermit = try await withTimeout(.seconds(1)) {
            try await pool.acquire(permitRequest)
        }
        await recoveredPermit.release()
    }
}
