import Foundation
import XZIPDomain

public struct DestinationLeaseKey: Hashable, Codable, Sendable {
    public let parentIdentity: FileSystemIdentity
    public let normalizedName: String

    public init(parentIdentity: FileSystemIdentity, normalizedName: String) {
        self.parentIdentity = parentIdentity
        self.normalizedName = normalizedName
    }
}

public actor ArchiveLeaseRegistry {
    public enum ArchiveAccess: Hashable, Sendable {
        case read
        case write
    }

    private struct ArchiveClaim: Sendable {
        let archiveID: ArchiveID
        var access: ArchiveAccess
    }

    private struct LeaseRequest: Sendable {
        let archives: [ArchiveClaim]
        let destination: DestinationLeaseKey?
    }

    private struct LeaseToken: Sendable {
        let id: UUID
        let request: LeaseRequest
    }

    private struct ArchiveState {
        var readerCount = 0
        var hasWriter = false
    }

    private struct Waiter {
        let id: UUID
        let request: LeaseRequest
        let continuation: CheckedContinuation<LeaseToken, Error>
    }

    private var archiveStates: [ArchiveID: ArchiveState] = [:]
    private var activeDestinations: Set<DestinationLeaseKey> = []
    private var activeRequests: [UUID: LeaseRequest] = [:]
    private var waiters: [Waiter] = []

    public init() {}

    public func withLeases<T: Sendable>(
        archive: (ArchiveID, ArchiveAccess)?,
        destination: DestinationLeaseKey?,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withLeases(
            archives: archive.map { [$0] } ?? [],
            destination: destination,
            operation: operation
        )
    }

    func withLeases<T: Sendable>(
        archives: [(ArchiveID, ArchiveAccess)],
        destination: DestinationLeaseKey?,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let requestID = UUID()
        let request = LeaseRequest(
            archives: canonicalClaims(archives),
            destination: destination
        )
        let token = try await withTaskCancellationHandler {
            try await acquire(request, id: requestID)
        } onCancel: {
            Task { await self.cancelWaiter(id: requestID) }
        }

        defer { release(token) }
        try Task.checkCancellation()
        return try await operation()
    }

    func queuedWaiterCountForTesting(archiveID: ArchiveID) -> Int {
        waiters.reduce(into: 0) { count, waiter in
            if waiter.request.archives.contains(where: { $0.archiveID == archiveID }) {
                count += 1
            }
        }
    }

    func queuedWaiterCountForTesting(destination: DestinationLeaseKey) -> Int {
        waiters.reduce(into: 0) { count, waiter in
            if waiter.request.destination == destination {
                count += 1
            }
        }
    }

    func queuedWaiterCountForTesting() -> Int {
        waiters.count
    }

    func activeRequestCountForTesting() -> Int {
        activeRequests.count
    }


    func isArchiveActiveForTesting(_ archiveID: ArchiveID) -> Bool {
        archiveStates[archiveID] != nil
    }

    func isDestinationActiveForTesting(_ destination: DestinationLeaseKey) -> Bool {
        activeDestinations.contains(destination)
    }

    private func canonicalClaims(
        _ archives: [(ArchiveID, ArchiveAccess)]
    ) -> [ArchiveClaim] {
        var claims: [ArchiveClaim] = []
        var indices: [ArchiveID: Int] = [:]

        for (archiveID, access) in archives {
            if let index = indices[archiveID] {
                if access == .write {
                    claims[index].access = .write
                }
            } else {
                indices[archiveID] = claims.count
                claims.append(ArchiveClaim(archiveID: archiveID, access: access))
            }
        }
        return claims
    }

    private func acquire(_ request: LeaseRequest, id: UUID) async throws -> LeaseToken {
        if Task.isCancelled {
            throw CancellationError()
        }

        if canGrant(request), !waiters.contains(where: { conflicts($0.request, request) }) {
            let token = LeaseToken(id: id, request: request)
            activate(token)
            return token
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, request: request, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            grantEligibleWaiters()
            return
        }

        // If acquisition has not reached the actor yet, the original task's
        // cancellation state is observed by `acquire` before it can enqueue.
    }

    private func release(_ token: LeaseToken) {
        guard activeRequests.removeValue(forKey: token.id) != nil else { return }

        for claim in token.request.archives {
            guard var state = archiveStates[claim.archiveID] else { continue }
            switch claim.access {
            case .read:
                state.readerCount -= 1
            case .write:
                state.hasWriter = false
            }
            if state.readerCount == 0, !state.hasWriter {
                archiveStates.removeValue(forKey: claim.archiveID)
            } else {
                archiveStates[claim.archiveID] = state
            }
        }

        if let destination = token.request.destination {
            activeDestinations.remove(destination)
        }
        grantEligibleWaiters()
    }

    private func grantEligibleWaiters() {
        var grantedWaiter = true
        while grantedWaiter {
            grantedWaiter = false
            for index in waiters.indices {
                let waiter = waiters[index]
                guard canGrant(waiter.request) else { continue }
                guard !waiters[..<index].contains(where: {
                    conflicts($0.request, waiter.request)
                }) else { continue }

                waiters.remove(at: index)
                let token = LeaseToken(id: waiter.id, request: waiter.request)
                activate(token)
                waiter.continuation.resume(returning: token)
                grantedWaiter = true
                break
            }
        }
    }

    private func canGrant(_ request: LeaseRequest) -> Bool {
        if let destination = request.destination,
           activeDestinations.contains(destination) {
            return false
        }

        return request.archives.allSatisfy { claim in
            let state = archiveStates[claim.archiveID] ?? ArchiveState()
            switch claim.access {
            case .read:
                return !state.hasWriter
            case .write:
                return !state.hasWriter && state.readerCount == 0
            }
        }
    }

    private func conflicts(_ lhs: LeaseRequest, _ rhs: LeaseRequest) -> Bool {
        if let lhsDestination = lhs.destination,
           lhsDestination == rhs.destination {
            return true
        }

        for lhsClaim in lhs.archives {
            for rhsClaim in rhs.archives where lhsClaim.archiveID == rhsClaim.archiveID {
                if lhsClaim.access == .write || rhsClaim.access == .write {
                    return true
                }
            }
        }
        return false
    }

    private func activate(_ token: LeaseToken) {
        activeRequests[token.id] = token.request

        for claim in token.request.archives {
            var state = archiveStates[claim.archiveID] ?? ArchiveState()
            switch claim.access {
            case .read:
                state.readerCount += 1
            case .write:
                state.hasWriter = true
            }
            archiveStates[claim.archiveID] = state
        }

        if let destination = token.request.destination {
            activeDestinations.insert(destination)
        }
    }
}
