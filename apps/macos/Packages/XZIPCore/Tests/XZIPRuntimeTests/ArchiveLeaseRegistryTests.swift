import XCTest
import XZIPDomain
@testable import XZIPRuntime

private actor AsyncTestSignal {
    private var signalCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        signalCount += 1
        let ready = waiters.filter { $0.0 <= signalCount }
        waiters.removeAll { $0.0 <= signalCount }
        ready.forEach { $0.1.resume() }
    }

    func wait(until target: Int) async {
        if signalCount >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    func currentCount() -> Int { signalCount }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor StringLog {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}

private func archiveID(_ value: UInt64) -> ArchiveID {
    ArchiveID(identity: .stable(
        volumeIdentifier: 1,
        fileIdentifier: value,
        generation: 1
    ))
}

private func waitUntilQueued(
    _ expected: Int,
    archiveID: ArchiveID,
    registry: ArchiveLeaseRegistry
) async {
    for _ in 0..<10_000 {
        if await registry.queuedWaiterCountForTesting(archiveID: archiveID) == expected {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(expected) queued archive waiters")
}

private func waitUntilQueued(
    _ expected: Int,
    destination: DestinationLeaseKey,
    registry: ArchiveLeaseRegistry
) async {
    for _ in 0..<10_000 {
        if await registry.queuedWaiterCountForTesting(destination: destination) == expected {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(expected) queued destination waiters")
}

private func waitUntilActive(
    _ expected: Int,
    registry: ArchiveLeaseRegistry
) async {
    for _ in 0..<10_000 {
        if await registry.activeRequestCountForTesting() == expected {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(expected) active lease requests")
}

private enum LeaseProbeError: Error {
    case expected
}

final class ArchiveLeaseRegistryTests: XCTestCase {
    func testReadersForSameArchiveEnterConcurrently() async throws {
        let registry = ArchiveLeaseRegistry()
        let id = archiveID(1)
        let entered = AsyncTestSignal()
        let release = AsyncTestGate()

        async let first: Void = try registry.withLeases(
            archive: (id, .read), destination: nil
        ) {
            await entered.signal()
            await release.wait()
        }
        async let second: Void = try registry.withLeases(
            archive: (id, .read), destination: nil
        ) {
            await entered.signal()
            await release.wait()
        }

        await entered.wait(until: 2)
        await release.open()
        _ = try await (first, second)
    }

    func testWriterWaitsForAllReaders() async throws {
        let registry = ArchiveLeaseRegistry()
        let id = archiveID(2)
        let readersEntered = AsyncTestSignal()
        let releaseReaders = AsyncTestGate()
        let writerEntered = AsyncTestSignal()

        let readerTasks = (0..<2).map { _ in
            Task {
                try await registry.withLeases(archive: (id, .read), destination: nil) {
                    await readersEntered.signal()
                    await releaseReaders.wait()
                }
            }
        }
        await readersEntered.wait(until: 2)
        let writer = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {
                await writerEntered.signal()
            }
        }
        await waitUntilQueued(1, archiveID: id, registry: registry)
        let queuedWriterCount = await registry.queuedWaiterCountForTesting(archiveID: id)
        XCTAssertEqual(queuedWriterCount, 1)

        await releaseReaders.open()
        for task in readerTasks { try await task.value }
        try await writer.value
        await writerEntered.wait(until: 1)
    }

    func testDifferentArchivesRunInParallel() async throws {
        let registry = ArchiveLeaseRegistry()
        let entered = AsyncTestSignal()
        let release = AsyncTestGate()

        async let first: Void = try registry.withLeases(
            archive: (archiveID(3), .write), destination: nil
        ) {
            await entered.signal()
            await release.wait()
        }
        async let second: Void = try registry.withLeases(
            archive: (archiveID(4), .write), destination: nil
        ) {
            await entered.signal()
            await release.wait()
        }

        await entered.wait(until: 2)
        await release.open()
        _ = try await (first, second)
    }

    func testDestinationLeaseIsExclusive() async throws {
        let registry = ArchiveLeaseRegistry()
        let destination = DestinationLeaseKey(
            parentIdentity: .stable(volumeIdentifier: 9, fileIdentifier: 9, generation: 1),
            normalizedName: "output.zip"
        )
        let firstEntered = AsyncTestSignal()
        let secondEntered = AsyncTestSignal()
        let release = AsyncTestGate()

        let first = Task {
            try await registry.withLeases(archive: nil, destination: destination) {
                await firstEntered.signal()
                await release.wait()
            }
        }
        await firstEntered.wait(until: 1)
        let second = Task {
            try await registry.withLeases(archive: nil, destination: destination) {
                await secondEntered.signal()
            }
        }
        await waitUntilQueued(1, destination: destination, registry: registry)
        let secondCount = await secondEntered.currentCount()
        XCTAssertEqual(secondCount, 0)

        await release.open()
        try await first.value
        try await second.value
        await secondEntered.wait(until: 1)
    }

    func testArchiveWriterWaitersAreFIFO() async throws {
        let registry = ArchiveLeaseRegistry()
        let id = archiveID(5)
        let blockerEntered = AsyncTestSignal()
        let release = AsyncTestGate()
        let log = StringLog()

        let blocker = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {
                await blockerEntered.signal()
                await release.wait()
            }
        }
        await blockerEntered.wait(until: 1)
        let first = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {
                await log.append("first")
            }
        }
        await waitUntilQueued(1, archiveID: id, registry: registry)
        let second = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {
                await log.append("second")
            }
        }
        await waitUntilQueued(2, archiveID: id, registry: registry)

        await release.open()
        try await blocker.value
        try await first.value
        try await second.value
        let values = await log.values()
        XCTAssertEqual(values, ["first", "second"])
    }

    func testCancelledWaiterIsRemovedAndDoesNotBlockNextWriter() async throws {
        let registry = ArchiveLeaseRegistry()
        let id = archiveID(6)
        let blockerEntered = AsyncTestSignal()
        let release = AsyncTestGate()

        let blocker = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {
                await blockerEntered.signal()
                await release.wait()
            }
        }
        await blockerEntered.wait(until: 1)
        let cancelled = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {}
        }
        await waitUntilQueued(1, archiveID: id, registry: registry)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        await waitUntilQueued(0, archiveID: id, registry: registry)

        let successor = Task {
            try await registry.withLeases(archive: (id, .write), destination: nil) {}
        }
        await waitUntilQueued(1, archiveID: id, registry: registry)
        await release.open()
        try await blocker.value
        try await successor.value
    }

    func testCombinedClaimDoesNotPartiallyAcquireWhileQueued() async throws {
        let registry = ArchiveLeaseRegistry()
        let blockedArchive = archiveID(7)
        let disjointArchive = archiveID(8)
        let destination = DestinationLeaseKey(
            parentIdentity: .stable(volumeIdentifier: 9, fileIdentifier: 10, generation: 1),
            normalizedName: "combined.zip"
        )
        let blockerEntered = AsyncTestSignal()
        let combinedEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()

        let blocker = Task {
            try await registry.withLeases(archive: (blockedArchive, .write), destination: nil) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let combined = Task {
            try await registry.withLeases(
                archives: [(blockedArchive, .read), (disjointArchive, .write)],
                destination: destination
            ) {
                await combinedEntered.signal()
            }
        }
        await waitUntilQueued(1, archiveID: blockedArchive, registry: registry)

        let activeCount = await registry.activeRequestCountForTesting()
        let disjointArchiveIsActive = await registry.isArchiveActiveForTesting(disjointArchive)
        let destinationIsActive = await registry.isDestinationActiveForTesting(destination)
        let combinedCountBeforeRelease = await combinedEntered.currentCount()
        XCTAssertEqual(activeCount, 1)
        XCTAssertFalse(disjointArchiveIsActive)
        XCTAssertFalse(destinationIsActive)
        XCTAssertEqual(combinedCountBeforeRelease, 0)

        await releaseBlocker.open()
        try await blocker.value
        try await combined.value
        let combinedCountAfterRelease = await combinedEntered.currentCount()
        XCTAssertEqual(combinedCountAfterRelease, 1)
        await waitUntilActive(0, registry: registry)
    }

    func testCancelledCombinedWaiterLeavesNoQueuedOrActiveRequest() async throws {
        let registry = ArchiveLeaseRegistry()
        let blockedArchive = archiveID(9)
        let secondArchive = archiveID(10)
        let destination = DestinationLeaseKey(
            parentIdentity: .stable(volumeIdentifier: 9, fileIdentifier: 11, generation: 1),
            normalizedName: "cancelled.zip"
        )
        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()

        let blocker = Task {
            try await registry.withLeases(archive: (blockedArchive, .write), destination: nil) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)
        let cancelled = Task {
            try await registry.withLeases(
                archives: [(blockedArchive, .read), (secondArchive, .write)],
                destination: destination
            ) {}
        }
        await waitUntilQueued(1, destination: destination, registry: registry)

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        await waitUntilQueued(0, destination: destination, registry: registry)
        let queuedCount = await registry.queuedWaiterCountForTesting()
        let activeCount = await registry.activeRequestCountForTesting()
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(activeCount, 1)

        await releaseBlocker.open()
        try await blocker.value
        await waitUntilActive(0, registry: registry)
    }

    func testCombinedClaimReleasesEveryResourceAfterOperationError() async throws {
        let registry = ArchiveLeaseRegistry()
        let firstArchive = archiveID(11)
        let secondArchive = archiveID(12)
        let destination = DestinationLeaseKey(
            parentIdentity: .stable(volumeIdentifier: 9, fileIdentifier: 12, generation: 1),
            normalizedName: "error.zip"
        )

        do {
            try await registry.withLeases(
                archives: [(firstArchive, .read), (secondArchive, .write)],
                destination: destination
            ) {
                throw LeaseProbeError.expected
            }
            XCTFail("Expected operation error")
        } catch LeaseProbeError.expected {}
        await waitUntilActive(0, registry: registry)

        let entered = AsyncTestSignal()
        async let firstProbe: Void = try registry.withLeases(
            archive: (firstArchive, .write), destination: nil
        ) {
            await entered.signal()
        }
        async let secondProbe: Void = try registry.withLeases(
            archive: (secondArchive, .write), destination: destination
        ) {
            await entered.signal()
        }
        await entered.wait(until: 2)
        _ = try await (firstProbe, secondProbe)
        await waitUntilActive(0, registry: registry)
    }
}
