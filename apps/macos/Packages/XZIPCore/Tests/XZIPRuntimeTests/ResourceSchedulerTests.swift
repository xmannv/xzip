import Dispatch
import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

final class ResourceSchedulerTests: XCTestCase {
    func testGlobalCapQueuesUntilPermitRelease() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 2, metadata: 2, heavyPerVolume: 2),
            debugProbe: probe.record
        )
        let (first, firstID) = try await acquireAndExpect(
            .metadata(volumeIDs: []),
            scheduler: scheduler,
            probe: probe
        )
        let (second, _) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [1]),
            scheduler: scheduler,
            probe: probe
        )
        let thirdWorkload = ProcessWorkload.heavyIO(volumeIDs: [2])
        let third = Task {
            try await scheduler.acquire(.init(workload: thirdWorkload))
        }
        let thirdID = await expectSchedulerEvent(
            .enqueued,
            workload: thirdWorkload,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .waiting,
            workload: thirdWorkload,
            id: thirdID,
            from: probe
        )

        await first.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: .metadata(volumeIDs: []),
            id: firstID,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .granted,
            workload: thirdWorkload,
            id: thirdID,
            from: probe
        )

        let thirdPermit = try await third.value
        await second.release()
        await thirdPermit.release()
    }

    func testMetadataLaneDoesNotBlockIndependentHeavyIO() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 2, metadata: 1, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let (firstMetadata, firstID) = try await acquireAndExpect(
            .metadata(volumeIDs: [1]),
            scheduler: scheduler,
            probe: probe
        )
        let secondWorkload = ProcessWorkload.metadata(volumeIDs: [2])
        let secondMetadata = Task {
            try await scheduler.acquire(.init(workload: secondWorkload))
        }
        let secondID = await expectSchedulerEvent(
            .enqueued,
            workload: secondWorkload,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .waiting,
            workload: secondWorkload,
            id: secondID,
            from: probe
        )

        let (heavy, heavyID) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [3]),
            scheduler: scheduler,
            probe: probe
        )
        await heavy.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: .heavyIO(volumeIDs: [3]),
            id: heavyID,
            from: probe
        )
        await firstMetadata.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: .metadata(volumeIDs: [1]),
            id: firstID,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .granted,
            workload: secondWorkload,
            id: secondID,
            from: probe
        )

        let secondMetadataPermit = try await secondMetadata.value
        await secondMetadataPermit.release()
    }

    func testPerVolumeCapAllowsDifferentVolumesAndQueuesSameVolume() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 3, metadata: 3, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let (first, firstID) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [11]),
            scheduler: scheduler,
            probe: probe
        )
        let sameWorkload = ProcessWorkload.heavyIO(volumeIDs: [11])
        let sameVolume = Task {
            try await scheduler.acquire(.init(workload: sameWorkload))
        }
        let sameID = await expectSchedulerEvent(
            .enqueued,
            workload: sameWorkload,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .waiting,
            workload: sameWorkload,
            id: sameID,
            from: probe
        )

        let (differentVolume, _) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [12]),
            scheduler: scheduler,
            probe: probe
        )
        await first.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: .heavyIO(volumeIDs: [11]),
            id: firstID,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .granted,
            workload: sameWorkload,
            id: sameID,
            from: probe
        )

        await differentVolume.release()
        let sameVolumePermit = try await sameVolume.value
        await sameVolumePermit.release()
    }

    func testConflictingWaitersAreGrantedFIFO() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 1, metadata: 1, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let workload = ProcessWorkload.heavyIO(volumeIDs: [1])
        let (holder, holderID) = try await acquireAndExpect(
            workload,
            scheduler: scheduler,
            probe: probe
        )
        let first = Task { try await scheduler.acquire(.init(workload: workload)) }
        let firstID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: firstID, from: probe)
        let second = Task { try await scheduler.acquire(.init(workload: workload)) }
        let secondID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: secondID, from: probe)

        await holder.release()
        _ = await expectSchedulerEvent(.released, workload: workload, id: holderID, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: firstID, from: probe)

        let firstPermit = try await first.value
        await firstPermit.release()
        _ = await expectSchedulerEvent(.released, workload: workload, id: firstID, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: secondID, from: probe)
        let secondPermit = try await second.value
        await secondPermit.release()
    }

    func testMultiVolumeClaimsAreAtomicOrderedAndFair() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 4, metadata: 4, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let (volumeOne, volumeOneID) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [1]),
            scheduler: scheduler,
            probe: probe
        )
        let multiWorkload = ProcessWorkload.heavyIO(volumeIDs: [1, 2])
        let multi = Task { try await scheduler.acquire(.init(workload: multiWorkload)) }
        let multiID = await expectSchedulerEvent(.enqueued, workload: multiWorkload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: multiWorkload, id: multiID, from: probe)

        let volumeTwoWorkload = ProcessWorkload.heavyIO(volumeIDs: [2])
        let volumeTwo = Task {
            try await scheduler.acquire(.init(workload: volumeTwoWorkload))
        }
        let volumeTwoID = await expectSchedulerEvent(
            .enqueued,
            workload: volumeTwoWorkload,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .waiting,
            workload: volumeTwoWorkload,
            id: volumeTwoID,
            from: probe
        )
        let (volumeThree, _) = try await acquireAndExpect(
            .heavyIO(volumeIDs: [3]),
            scheduler: scheduler,
            probe: probe
        )

        await volumeOne.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: .heavyIO(volumeIDs: [1]),
            id: volumeOneID,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .granted,
            workload: multiWorkload,
            id: multiID,
            from: probe
        )

        let multiPermit = try await multi.value
        await multiPermit.release()
        _ = await expectSchedulerEvent(
            .released,
            workload: multiWorkload,
            id: multiID,
            from: probe
        )
        _ = await expectSchedulerEvent(
            .granted,
            workload: volumeTwoWorkload,
            id: volumeTwoID,
            from: probe
        )

        await volumeThree.release()
        let volumeTwoPermit = try await volumeTwo.value
        await volumeTwoPermit.release()
    }

    func testQueuedCancellationRemovesWaiterAndWakesNextEligible() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 1, metadata: 1, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let workload = ProcessWorkload.metadata(volumeIDs: [])
        let (holder, holderID) = try await acquireAndExpect(
            workload,
            scheduler: scheduler,
            probe: probe
        )
        let cancelled = Task { try await scheduler.acquire(.init(workload: workload)) }
        let cancelledID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: cancelledID, from: probe)
        let next = Task { try await scheduler.acquire(.init(workload: workload)) }
        let nextID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: nextID, from: probe)

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        _ = await expectSchedulerEvent(
            .cancelled,
            workload: workload,
            id: cancelledID,
            from: probe
        )

        await holder.release()
        _ = await expectSchedulerEvent(.released, workload: workload, id: holderID, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: nextID, from: probe)
        let nextPermit = try await next.value
        await nextPermit.release()
    }

    func testPermitReleaseIsIdempotent() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 1, metadata: 1, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let workload = ProcessWorkload.heavyIO(volumeIDs: [7])
        let (holder, holderID) = try await acquireAndExpect(
            workload,
            scheduler: scheduler,
            probe: probe
        )
        let first = Task { try await scheduler.acquire(.init(workload: workload)) }
        let firstID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: firstID, from: probe)

        await holder.release()
        _ = await expectSchedulerEvent(.released, workload: workload, id: holderID, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: firstID, from: probe)
        let firstPermit = try await first.value
        let second = Task { try await scheduler.acquire(.init(workload: workload)) }
        let secondID = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.waiting, workload: workload, id: secondID, from: probe)

        await holder.release()
        let snapshot = await scheduler.debugSnapshot()
        XCTAssertEqual(snapshot.activeGlobalCount, 1)
        XCTAssertEqual(snapshot.waiterCount, 1)

        await firstPermit.release()
        _ = await expectSchedulerEvent(.released, workload: workload, id: firstID, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: secondID, from: probe)
        let secondPermit = try await second.value
        await secondPermit.release()
    }

    func testGrantCancellationRaceReleasesActivatedClaimExactlyOnce() async throws {
        let probe = SchedulerProbe(blockNextGrant: true)
        let scheduler = ResourceScheduler(
            policy: policy(global: 1, metadata: 1, heavyPerVolume: 1),
            debugProbe: probe.record
        )
        let workload = ProcessWorkload.heavyIO(volumeIDs: [9])
        let acquiring = Task { try await scheduler.acquire(.init(workload: workload)) }
        let id = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        _ = await expectSchedulerEvent(.granted, workload: workload, id: id, from: probe)

        acquiring.cancel()
        probe.openGrantGate()
        do {
            _ = try await acquiring.value
            XCTFail("Expected cancellation after grant")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        _ = await expectSchedulerEvent(.released, workload: workload, id: id, from: probe)

        let (next, _) = try await acquireAndExpect(
            workload,
            scheduler: scheduler,
            probe: probe
        )
        await next.release()
    }

    func testNonpositivePolicyCapsNormalizeToOne() async throws {
        let probe = SchedulerProbe()
        let scheduler = ResourceScheduler(
            policy: policy(global: 0, metadata: -1, heavyPerVolume: 0),
            debugProbe: probe.record
        )
        let workload = ProcessWorkload.metadata(volumeIDs: [])
        let acquiring = Task { try await scheduler.acquire(.init(workload: workload)) }
        let id = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
        let nextEvent = await probe.next()
        let nextKind = schedulerEventParts(nextEvent).kind
        XCTAssertEqual(nextKind, .granted)

        if nextKind == .granted {
            let parts = schedulerEventParts(nextEvent)
            XCTAssertEqual(parts.id, id)
            XCTAssertEqual(parts.workload, workload)
            let permit = try await acquiring.value
            await permit.release()
        } else {
            acquiring.cancel()
            _ = try? await acquiring.value
        }
    }
}

