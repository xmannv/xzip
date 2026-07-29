import Darwin
import Foundation
import XZIPCore
import XZIPDomain

public protocol ArchiveRuntimeClient: Sendable {
    func openArchive(at url: URL) async throws -> ArchiveLocator
    func executeOperation(_ descriptor: OperationDescriptor) async throws
}

enum ArchiveRuntimeValidationError: Error, Equatable, Sendable {
    case archiveIDRequired
    case unexpectedArchiveID
    case sessionRequiresArchive
    case payloadArchiveMismatch
    case editSessionArchiveMismatch
    case invalidCompressionFormat(String)
    case invalidCompressionLevel(Int)
    case duplicateOperationID
    case transactionalExtractionRequired
}

private struct DestinationSnapshot: Equatable, Sendable {
    let key: DestinationLeaseKey
    let existingArchiveID: ArchiveID?
}

private final class OperationLifecycle: @unchecked Sendable {
    private enum State {
        case active
        case cancelled
        case succeeded
        case failed
    }

    private let lock = NSLock()
    private var state = State.active

    func requestCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return false }
        state = .cancelled
        return true
    }

    func finalizeSuccess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return false }
        state = .succeeded
        return true
    }

    func finalizeCommittedSuccess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active || state == .cancelled else { return false }
        state = .succeeded
        return true
    }

    func finalizeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return false }
        state = .failed
        return true
    }

    func finalizeRollbackFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active || state == .cancelled else { return false }
        state = .failed
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }
}

private final class OperationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private enum OperationExecutionOutcome: Sendable {
    case ordinary(OperationResult?)
    case committed(
        result: OperationResult,
        postTerminalFinalizer: @Sendable () async throws -> Void
    )
}

private struct OperationOwnership {
    let reservationID: UUID
    let lifecycle: OperationLifecycle
    let startGate: OperationStartGate
    let task: Task<OperationExecutionOutcome, Error>
}

