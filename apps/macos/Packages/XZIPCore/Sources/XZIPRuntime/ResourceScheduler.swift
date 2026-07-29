import Foundation
import XZIPCore
import XZIPDomain

public actor ResourceScheduler: ProcessPermitAcquiring {
    enum DebugEvent: Equatable, Sendable {
        case enqueued(UUID, ProcessWorkload)
        case waiting(UUID, ProcessWorkload)
        case granted(UUID, ProcessWorkload)
        case cancelled(UUID, ProcessWorkload)
        case released(UUID, ProcessWorkload)
    }

    struct DebugSnapshot: Equatable, Sendable {
        let activeGlobalCount: Int
        let activeMetadataCount: Int
        let activeHeavyIOCounts: [UInt64: Int]
        let waiterCount: Int
    }

    private enum Lane: Sendable {
        case metadata
        case heavyIO
    }

    private struct Claim: Sendable {
        let lane: Lane
        let volumeIDs: [UInt64]

        var workload: ProcessWorkload {
            let volumes = Set(volumeIDs)
            switch lane {
            case .metadata:
                return .metadata(volumeIDs: volumes)
            case .heavyIO:
                return .heavyIO(volumeIDs: volumes)
            }
        }
    }

    private struct Waiter {
        let id: UUID
        let claim: Claim
        let continuation: CheckedContinuation<ProcessPermit, Error>
    }

    private let globalLimit: Int
    private let metadataLimit: Int
    private let heavyIOPerVolumeLimit: Int
    private let debugProbe: (@Sendable (DebugEvent) -> Void)?
    private var activeGlobalCount = 0
    private var activeMetadataCount = 0
    private var activeHeavyIOCounts: [UInt64: Int] = [:]
    private var activeClaims: [UUID: Claim] = [:]
    private var waiters: [Waiter] = []

    public init(policy: ArchiveResourcePolicy) {
        globalLimit = max(1, policy.scheduling.globalProcessLimit)
        metadataLimit = max(1, policy.scheduling.metadataProcessLimit)
        heavyIOPerVolumeLimit = max(1, policy.scheduling.heavyIOPerVolumeLimit)
        debugProbe = nil
    }

    init(
        policy: ArchiveResourcePolicy,
        debugProbe: (@Sendable (DebugEvent) -> Void)?
    ) {
        globalLimit = max(1, policy.scheduling.globalProcessLimit)
        metadataLimit = max(1, policy.scheduling.metadataProcessLimit)
        heavyIOPerVolumeLimit = max(1, policy.scheduling.heavyIOPerVolumeLimit)
        self.debugProbe = debugProbe
    }

    public func acquire(_ request: ProcessPermitRequest) async throws -> ProcessPermit {
        let id = UUID()
        let claim = canonicalClaim(for: request.workload)
        let permit = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, claim: claim, continuation: continuation))
                debugProbe?(.enqueued(id, claim.workload))
                grantEligibleWaiters()
                if waiters.contains(where: { $0.id == id }) {
                    debugProbe?(.waiting(id, claim.workload))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }

        if Task.isCancelled {
            await permit.release()
            throw CancellationError()
        }
        return permit
    }

    func debugSnapshot() -> DebugSnapshot {
        DebugSnapshot(
            activeGlobalCount: activeGlobalCount,
            activeMetadataCount: activeMetadataCount,
            activeHeavyIOCounts: activeHeavyIOCounts,
            waiterCount: waiters.count
        )
    }

    private func canonicalClaim(for workload: ProcessWorkload) -> Claim {
        switch workload {
        case let .metadata(volumeIDs):
            return Claim(lane: .metadata, volumeIDs: volumeIDs.sorted())
        case let .heavyIO(volumeIDs):
            return Claim(lane: .heavyIO, volumeIDs: volumeIDs.sorted())
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            debugProbe?(.cancelled(id, waiter.claim.workload))
            waiter.continuation.resume(throwing: CancellationError())
            grantEligibleWaiters()
            return
        }

        if activeClaims[id] != nil {
            release(id: id)
        }
    }

    private func release(id: UUID) {
        guard let claim = activeClaims.removeValue(forKey: id) else { return }
        activeGlobalCount -= 1

        switch claim.lane {
        case .metadata:
            activeMetadataCount -= 1
        case .heavyIO:
            for volumeID in claim.volumeIDs {
                let remaining = (activeHeavyIOCounts[volumeID] ?? 0) - 1
                if remaining == 0 {
                    activeHeavyIOCounts.removeValue(forKey: volumeID)
                } else {
                    activeHeavyIOCounts[volumeID] = remaining
                }
            }
        }

        debugProbe?(.released(id, claim.workload))
        grantEligibleWaiters()
    }

    private func grantEligibleWaiters() {
        var granted = true
        while granted {
            granted = false
            for index in waiters.indices {
                let waiter = waiters[index]
                guard canGrant(waiter.claim) else { continue }
                guard !waiters[..<index].contains(where: {
                    conflicts($0.claim, waiter.claim)
                }) else { continue }

                waiters.remove(at: index)
                activate(waiter.claim, id: waiter.id)
                let permit = ProcessPermit { [weak self] in
                    await self?.release(id: waiter.id)
                }
                debugProbe?(.granted(waiter.id, waiter.claim.workload))
                waiter.continuation.resume(returning: permit)
                granted = true
                break
            }
        }
    }

    private func canGrant(_ claim: Claim) -> Bool {
        guard activeGlobalCount < globalLimit else { return false }

        switch claim.lane {
        case .metadata:
            return activeMetadataCount < metadataLimit
        case .heavyIO:
            return claim.volumeIDs.allSatisfy {
                (activeHeavyIOCounts[$0] ?? 0) < heavyIOPerVolumeLimit
            }
        }
    }

    private func conflicts(_ lhs: Claim, _ rhs: Claim) -> Bool {
        switch (lhs.lane, rhs.lane) {
        case (.metadata, .metadata):
            return true
        case (.heavyIO, .heavyIO):
            return !Set(lhs.volumeIDs).isDisjoint(with: rhs.volumeIDs)
        case (.metadata, .heavyIO), (.heavyIO, .metadata):
            return false
        }
    }

    private func activate(_ claim: Claim, id: UUID) {
        activeClaims[id] = claim
        activeGlobalCount += 1

        switch claim.lane {
        case .metadata:
            activeMetadataCount += 1
        case .heavyIO:
            for volumeID in claim.volumeIDs {
                activeHeavyIOCounts[volumeID, default: 0] += 1
            }
        }
    }
}
