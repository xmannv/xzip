import XCTest
@testable import XZip

/// Tests for `ArchiveMutationGate`, which serializes the in-place rewrites of an
/// archive so two `7zz` passes never race on the same file.
@MainActor
final class ArchiveMutationGateTests: XCTestCase {

    // MARK: - Helpers

    /// Lets a test hold a mutation "in flight" until it decides to release it.
    @MainActor
    private final class Latch {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Collects the order in which mutations ran.
    @MainActor
    private final class Recorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    /// Waits (bounded) for the gate to free `archive`. The slot is released in a
    /// follow-up task, so it is not free the instant the body returns.
    private func waitUntilFree(_ gate: ArchiveMutationGate, _ archive: URL) async {
        for _ in 0..<1_000 where gate.isMutating(archive) {
            await Task.yield()
        }
    }

    // MARK: - tryRun

    func testTryRunRefusesASecondMutationOfTheSameArchive() async {
        let gate = ArchiveMutationGate()
        let archive = url("/tmp/a.zip")
        let latch = Latch()

        let first = gate.tryRun(archive: archive) { await latch.wait() }
        let second = gate.tryRun(archive: archive) { XCTFail("must not run while busy") }

        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second rewrite of the same archive must be refused")
        latch.open()
        await waitUntilFree(gate, archive)
    }

    func testTryRunAllowsMutatingTwoDifferentArchivesAtOnce() async {
        let gate = ArchiveMutationGate()
        let first = url("/tmp/a.zip")
        let second = url("/tmp/b.zip")
        let latch = Latch()

        let startedFirst = gate.tryRun(archive: first) { await latch.wait() }
        let startedSecond = gate.tryRun(archive: second) {}

        XCTAssertTrue(startedFirst)
        XCTAssertTrue(startedSecond, "different archives don't share a temp-then-swap, so they need not wait")
        latch.open()
        await waitUntilFree(gate, first)
    }

    func testTryRunAllowsANewMutationAfterThePreviousOneFinished() async {
        let gate = ArchiveMutationGate()
        let archive = url("/tmp/a.zip")
        let latch = Latch()

        XCTAssertTrue(gate.tryRun(archive: archive) { await latch.wait() })
        latch.open()
        await waitUntilFree(gate, archive)

        XCTAssertTrue(gate.tryRun(archive: archive) {}, "the gate must not stay latched after a mutation ends")
    }

    func testTryRunTreatsEquivalentPathsAsTheSameArchive() async {
        let gate = ArchiveMutationGate()
        let latch = Latch()

        XCTAssertTrue(gate.tryRun(archive: url("/tmp/a.zip")) { await latch.wait() })
        XCTAssertFalse(
            gate.tryRun(archive: url("/tmp/./a.zip")) { XCTFail("same file via another path") },
            "path spelling must not let a second rewrite through")

        latch.open()
        await waitUntilFree(gate, url("/tmp/a.zip"))
    }

    // MARK: - enqueue

    func testEnqueueWaitsForTheRunningMutationInsteadOfBeingDropped() async {
        let gate = ArchiveMutationGate()
        let archive = url("/tmp/a.zip")
        let latch = Latch()
        let recorder = Recorder()

        XCTAssertTrue(gate.tryRun(archive: archive) {
            await latch.wait()
            recorder.record("user-edit")
        })

        let queued = Task { @MainActor in
            try await gate.enqueue(archive: archive) { recorder.record("save-back") }
        }
        // Give the queued mutation a chance to (incorrectly) run early.
        await Task.yield()
        XCTAssertTrue(recorder.events.isEmpty)

        latch.open()
        try? await queued.value

        XCTAssertEqual(recorder.events, ["user-edit", "save-back"],
                       "a save-back must run after the in-flight edit, and must not be dropped")
    }

    func testEnqueuePropagatesFailuresToTheCaller() async {
        struct WriteFailure: Error {}
        let gate = ArchiveMutationGate()

        do {
            try await gate.enqueue(archive: url("/tmp/a.zip")) { throw WriteFailure() }
            XCTFail("the error must reach the caller so a failed save-back can be reported")
        } catch is WriteFailure {
            // Expected: the save-back flow relies on this to warn the user.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEnqueueRunsQueuedMutationsInOrder() async throws {
        let gate = ArchiveMutationGate()
        let archive = url("/tmp/a.zip")
        let latch = Latch()
        let recorder = Recorder()

        let first = Task { @MainActor in
            try await gate.enqueue(archive: archive) {
                await latch.wait()
                recorder.record("first")
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await gate.enqueue(archive: archive) { recorder.record("second") }
        }
        await Task.yield()

        latch.open()
        try await first.value
        try await second.value

        XCTAssertEqual(recorder.events, ["first", "second"])
    }

    func testEnqueueReturnsTheMutationResult() async throws {
        let gate = ArchiveMutationGate()
        let value = try await gate.enqueue(archive: url("/tmp/a.zip")) { 42 }
        XCTAssertEqual(value, 42)
    }

    // MARK: - cancel

    func testCancelCancelsTheRunningMutation() async {
        let gate = ArchiveMutationGate()
        let archive = url("/tmp/a.zip")
        let started = Latch()
        let recorder = Recorder()

        XCTAssertTrue(gate.tryRun(archive: archive) {
            started.open()
            // Stand in for a long 7zz pass that honours cancellation.
            while !Task.isCancelled { await Task.yield() }
            recorder.record("cancelled")
        })

        await started.wait()
        gate.cancel(archive: archive)
        await waitUntilFree(gate, archive)

        XCTAssertEqual(recorder.events, ["cancelled"])
    }

    func testCancelIgnoresArchivesWithNoRunningMutation() {
        let gate = ArchiveMutationGate()
        // Must not trap: the repack sheet can be dismissed after the work ended.
        gate.cancel(archive: url("/tmp/nothing-running.zip"))
        XCTAssertFalse(gate.isMutating(url("/tmp/nothing-running.zip")))
    }
}