private enum SchedulerEventKind: Equatable {
    case enqueued
    case waiting
    case granted
    case cancelled
    case released
}

private final class SchedulerProbe: @unchecked Sendable {
    private let continuation: AsyncStream<ResourceScheduler.DebugEvent>.Continuation
    private let reader: SchedulerProbeReader
    private let lock = NSLock()
    private var shouldBlockNextGrant: Bool
    private let grantGate: DispatchSemaphore?

    init(blockNextGrant: Bool = false) {
        let pair = AsyncStream<ResourceScheduler.DebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        reader = SchedulerProbeReader(stream: pair.stream)
        shouldBlockNextGrant = blockNextGrant
        grantGate = blockNextGrant ? DispatchSemaphore(value: 0) : nil
    }

    func record(_ event: ResourceScheduler.DebugEvent) {
        continuation.yield(event)
        guard case .granted = event else { return }

        lock.lock()
        let shouldBlock = shouldBlockNextGrant
        shouldBlockNextGrant = false
        lock.unlock()
        if shouldBlock {
            grantGate?.wait()
        }
    }

    func next() async -> ResourceScheduler.DebugEvent {
        await reader.next()
    }

    func openGrantGate() {
        grantGate?.signal()
    }
}

private actor SchedulerProbeReader {
    private var bufferedEvents: [ResourceScheduler.DebugEvent] = []
    private var waiters: [CheckedContinuation<ResourceScheduler.DebugEvent, Never>] = []

    init(stream: AsyncStream<ResourceScheduler.DebugEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }

    private func record(_ event: ResourceScheduler.DebugEvent) {
        if waiters.isEmpty {
            bufferedEvents.append(event)
        } else {
            waiters.removeFirst().resume(returning: event)
        }
    }

    func next() async -> ResourceScheduler.DebugEvent {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func acquireAndExpect(
    _ workload: ProcessWorkload,
    scheduler: ResourceScheduler,
    probe: SchedulerProbe
) async throws -> (ProcessPermit, UUID) {
    let permit = try await scheduler.acquire(.init(workload: workload))
    let id = await expectSchedulerEvent(.enqueued, workload: workload, from: probe)
    _ = await expectSchedulerEvent(.granted, workload: workload, id: id, from: probe)
    return (permit, id)
}

@discardableResult
private func expectSchedulerEvent(
    _ kind: SchedulerEventKind,
    workload: ProcessWorkload,
    id expectedID: UUID? = nil,
    from probe: SchedulerProbe,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> UUID {
    let parts = schedulerEventParts(await probe.next())
    XCTAssertEqual(parts.kind, kind, file: file, line: line)
    XCTAssertEqual(parts.workload, workload, file: file, line: line)
    if let expectedID {
        XCTAssertEqual(parts.id, expectedID, file: file, line: line)
    }
    return parts.id
}

private func schedulerEventParts(
    _ event: ResourceScheduler.DebugEvent
) -> (kind: SchedulerEventKind, id: UUID, workload: ProcessWorkload) {
    switch event {
    case let .enqueued(id, workload):
        return (.enqueued, id, workload)
    case let .waiting(id, workload):
        return (.waiting, id, workload)
    case let .granted(id, workload):
        return (.granted, id, workload)
    case let .cancelled(id, workload):
        return (.cancelled, id, workload)
    case let .released(id, workload):
        return (.released, id, workload)
    }
}

private func policy(
    global: Int,
    metadata: Int,
    heavyPerVolume: Int
) -> ArchiveResourcePolicy {
    let base = ArchiveResourcePolicy.production
    return ArchiveResourcePolicy(
        listing: base.listing,
        output: base.output,
        process: base.process,
        cache: base.cache,
        split: base.split,
        command: base.command,
        journal: base.journal,
        scheduling: .init(
            globalProcessLimit: global,
            metadataProcessLimit: metadata,
            heavyIOPerVolumeLimit: heavyPerVolume
        )
    )
}