public actor ArchiveRuntime: ArchiveRuntimeClient, ArchiveRuntimeObserving,
    ArchiveExtractionPreflighting
{
    enum DebugEvent: Equatable, Sendable {
        case ownershipReserved(OperationID)
        case permitGranted(OperationID)
        case stateChanged(OperationID, OperationState)
        case cancellationRequested(OperationID)
        case finalized(OperationID, OperationState)
        case ownershipRemoved(OperationID)
    }

    private enum SchedulingLane {
        case metadata
        case heavyIO
    }

    private let backend: any ArchiveBackend
    private let identityResolver: any ArchiveIdentityResolving
    private let policy: ArchiveResourcePolicy
    private let leases: ArchiveLeaseRegistry
    private let cache: CompatibilityArchiveCache
    private let scheduler: ResourceScheduler
    private let observations: OperationObservationStore
    private let volumeIdentifierProvider: @Sendable (URL) throws -> UInt64
    private let debugProbe: (@Sendable (DebugEvent) -> Void)?
    private let replacementWorkspaceProvider: @Sendable (URL) throws -> URL
    private let extractionHandler: (any ArchiveExtractionHandling)?
    private var operationTasks: [OperationID: OperationOwnership] = [:]

    public init(
        backend: any ArchiveBackend,
        identityResolver: any ArchiveIdentityResolving,
        policy: ArchiveResourcePolicy = .production,
        leases: ArchiveLeaseRegistry = ArchiveLeaseRegistry()
    ) {
        self.backend = backend
        self.identityResolver = identityResolver
        self.policy = policy
        self.leases = leases
        self.cache = CompatibilityArchiveCache(
            listingWeightBudget: policy.cache.weightBudget
        )
        self.scheduler = ResourceScheduler(policy: policy)
        self.observations = OperationObservationStore(
            policy: .init(maximumRecordCount: 256)
        )
        self.volumeIdentifierProvider = {
            try ArchiveIdentityResolver().stableVolumeIdentifier(for: $0)
        }
        self.debugProbe = nil
        self.replacementWorkspaceProvider = { archive in
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: archive,
                create: true
            )
        }
        self.extractionHandler = nil
    }


    init(
        backend: any ArchiveBackend,
        identityResolver: any ArchiveIdentityResolving,
        policy: ArchiveResourcePolicy = .production,
        leases: ArchiveLeaseRegistry = ArchiveLeaseRegistry(),
        scheduler: ResourceScheduler? = nil,
        observationPolicy: OperationObservationStore.Policy = .init(
            maximumRecordCount: 256
        ),
        volumeIdentifierProvider: @escaping @Sendable (URL) throws -> UInt64 = {
            try ArchiveIdentityResolver().stableVolumeIdentifier(for: $0)
        },
        debugProbe: (@Sendable (DebugEvent) -> Void)? = nil,
        replacementWorkspaceProvider: @escaping @Sendable (URL) throws -> URL = { archive in
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: archive,
                create: true
            )
        },
        extractionHandler: (any ArchiveExtractionHandling)? = nil
    ) {
        self.backend = backend
        self.identityResolver = identityResolver
        self.policy = policy
        self.leases = leases
        self.cache = CompatibilityArchiveCache(
            listingWeightBudget: policy.cache.weightBudget
        )
        self.scheduler = scheduler ?? ResourceScheduler(policy: policy)
        self.observations = OperationObservationStore(policy: observationPolicy)
        self.volumeIdentifierProvider = volumeIdentifierProvider
        self.debugProbe = debugProbe
        self.replacementWorkspaceProvider = replacementWorkspaceProvider
        self.extractionHandler = extractionHandler
    }

    public func openArchive(at url: URL) async throws -> ArchiveLocator {
        try identityResolver.resolve(url).locator
    }

    public func preflightExtraction(
        _ request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight {
        try validateConflictPolicy(request.conflictPolicy)
        guard let extractionHandler else {
            if request.conflictPolicy == .replace {
                throw ArchiveFailure.destructiveReplacementApprovalRequired
            }
            throw ArchiveFailure.brokerUnavailable
        }

        let archiveReference = OperationResourceReference(
            identity: request.archive.archiveID.identity,
            url: request.archive.url
        )
        let destinationReference = OperationResourceReference(
            identity: nil,
            url: request.destination
        )
        let archiveID = request.archive.archiveID
        guard try identityResolver.resolve(request.archive.url).locator.archiveID == archiveID else {
            throw ArchiveFailure.archiveChanged
        }
        let destination = try destinationSnapshot(for: destinationReference)
        guard destination.existingArchiveID != nil else {
            throw ArchiveFailure.destinationConflict(path: request.destination.path)
        }
        var archiveClaims: [(ArchiveID, ArchiveLeaseRegistry.ArchiveAccess)] = [
            (archiveID, .read)
        ]
        if let destinationArchiveID = destination.existingArchiveID {
            archiveClaims.append((destinationArchiveID, .write))
        }
        let resolver = identityResolver

        return try await leases.withLeases(
            archives: archiveClaims,
            destination: destination.key
        ) {
            _ = try resolveArchive(
                archiveReference,
                expectedID: archiveID,
                resolver: resolver
            )
            try validateDestinationSnapshot(
                destination,
                reference: destinationReference,
                conflictPolicy: request.conflictPolicy
            )
            return try await executeExtractionPreflightWithPermit(
                resources: [archiveReference, destinationReference],
                operationID: request.operationID
            ) {
                try await extractionHandler.preflight(request: request)
            }
        }
    }

    public func executeOperation(_ descriptor: OperationDescriptor) async throws {
        let operationID = descriptor.operationID
        guard operationTasks[operationID] == nil else {
            throw ArchiveRuntimeValidationError.duplicateOperationID
        }

        let reservationID = UUID()
        let lifecycle = OperationLifecycle()
        let startGate = OperationStartGate()
        let observations = self.observations
        let debugProbe = self.debugProbe
        let operationTask = Task { () throws -> OperationExecutionOutcome in
            await startGate.wait()
            try Task.checkCancellation()
            try validateDescriptor(descriptor)
            return try await executePayload(descriptor)
        }
        operationTasks[operationID] = OperationOwnership(
            reservationID: reservationID,
            lifecycle: lifecycle,
            startGate: startGate,
            task: operationTask
        )
        defer {
            startGate.open()
            if operationTasks[operationID]?.reservationID == reservationID {
                operationTasks.removeValue(forKey: operationID)
                debugProbe?(.ownershipRemoved(operationID))
            }
        }

        try await withTaskCancellationHandler {
            debugProbe?(.ownershipReserved(operationID))
            guard await observations.beginOperation(operationID) else {
                operationTask.cancel()
                startGate.open()
                do {
                    _ = try await operationTask.value
                } catch {
                    // The rejected child must unwind before ownership is released.
                }
                throw ArchiveRuntimeValidationError.duplicateOperationID
            }
            startGate.open()
            do {
                let outcome = try await operationTask.value
                switch outcome {
                case let .ordinary(result):
                    guard lifecycle.finalizeSuccess() else {
                        throw CancellationError()
                    }
                    await observations.finishTerminal(
                        operationID,
                        state: .completed,
                        result: result
                    )
                    debugProbe?(.finalized(operationID, .completed))
                case let .committed(result, postTerminalFinalizer):
                    guard lifecycle.finalizeCommittedSuccess() else {
                        throw CancellationError()
                    }
                    await observations.finishTerminal(
                        operationID,
                        state: .completed,
                        result: result
                    )
                    debugProbe?(.finalized(operationID, .completed))
                    do {
                        try await postTerminalFinalizer()
                    } catch {
                        // Durable marker and private artifacts remain for startup retry.
                    }
                }
            } catch {
                if case ArchiveFailure.rollbackFailed = error {
                    guard lifecycle.finalizeRollbackFailure() else {
                        await finalizeCancellation(operationID)
                        throw CancellationError()
                    }
                    await observations.finishTerminal(operationID, state: .failed)
                    debugProbe?(.finalized(operationID, .failed))
                    throw error
                }
                if lifecycle.isCancelled || error is CancellationError {
                    _ = lifecycle.requestCancellation()
                    await finalizeCancellation(operationID)
                    throw CancellationError()
                }
                guard lifecycle.finalizeFailure() else {
                    await finalizeCancellation(operationID)
                    throw CancellationError()
                }
                await observations.finishTerminal(operationID, state: .failed)
                debugProbe?(.finalized(operationID, .failed))
                throw error
            }
        } onCancel: {
            if lifecycle.requestCancellation() {
                operationTask.cancel()
                startGate.open()
                Task {
                    await self.requestCancellation(
                        operationID,
                        reservationID: reservationID,
                        lifecycleAlreadyCancelled: true
                    )
                }
            }
        }
    }

    public func progress(
        for operationID: OperationID
    ) async -> AsyncStream<OperationProgressEvent> {
        await observations.register(operationID)
    }

    public func result(for operationID: OperationID) async -> OperationResult? {
        await observations.result(for: operationID)
    }

    public func state(for operationID: OperationID) async -> OperationState? {
        await observations.state(for: operationID)
    }

    public func cancelOperation(_ operationID: OperationID) async {
        guard let ownership = operationTasks[operationID] else { return }
        await requestCancellation(
            operationID,
            reservationID: ownership.reservationID,
            lifecycleAlreadyCancelled: false
        )
    }

    private func requestCancellation(
        _ operationID: OperationID,
        reservationID: UUID,
        lifecycleAlreadyCancelled: Bool
    ) async {
        guard let ownership = operationTasks[operationID],
              ownership.reservationID == reservationID else {
            return
        }
        if lifecycleAlreadyCancelled {
            guard ownership.lifecycle.isCancelled else { return }
        } else {
            guard ownership.lifecycle.requestCancellation() else { return }
        }

        ownership.task.cancel()
        ownership.startGate.open()
        await publishStoppingIfNeeded(operationID)
        debugProbe?(.cancellationRequested(operationID))
    }

    private func finalizeCancellation(_ operationID: OperationID) async {
        await publishStoppingIfNeeded(operationID)
        await observations.finishTerminal(operationID, state: .cancelled)
        debugProbe?(.finalized(operationID, .cancelled))
    }

    private func publishStoppingIfNeeded(_ operationID: OperationID) async {
        if await observations.transitionToStoppingIfNeeded(operationID) {
            debugProbe?(.stateChanged(operationID, .stopping))
        }
    }

    private func executeWithPermit(
        lane: SchedulingLane,
        resources: [OperationResourceReference],
        operationID: OperationID,
        operation: () async throws -> OperationResult?
    ) async throws -> OperationResult? {
        try Task.checkCancellation()
        let volumeIDs = try Set(resources.map {
            try volumeIdentifierProvider($0.url)
        })
        try Task.checkCancellation()
        let workload: ProcessWorkload
        switch lane {
        case .metadata:
            workload = .metadata(volumeIDs: volumeIDs)
        case .heavyIO:
            workload = .heavyIO(volumeIDs: volumeIDs)
        }

        let permit = try await scheduler.acquire(
            ProcessPermitRequest(workload: workload)
        )
        debugProbe?(.permitGranted(operationID))
        do {
            try Task.checkCancellation()
            await observations.setState(.running, for: operationID)
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            await permit.release()
            return result
        } catch {
            await permit.release()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func executeExtractionPreflightWithPermit(
        resources: [OperationResourceReference],
        operationID: OperationID,
        operation: () async throws -> ExtractionPreflight
    ) async throws -> ExtractionPreflight {
        try Task.checkCancellation()
        let volumeIDs = try Set(resources.map {
            try volumeIdentifierProvider($0.url)
        })
        try Task.checkCancellation()
        let permit = try await scheduler.acquire(
            ProcessPermitRequest(workload: .heavyIO(volumeIDs: volumeIDs))
        )
        debugProbe?(.permitGranted(operationID))
        do {
            try Task.checkCancellation()
            let preflight = try await operation()
            try Task.checkCancellation()
            await permit.release()
            return preflight
        } catch {
            await permit.release()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func executeSelectedExtractionWithPermit(
        resources: [OperationResourceReference],
        operationID: OperationID,
        operation: () async throws -> ArchiveExtractionExecution
    ) async throws -> ArchiveExtractionExecution {
        try Task.checkCancellation()
        let volumeIDs = try Set(resources.map {
            try volumeIdentifierProvider($0.url)
        })
        try Task.checkCancellation()
        let permit = try await scheduler.acquire(
            ProcessPermitRequest(workload: .heavyIO(volumeIDs: volumeIDs))
        )
        debugProbe?(.permitGranted(operationID))
        do {
            try Task.checkCancellation()
            await observations.setState(.running, for: operationID)
            try Task.checkCancellation()
            let execution = try await operation()
            await permit.release()
            return execution
        } catch {
            await permit.release()
            if case ArchiveFailure.rollbackFailed = error {
                throw error
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func executePayload(
        _ descriptor: OperationDescriptor
    ) async throws -> OperationExecutionOutcome {
        let operationID = descriptor.operationID
        switch descriptor.payload {
        case let .open(payload):
            try validateOptionalArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeOpen(payload, descriptor: descriptor)
                return nil
            })
        case let .list(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeList(payload, descriptor: descriptor)
                return nil
            })
        case let .test(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                .integrityTest(try await executeTest(payload, descriptor: descriptor))
            })
        case let .extract(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            try validateDestination(payload.destination)
            try validateConflictPolicy(payload.conflictPolicy)
            guard let extractionHandler else {
                throw ArchiveRuntimeValidationError.transactionalExtractionRequired
            }

            switch try await extractionHandler.prepare(descriptor: descriptor) {
            case let .committed(execution):
                return .committed(
                    result: .extraction(execution.result),
                    postTerminalFinalizer: execution.postTerminalFinalizer
                )
            case .fresh:
                let execution = try await executeSelectedExtractionWithPermit(
                    resources: [payload.archive, payload.destination],
                    operationID: operationID
                ) {
                    try await executeExtract(
                        payload,
                        descriptor: descriptor,
                        selectedHandler: extractionHandler
                    )
                }
                return .committed(
                    result: .extraction(execution.result),
                    postTerminalFinalizer: execution.postTerminalFinalizer
                )
            }
        case let .compress(payload):
            try validateNoArchiveContext(descriptor)
            try validateCompressionPayload(payload)
            try validateConflictPolicy(payload.conflictPolicy)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: payload.sources + [payload.destination],
                operationID: operationID
            ) {
                try await executeCompress(payload, descriptor: descriptor)
                return nil
            })
        case let .add(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            let resources = [payload.archive] + payload.sources
                + [payload.workingDirectory].compactMap { $0 }
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: resources,
                operationID: operationID
            ) {
                try await executeAdd(payload, descriptor: descriptor)
                return nil
            })
        case let .repackAdd(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            let resources = [payload.archive] + payload.sources
                + [payload.workingDirectory].compactMap { $0 }
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: resources,
                operationID: operationID
            ) {
                try await executeRepackAdd(payload, descriptor: descriptor)
                return nil
            })
        case let .delete(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeDelete(payload, descriptor: descriptor)
                return nil
            })
        case let .rename(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeRename(payload, descriptor: descriptor)
                return nil
            })
        case let .create(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            _ = try ArchiveComponentValidator.validate(payload.name)
            _ = try ArchivePathContainment.descendantDirectoryURL(
                root: URL(fileURLWithPath: "/", isDirectory: true),
                relativePath: payload.parentPath
            )
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeCreate(payload, descriptor: descriptor)
                return nil
            })
        case let .readComment(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                .archiveComment(try await executeReadComment(payload, descriptor: descriptor))
            })
        case let .saveBack(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            try validateEditSessionKey(payload.key, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [payload.archive, payload.workingDirectory],
                operationID: operationID
            ) {
                try await executeSaveBack(payload, descriptor: descriptor)
                return nil
            })
        case let .writeComment(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeWriteComment(payload, descriptor: descriptor)
                return nil
            })
        case let .beginEdit(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            try validateEditSessionKey(payload.key, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeBeginEdit(payload, descriptor: descriptor)
                return nil
            })
        case let .endEdit(payload):
            try validateArchiveReference(payload.archive, descriptor: descriptor)
            try validateEditSessionKey(payload.key, descriptor: descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .metadata,
                resources: [payload.archive],
                operationID: operationID
            ) {
                try await executeEndEdit(payload, descriptor: descriptor)
                return nil
            })
        case let .joinSplit(payload):
            try validateNoArchiveContext(descriptor)
            try validateDestination(payload.destination)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: payload.parts + [payload.destination],
                operationID: operationID
            ) {
                try await executeJoinSplit(payload, descriptor: descriptor)
                return nil
            })
        case let .brokerCommand(payload):
            try validateNoArchiveContext(descriptor)
            return .ordinary(try await executeWithPermit(
                lane: .heavyIO,
                resources: [],
                operationID: operationID
            ) {
                try await executeBrokerCommand(payload, descriptor: descriptor)
                return nil
            })
        }
    }

    private func validateDescriptor(_ descriptor: OperationDescriptor) throws {
        if descriptor.sessionID != nil, descriptor.archiveID == nil {
            throw ArchiveRuntimeValidationError.sessionRequiresArchive
        }
    }

    private func validateDestination(_ destination: OperationResourceReference) throws {
        _ = try ArchiveComponentValidator.validate(
            destination.url.standardizedFileURL.lastPathComponent
        )
    }

    private func validateCompressionPayload(_ payload: CompressionOperationPayload) throws {
        guard ArchiveFormat(rawValue: payload.formatIdentifier) != nil else {
            throw ArchiveRuntimeValidationError.invalidCompressionFormat(
                payload.formatIdentifier
            )
        }
        guard CompressionLevel(rawValue: payload.compressionLevel) != nil else {
            throw ArchiveRuntimeValidationError.invalidCompressionLevel(
                payload.compressionLevel
            )
        }
        try validateDestination(payload.destination)
    }


    private func validateConflictPolicy(
        _ conflictPolicy: OperationConflictPolicy
    ) throws {
        if conflictPolicy == .ask {
            throw ArchiveFailure.unresolvedConflictPolicy
        }
    }

    private func validateOptionalArchiveReference(
        _ reference: OperationResourceReference,
        descriptor: OperationDescriptor
    ) throws {
        guard let archiveID = descriptor.archiveID else { return }
        if let identity = reference.identity, identity != archiveID.identity {
            throw ArchiveRuntimeValidationError.payloadArchiveMismatch
        }
    }

    private func validateArchiveReference(
        _ reference: OperationResourceReference,
        descriptor: OperationDescriptor
    ) throws {
        guard let archiveID = descriptor.archiveID else {
            throw ArchiveRuntimeValidationError.archiveIDRequired
        }
        if let identity = reference.identity, identity != archiveID.identity {
            throw ArchiveRuntimeValidationError.payloadArchiveMismatch
        }
    }

    private func validateEditSessionKey(
        _ key: EditSessionKey,
        descriptor: OperationDescriptor
    ) throws {
        guard key.archiveID == descriptor.archiveID else {
            throw ArchiveRuntimeValidationError.editSessionArchiveMismatch
        }
    }

    private func validateNoArchiveContext(_ descriptor: OperationDescriptor) throws {
        guard descriptor.archiveID == nil, descriptor.sessionID == nil else {
            throw ArchiveRuntimeValidationError.unexpectedArchiveID
        }
    }

    private func executeOpen(
        _ payload: ArchiveReadOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let initiallyResolved = try resolveArchive(
            payload.archive,
            expectedID: descriptor.archiveID,
            resolver: identityResolver
        )
        let archiveID = initiallyResolved.locator.archiveID
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache

        try await leases.withLeases(
            archive: (archiveID, .read),
            destination: nil
        ) {
            let resolved = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            let key = CompatibilityArchiveCache.CacheKey(
                archiveID: archiveID,
                revision: resolved.revision
            )
            guard await cache.cachedFormat(for: key) == nil else { return }
            let token = await cache.beginLoad(for: key)
            if let format = backend.detectedFormat(for: payload.archive.url) {
                await cache.storeFormat(format, token: token)
            }
            await cache.finishLoad(token)
        }
    }

    private func executeList(
        _ payload: ArchiveReadOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        let listingLimit = max(0, min(
            policy.listing.listingHardCap,
            descriptor.resourcePolicy.listing.listingHardCap
        ))

        try await leases.withLeases(
            archive: (archiveID, .read),
            destination: nil
        ) {
            let resolved = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            let key = CompatibilityArchiveCache.CacheKey(
                archiveID: archiveID,
                revision: resolved.revision
            )
            guard await cache.cachedListing(for: key) == nil else { return }

            let token = await cache.beginLoad(for: key)
            do {
                let result = try await backend.list(
                    archive: payload.archive.url,
                    password: nil,
                    limit: listingLimit
                )
                if result.truncated {
                    throw ArchiveFailure.resourceLimitExceeded(
                        kind: .listingEntries,
                        limit: UInt64(listingLimit),
                        observed: UInt64(listingLimit) + 1
                    )
                }
                await cache.storeListing(result.entries, token: token)
                if let format = backend.detectedFormat(for: payload.archive.url) {
                    await cache.storeFormat(format, token: token)
                }
                await cache.finishLoad(token)
            } catch {
                await cache.finishLoad(token)
                throw error
            }
        }
    }

    private func executeTest(
        _ payload: ArchiveReadOperationPayload,
        descriptor: OperationDescriptor
    ) async throws -> Bool {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        return try await leases.withLeases(
            archive: (archiveID, .read),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            return try await backend.test(
                archive: payload.archive.url,
                password: nil
            )
        }
    }

    private func executeExtract(
        _ payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        selectedHandler: any ArchiveExtractionHandling
    ) async throws -> ArchiveExtractionExecution {
        let archiveID = try requiredArchiveID(descriptor)
        let destination = try destinationSnapshot(for: payload.destination)
        var archiveClaims: [(ArchiveID, ArchiveLeaseRegistry.ArchiveAccess)] = [
            (archiveID, .read)
        ]
        if let destinationArchiveID = destination.existingArchiveID {
            archiveClaims.append((destinationArchiveID, .write))
        }
        let resolver = identityResolver
        let observations = self.observations
        let operationID = descriptor.operationID

        return try await leases.withLeases(
            archives: archiveClaims,
            destination: destination.key
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try validateDestinationSnapshot(
                destination,
                reference: payload.destination,
                conflictPolicy: payload.conflictPolicy
            )

            return try await selectedHandler.executeFresh(
                payload: payload,
                descriptor: descriptor,
                progress: { progress in
                    await observations.publishProgress(
                        .archive(progress),
                        for: operationID
                    )
                }
            )
        }
    }

    private func executeCompress(
        _ payload: CompressionOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        guard let format = ArchiveFormat(rawValue: payload.formatIdentifier) else {
            throw ArchiveRuntimeValidationError.invalidCompressionFormat(
                payload.formatIdentifier
            )
        }
        guard let level = CompressionLevel(rawValue: payload.compressionLevel) else {
            throw ArchiveRuntimeValidationError.invalidCompressionLevel(
                payload.compressionLevel
            )
        }
        let destination = try destinationSnapshot(for: payload.destination)
        let archiveClaims = destination.existingArchiveID.map {
            [($0, ArchiveLeaseRegistry.ArchiveAccess.write)]
        } ?? []
        let backend = self.backend
        let cache = self.cache
        let observations = self.observations
        let operationID = descriptor.operationID
        let options = CompressionOptions(
            format: format,
            level: level,
            password: nil,
            encryptFileNames: payload.encryptFileNames,
            volumeSize: payload.volumeSizeBytes,
            exclusionPatterns: payload.exclusionPatterns,
            preserveTimestamps: payload.preserveTimestamps,
            existingFilePolicy: try existingFilePolicy(
                for: payload.conflictPolicy
            ),
            destinationParentIdentity: destination.key.parentIdentity
        )

        try await leases.withLeases(
            archives: archiveClaims,
            destination: destination.key
        ) {
            try validateDestinationSnapshot(
                destination,
                reference: payload.destination,
                conflictPolicy: payload.conflictPolicy
            )
            if payload.conflictPolicy == .fail,
               destination.existingArchiveID != nil {
                throw ArchiveFailure.destinationConflict(
                    path: payload.destination.url.path
                )
            }
            try validateReferenceIdentities(payload.sources)
            try await drain(
                try backend.compress(
                    sources: payload.sources.map(\.url),
                    destination: payload.destination.url,
                    options: options
                ),
                operationID: operationID,
                observations: observations
            )
            if let destinationArchiveID = destination.existingArchiveID {
                await cache.invalidate(archiveID: destinationArchiveID)
            }
        }
    }

    private func executeAdd(
        _ payload: AddOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try validateReferenceIdentities(payload.sources)
            if let workingDirectory = payload.workingDirectory {
                try validateReferenceIdentity(workingDirectory)
            }
            try await backend.add(
                files: payload.sources.map(\.url),
                to: payload.archive.url,
                password: nil,
                workingDirectory: payload.workingDirectory?.url
            )
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeRepackAdd(
        _ payload: AddOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        let workspaceProvider = replacementWorkspaceProvider
        let observations = self.observations
        let operationID = descriptor.operationID
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try validateReferenceIdentities(payload.sources)
            let workspace = try workspaceProvider(payload.archive.url)
            defer { try? FileManager.default.removeItem(at: workspace) }

            let pair = AsyncStream<RepackStep>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let relay = Task {
                for await step in pair.stream {
                    await observations.publishProgress(
                        .repackStep(step),
                        for: operationID
                    )
                }
            }
            do {
                try await backend.addViaRepack(
                    files: payload.sources.map(\.url),
                    to: payload.archive.url,
                    workspace: workspace,
                    onStep: { step in pair.continuation.yield(step) }
                )
                pair.continuation.finish()
                await relay.value
            } catch {
                pair.continuation.finish()
                await relay.value
                throw error
            }
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeDelete(
        _ payload: DeleteOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try await backend.delete(
                entries: payload.entryPaths,
                from: payload.archive.url,
                password: nil
            )
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeRename(
        _ payload: RenameOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try await backend.rename(
                pairs: payload.pairs.map { ($0.entryPath, $0.newName) },
                in: payload.archive.url,
                password: nil
            )
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeCreate(
        _ payload: CreateEntryOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        let workspaceProvider = replacementWorkspaceProvider
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            let workspace = try workspaceProvider(payload.archive.url)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let parent = try ArchivePathContainment.descendantDirectoryURL(
                root: workspace,
                relativePath: payload.parentPath
            )
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let item = try ArchivePathContainment.childURL(
                parent: parent,
                component: payload.name
            )
            switch payload.kind {
            case .file:
                try Data().write(to: item, options: .withoutOverwriting)
            case .folder:
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
            }
            try await backend.add(
                files: [item],
                to: payload.archive.url,
                password: nil,
                workingDirectory: workspace
            )
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeReadComment(
        _ payload: ArchiveReadOperationPayload,
        descriptor: OperationDescriptor
    ) async throws -> String {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        return try await leases.withLeases(
            archive: (archiveID, .read),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            return try await backend.readComment(for: payload.archive.url)
        }
    }

    private func executeSaveBack(
        _ payload: SaveBackOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try validateReferenceIdentity(payload.workingDirectory)
            try await backend.update(
                entry: payload.key.entryPath,
                from: payload.workingDirectory.url,
                in: payload.archive.url,
                password: nil
            )
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeWriteComment(
        _ payload: WriteCommentOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let backend = self.backend
        let resolver = identityResolver
        let cache = self.cache
        try await leases.withLeases(
            archive: (archiveID, .write),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
            try await backend.writeComment(payload.comment, to: payload.archive.url)
            await cache.invalidate(archiveID: archiveID)
        }
    }

    private func executeBeginEdit(
        _ payload: EditSessionOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        try await executeEditSessionValidation(payload, descriptor: descriptor)
    }

    private func executeEndEdit(
        _ payload: EditSessionOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        try await executeEditSessionValidation(payload, descriptor: descriptor)
    }

    private func executeEditSessionValidation(
        _ payload: EditSessionOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let archiveID = try requiredArchiveID(descriptor)
        let resolver = identityResolver
        try await leases.withLeases(
            archive: (archiveID, .read),
            destination: nil
        ) {
            _ = try resolveArchive(
                payload.archive,
                expectedID: archiveID,
                resolver: resolver
            )
        }
    }

    private func executeJoinSplit(
        _ payload: JoinSplitOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        let destination = try destinationSnapshot(for: payload.destination)
        let archiveClaims = destination.existingArchiveID.map {
            [($0, ArchiveLeaseRegistry.ArchiveAccess.write)]
        } ?? []
        let backend = self.backend
        let cache = self.cache
        let observations = self.observations
        let operationID = descriptor.operationID
        try await leases.withLeases(
            archives: archiveClaims,
            destination: destination.key
        ) {
            try validateDestinationSnapshot(
                destination,
                reference: payload.destination,
                conflictPolicy: nil
            )
            try validateReferenceIdentities(payload.parts)
            try await drain(
                backend.joinSplit(
                    parts: payload.parts.map(\.url),
                    destination: payload.destination.url
                ),
                operationID: operationID,
                observations: observations
            )
            if let destinationArchiveID = destination.existingArchiveID {
                await cache.invalidate(archiveID: destinationArchiveID)
            }
        }
    }

    private func executeBrokerCommand(
        _ payload: BrokerCommandOperationPayload,
        descriptor: OperationDescriptor
    ) async throws {
        _ = payload
        _ = descriptor
        throw ArchiveFailure.brokerUnavailable
    }

    private func requiredArchiveID(_ descriptor: OperationDescriptor) throws -> ArchiveID {
        guard let archiveID = descriptor.archiveID else {
            throw ArchiveRuntimeValidationError.archiveIDRequired
        }
        return archiveID
    }

}

private func resolveArchive(
    _ reference: OperationResourceReference,
    expectedID: ArchiveID?,
    resolver: any ArchiveIdentityResolving
) throws -> ResolvedArchive {
    let resolved = try resolver.resolve(reference.url)
    if let expectedID, resolved.locator.archiveID != expectedID {
        throw ArchiveFailure.archiveChanged
    }
    if let identity = reference.identity,
       resolved.locator.archiveID.identity != identity {
        throw ArchiveFailure.archiveChanged
    }
    return resolved
}

private func destinationSnapshot(
    for reference: OperationResourceReference
) throws -> DestinationSnapshot {
    let key = try destinationLeaseKey(for: reference.url)
    let identity = try existingFileIdentityIfPresent(for: reference.url)
    if let expectedIdentity = reference.identity,
       identity != expectedIdentity {
        throw ArchiveFailure.archiveChanged
    }
    return DestinationSnapshot(
        key: key,
        existingArchiveID: identity.map(ArchiveID.init(identity:))
    )
}

private func validateDestinationSnapshot(
    _ expected: DestinationSnapshot,
    reference: OperationResourceReference,
    conflictPolicy: OperationConflictPolicy?
) throws {
    let currentKey = try destinationLeaseKey(for: reference.url)
    let currentIdentity = try existingFileIdentityIfPresent(for: reference.url)
    if let expectedIdentity = reference.identity,
       currentIdentity != expectedIdentity {
        throw ArchiveFailure.archiveChanged
    }
    let current = DestinationSnapshot(
        key: currentKey,
        existingArchiveID: currentIdentity.map(ArchiveID.init(identity:))
    )
    guard current.key == expected.key else {
        throw ArchiveFailure.archiveChanged
    }
    guard current.existingArchiveID != expected.existingArchiveID else {
        return
    }
    if expected.existingArchiveID != nil {
        throw ArchiveFailure.archiveChanged
    }
    if conflictPolicy == .fail, current.existingArchiveID != nil {
        throw ArchiveFailure.destinationConflict(path: reference.url.path)
    }
    throw ArchiveFailure.archiveChanged
}

private func validateReferenceIdentities(
    _ references: [OperationResourceReference]
) throws {
    for reference in references {
        try validateReferenceIdentity(reference)
    }
}

private func validateReferenceIdentity(
    _ reference: OperationResourceReference
) throws {
    guard let expectedIdentity = reference.identity else { return }
    guard try existingFileIdentityIfPresent(for: reference.url) == expectedIdentity else {
        throw ArchiveFailure.archiveChanged
    }
}

private func existingFileIdentityIfPresent(
    for url: URL
) throws -> FileSystemIdentity? {
    do {
        return try existingFileIdentity(for: url)
    } catch let error as NSError
        where error.domain == NSPOSIXErrorDomain
            && error.code == Int(ENOENT) {
        return nil
    }
}

private func destinationLeaseKey(for destination: URL) throws -> DestinationLeaseKey {
    let standardized = destination.standardizedFileURL
    let normalizedName = try ArchiveComponentValidator.validate(
        standardized.lastPathComponent
    )
    let parentIdentity = try existingFileIdentity(
        for: standardized.deletingLastPathComponent()
    )
    return DestinationLeaseKey(
        parentIdentity: parentIdentity,
        // Must fold at least as widely as the filesystem does. This key is what
        // `ArchiveLeaseRegistry.activeDestinations` uses to stop two operations
        // writing the same file, so under-folding hands out two leases for one
        // file. `lowercased()` under-folds: on APFS `straße.zip` and
        // `strasse.zip` are a single inode, but they lowercase to different
        // strings.
        normalizedName: FileSystemNameCanonicalization.key(
            component: normalizedName
        )
    )
}

private func existingFileIdentity(for url: URL) throws -> FileSystemIdentity {
    var info = stat()
    let result = url.path.withCString { path in
        fstatat(AT_FDCWD, path, &info, 0)
    }
    guard result == 0 else {
        let errorCode = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
    guard info.st_dev != 0, info.st_ino != 0 else {
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return .stable(
        volumeIdentifier: UInt64(UInt32(bitPattern: info.st_dev)),
        fileIdentifier: UInt64(info.st_ino),
        generation: info.st_gen == 0 ? nil : UInt64(info.st_gen)
    )
}

private func existingFilePolicy(
    for policy: OperationConflictPolicy
) throws -> ExistingFilePolicy {
    switch policy {
    case .replace:
        return .replace
    case .keepBoth:
        return .keepBoth
    case .skip:
        return .skip
    case .fail:
        return .fail
    case .ask:
        throw ArchiveFailure.unresolvedConflictPolicy
    }
}

private func drain(
    _ stream: AsyncThrowingStream<Double, Error>,
    operationID: OperationID,
    observations: OperationObservationStore
) async throws {
    for try await fraction in stream {
        try Task.checkCancellation()
        await observations.publishProgress(
            .archive(.init(fraction: fraction)),
            for: operationID
        )
    }
    try Task.checkCancellation()
}
