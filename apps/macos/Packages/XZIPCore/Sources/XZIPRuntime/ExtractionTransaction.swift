import Darwin
import Foundation
import XZIPCore
import XZIPDomain

public protocol ArchiveExtractionBackend: Sendable {
    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error>
}

public struct QuarantineManifestEntry: Hashable, Sendable {
    public let relativePath: String
    public let kind: ExtractionNodeKind
    public let identity: FileNodeIdentity

    public init(
        relativePath: String,
        kind: ExtractionNodeKind,
        identity: FileNodeIdentity
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.identity = identity
    }
}

public protocol PublicationQuarantining: Sendable {
    func apply(
        to entries: [QuarantineManifestEntry],
        stagingRoot: URL,
        stagingRootIdentity: FileNodeIdentity,
        fileSystem: any FileSystemOperations
    ) throws
}

struct ReplaceSwapSyncCompletion: Equatable, Sendable {
    var sourceParentSynced = false
    var destinationParentSynced = false

    var isComplete: Bool {
        sourceParentSynced && destinationParentSynced
    }
}

public actor ExtractionTransaction {
private struct CommitStateUncertain: Error {
        let recoveryURL: URL
    }

    private struct UnsafeStagingAuthority: Error {}

    private struct PostEffectAuthorityFailure: Error {
        let reason: String
        let allowsRollback: Bool

        init(reason: String, allowsRollback: Bool = false) {
            self.reason = reason
            self.allowsRollback = allowsRollback
        }
    }

    private struct StagedNode: Sendable {
        let path: String
        let kind: ExtractionNodeKind
        let identity: FileNodeIdentity
    }

    private enum AppliedMutation: Sendable {
        case publishMove(
            mutationID: JournalMutationID,
            staged: JournalNodeReference,
            destination: JournalNodeReference,
            identity: FileNodeIdentity
        )
        case replaceSwap(
            mutationID: JournalMutationID,
            staged: JournalNodeReference,
            destination: JournalNodeReference,
            replacementIdentity: FileNodeIdentity,
            capturedManifest: CapturedTreeManifest,
            syncCompletion: ReplaceSwapSyncCompletion
        )
    }

    private final class ActiveContext: @unchecked Sendable {
        let namespace: TransactionNamespaceLocator
        let namespaceHandle: DirectoryHandle
        let rootName: String
        let rootIdentity: FileNodeIdentity
        let rootHandle: DirectoryHandle
        let journalNode: FileNode

        init(
            namespace: TransactionNamespaceLocator,
            namespaceHandle: DirectoryHandle,
            rootName: String,
            rootIdentity: FileNodeIdentity,
            rootHandle: DirectoryHandle,
            journalNode: FileNode
        ) {
            self.namespace = namespace
            self.namespaceHandle = namespaceHandle
            self.rootName = rootName
            self.rootIdentity = rootIdentity
            self.rootHandle = rootHandle
            self.journalNode = journalNode
        }

        func close() {
            rootHandle.close()
            namespaceHandle.close()
        }
    }

    private let backend: any ArchiveExtractionBackend
    private let journal: any ExtractionJournalStore
    private let preparationAborter: any ExtractionPreparationAborting
    private let namespaceProvider: any TransactionNamespaceProviding
    private let fileSystem: any FileSystemOperations
    private let stateResolver: ExtractionStateResolver
    private let quarantine: any PublicationQuarantining
    private let archiveSourceBindingBeforeReleaseObserver: (@Sendable (URL) throws -> Void)?
    private let replaceSwapSyncCompletionBeforeCommit: (@Sendable (
        ReplaceSwapSyncCompletion
    ) -> ReplaceSwapSyncCompletion)?

    private final class ArchiveSourceBinding: @unchecked Sendable {
        let locator: ArchiveLocator

        private let lock = NSLock()
        private let sourceDescriptor: Int32
        private let eventQueue: Int32
        private let expectedMetadata: stat
        private let beforeReleaseObserver: (@Sendable (URL) throws -> Void)?
        private var isClosed = false

        init(
            locator: ArchiveLocator,
            sourceDescriptor: Int32,
            eventQueue: Int32,
            metadata: stat,
            beforeReleaseObserver: (@Sendable (URL) throws -> Void)?
        ) {
            self.locator = locator
            self.sourceDescriptor = sourceDescriptor
            self.eventQueue = eventQueue
            expectedMetadata = metadata
            self.beforeReleaseObserver = beforeReleaseObserver
        }

        deinit {
            release()
        }

        func verifyStable() throws {
            try lock.withLock {
                guard !isClosed else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                try verifyStableLocked()
            }
        }

        func verifyAndRelease() throws {
            try lock.withLock {
                guard !isClosed else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                try verifyStableLocked()
                try beforeReleaseObserver?(locator.url)
                try verifyStableLocked()
                closeLocked()
            }
        }

        func release() {
            lock.withLock {
                guard !isClosed else { return }
                closeLocked()
            }
        }

        private func verifyStableLocked() throws {
            var event = kevent64_s(
                ident: 0,
                filter: 0,
                flags: 0,
                fflags: 0,
                data: 0,
                udata: 0,
                ext: (0, 0)
            )
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let eventCount = kevent64(
                eventQueue,
                nil,
                0,
                &event,
                1,
                0,
                &timeout
            )
            guard eventCount >= 0 else {
                throw FileSystemOperationError.posix(
                    function: "kevent64.archiveSourceBinding",
                    code: errno
                )
            }
            guard eventCount == 0 else {
                throw ArchiveFailure.extractionPlanChanged
            }

            var opened = stat()
            guard fstat(sourceDescriptor, &opened) == 0 else {
                throw FileSystemOperationError.posix(
                    function: "fstat.archiveSourceBinding",
                    code: errno
                )
            }
            var current = stat()
            let pathStatus = locator.url.path.withCString { path in
                fstatat(AT_FDCWD, path, &current, 0)
            }
            guard pathStatus == 0,
                  metadataMatches(opened),
                  metadataMatches(current)
            else {
                throw ArchiveFailure.extractionPlanChanged
            }
        }

        private func metadataMatches(_ metadata: stat) -> Bool {
            metadata.st_dev == expectedMetadata.st_dev
                && metadata.st_ino == expectedMetadata.st_ino
                && metadata.st_size == expectedMetadata.st_size
                && metadata.st_mode == expectedMetadata.st_mode
                && metadata.st_mtimespec.tv_sec == expectedMetadata.st_mtimespec.tv_sec
                && metadata.st_mtimespec.tv_nsec == expectedMetadata.st_mtimespec.tv_nsec
                && metadata.st_ctimespec.tv_sec == expectedMetadata.st_ctimespec.tv_sec
                && metadata.st_ctimespec.tv_nsec == expectedMetadata.st_ctimespec.tv_nsec
                && metadata.st_mode & S_IFMT == S_IFREG
        }

        private func closeLocked() {
            isClosed = true
            _ = Darwin.close(eventQueue)
            _ = Darwin.close(sourceDescriptor)
        }
    }

    public init(
        backend: any ArchiveExtractionBackend,
        journal: any ExtractionJournalStore,
        preparationAborter: any ExtractionPreparationAborting,
        namespaceProvider: any TransactionNamespaceProviding,
        fileSystem: any FileSystemOperations,
        quarantine: any PublicationQuarantining
    ) {
        self.backend = backend
        self.journal = journal
        self.preparationAborter = preparationAborter
        self.namespaceProvider = namespaceProvider
        self.fileSystem = fileSystem
        self.stateResolver = ExtractionStateResolver(
            archiveIdentityResolver: ArchiveIdentityResolver(),
            fileSystem: fileSystem
        )
        self.quarantine = quarantine
        self.archiveSourceBindingBeforeReleaseObserver = nil
        self.replaceSwapSyncCompletionBeforeCommit = nil
    }

    init(
        backend: any ArchiveExtractionBackend,
        journal: any ExtractionJournalStore,
        preparationAborter: any ExtractionPreparationAborting,
        namespaceProvider: any TransactionNamespaceProviding,
        fileSystem: any FileSystemOperations,
        stateResolver: ExtractionStateResolver,
        quarantine: any PublicationQuarantining,
        archiveSourceBindingBeforeReleaseObserver: (@Sendable (URL) throws -> Void)? = nil,
        replaceSwapSyncCompletionBeforeCommit: (@Sendable (
            ReplaceSwapSyncCompletion
        ) -> ReplaceSwapSyncCompletion)? = nil
    ) {
        self.backend = backend
        self.journal = journal
        self.preparationAborter = preparationAborter
        self.namespaceProvider = namespaceProvider
        self.fileSystem = fileSystem
        self.stateResolver = stateResolver
        self.quarantine = quarantine
        self.archiveSourceBindingBeforeReleaseObserver = archiveSourceBindingBeforeReleaseObserver
        self.replaceSwapSyncCompletionBeforeCommit = replaceSwapSyncCompletionBeforeCommit
    }

    private func makeArchiveSourceBinding(
        archive: ArchiveLocator
    ) throws -> ArchiveSourceBinding {
        let sourceDescriptor = open(
            archive.url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            let openError = errno
            if openError == ELOOP {
                throw ArchiveFailure.extractionPlanChanged
            }
            throw FileSystemOperationError.posix(
                function: "open.archiveSourceBinding",
                code: openError
            )
        }
        var shouldCloseSource = true
        var eventQueue: Int32 = -1
        defer {
            if eventQueue >= 0 { _ = Darwin.close(eventQueue) }
            if shouldCloseSource { _ = Darwin.close(sourceDescriptor) }
        }

        var sourceMetadata = stat()
        guard fstat(sourceDescriptor, &sourceMetadata) == 0 else {
            throw FileSystemOperationError.posix(
                function: "fstat.archiveSourceBinding",
                code: errno
            )
        }
        guard sourceMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveFailure.extractionPlanChanged
        }

        eventQueue = kqueue()
        guard eventQueue >= 0 else {
            throw FileSystemOperationError.posix(
                function: "kqueue.archiveSourceBinding",
                code: errno
            )
        }
        let eventFlags = UInt16(EV_ADD) | UInt16(EV_CLEAR)
        let vnodeNotes = UInt32(NOTE_DELETE)
            | UInt32(NOTE_WRITE)
            | UInt32(NOTE_EXTEND)
            | UInt32(NOTE_ATTRIB)
            | UInt32(NOTE_LINK)
            | UInt32(NOTE_RENAME)
            | UInt32(NOTE_REVOKE)
        var change = kevent64_s(
            ident: UInt64(sourceDescriptor),
            filter: Int16(EVFILT_VNODE),
            flags: eventFlags,
            fflags: vnodeNotes,
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        guard kevent64(eventQueue, &change, 1, nil, 0, 0, nil) == 0 else {
            throw FileSystemOperationError.posix(
                function: "kevent64.archiveSourceBinding.register",
                code: errno
            )
        }

        let binding = ArchiveSourceBinding(
            locator: archive,
            sourceDescriptor: sourceDescriptor,
            eventQueue: eventQueue,
            metadata: sourceMetadata,
            beforeReleaseObserver: archiveSourceBindingBeforeReleaseObserver
        )
        shouldCloseSource = false
        eventQueue = -1
        try binding.verifyStable()
        return binding
    }

    private struct PublishedEntry: Sendable {
        let finalPath: String
        let url: URL
    }

    private final class PublicationState {
        var applied: [AppliedMutation]
        var publishedByOriginalPath: [String: PublishedEntry] = [:]
        var skippedPaths: Set<String> = []
        /// Archive-recorded directory modes by normalized staged path, computed
        /// once per publication pass so restoring a subtree stays linear.
        let directoryModes: [String: UInt16]

        init(
            applied: [AppliedMutation],
            directoryModes: [String: UInt16]
        ) {
            self.applied = applied
            self.directoryModes = directoryModes
        }

        func markReplaceSwapParentSynced(
            mutationID: JournalMutationID,
            source: Bool
        ) throws {
            guard let index = applied.firstIndex(where: { mutation in
                guard case let .replaceSwap(id, _, _, _, _, _) = mutation else {
                    return false
                }
                return id == mutationID
            }), case let .replaceSwap(
                id,
                staged,
                destination,
                replacementIdentity,
                capturedManifest,
                current
            ) = applied[index] else {
                throw PostEffectAuthorityFailure(
                    reason: "replace swap sync state is not registered"
                )
            }
            var completion = current
            if source {
                completion.sourceParentSynced = true
            } else {
                completion.destinationParentSynced = true
            }
            applied[index] = .replaceSwap(
                mutationID: id,
                staged: staged,
                destination: destination,
                replacementIdentity: replacementIdentity,
                capturedManifest: capturedManifest,
                syncCompletion: completion
            )
        }
    }

    /// The mode used for a published directory whose archive recorded none.
    ///
    /// Archives that do record a mode are honoured exactly, so this default is
    /// deliberately a plain constant rather than `0o777 & ~umask`: the process
    /// umask must not silently override what an archive asked for, and applying
    /// it only to mode-less entries would be inconsistent.
    private static let defaultPublishedDirectoryMode: UInt16 = 0o755

    /// The archive-recorded `mode`, clamped to something safe to publish.
    ///
    /// `| 0o700` — the owner keeps `rwx`. Modes are restored *before* the
    /// publishing rename, which is the only moment the transaction can still
    /// reach a subtree. If a rename then does not happen — the destination name
    /// is taken, so `.keepBoth` retries under another name, or `.skip` abandons
    /// the node — the staged directory is left at the restored mode and the
    /// transaction must still be able to open it to publish, clean up, or roll
    /// back. An archive recording a directory without owner `rwx` (`0555`, or
    /// `0000`) would otherwise make that open fail with `EACCES`, the same class
    /// of self-inflicted deadlock that unrecoverable staged modes caused before
    /// adoption existed. Every ordinary directory mode (`0755`, `0750`, `0700`,
    /// `0775`, `0705`) already includes owner `rwx` and is unaffected.
    ///
    /// `& ~0o022` — group and other lose *write*. Previously only the OR was
    /// applied, so a directory declaring `0o777` published as `0o777` and any
    /// local user could drop files into the freshly extracted tree. Group/other
    /// read and execute are deliberately kept: stripping them would break the
    /// ordinary case of extracting a world-readable tree.
    ///
    /// Setuid/setgid/sticky never reach here: `SevenZipInventoryParser` decodes
    /// only the low nine bits.
    private static func publishableDirectoryMode(_ mode: UInt16) -> UInt16 {
        (mode | 0o700) & ~0o022
    }

    func preflight(
        _ request: ExtractionPreflightRequest,
        password: String?
    ) async throws -> ExtractionPreflight {
        guard request.conflictPolicy != .ask else {
            throw ArchiveFailure.unresolvedConflictPolicy
        }

        var transactionPassword = password
        defer { transactionPassword = nil }
        let initialState = try stateResolver.resolve(
            archive: request.archive.url,
            destination: request.destination
        )
        let suppliedInventory = try await backend.freshExtractionInventory(
            archive: request.archive,
            selectedEntries: request.selectedEntries,
            password: transactionPassword,
            policy: request.resourcePolicy
        )
        try Task.checkCancellation()
        let inventory = try normalizedInventory(
            suppliedInventory,
            policy: request.resourcePolicy
        )
        let validatedState = try stateResolver.resolve(
            archive: request.archive.url,
            destination: request.destination
        )
        guard validatedState == initialState else {
            throw ArchiveFailure.extractionPlanChanged
        }

        let destination = try fileSystem.openDirectoryNoFollow(at: request.destination)
        defer { destination.close() }
        guard try fileSystem.identity(of: destination)
            == validatedState.destinationRootNodeIdentity
        else {
            throw ArchiveFailure.extractionPlanChanged
        }
        let plan = try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
            inventory: inventory,
            selectedEntries: normalizedSelectedEntries(request.selectedEntries),
            destination: destination,
            conflictPolicy: request.conflictPolicy,
            preserveTimestamps: request.preserveTimestamps,
            resourcePolicy: request.resourcePolicy
        )

        return ExtractionPreflight(
            archive: request.archive,
            archiveRevision: validatedState.archiveRevision,
            destination: request.destination,
            destinationIdentity: validatedState.destinationIdentity,
            selectedEntries: request.selectedEntries,
            conflictPolicy: request.conflictPolicy,
            preserveTimestamps: request.preserveTimestamps,
            resourcePolicy: request.resourcePolicy,
            planDigest: plan.digest,
            publicationBinding: plan.publicationBinding,
            conflicts: plan.conflicts,
            destructiveReplacementPaths: plan.destructiveReplacementPaths
        )
    }

    func execute(
        _ request: ExtractionRequest,
        password: String?,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ExtractionResult {
        guard request.conflictPolicy != .ask else {
            throw ArchiveFailure.unresolvedConflictPolicy
        }

        var transactionPassword = password
        defer { transactionPassword = nil }

        let expectedArchiveRevision: ArchiveRevision
        let expectedDestinationIdentity: ExtractionDestinationIdentity
        let expectedPlanDigest: ExtractionPlanDigest
        let expectedPublicationBinding: [ExtractionPublicationBindingEntry]
        switch (
            request.expectedArchiveRevision,
            request.expectedDestinationIdentity,
            request.planDigest,
            request.publicationBinding
        ) {
        case (nil, nil, nil, nil):
            guard request.conflictPolicy != .replace else {
                throw ArchiveFailure.destructiveReplacementApprovalRequired
            }
            let bound = try await preflight(
                ExtractionPreflightRequest(
                    operationID: request.operationID,
                    sessionID: request.sessionID,
                    archive: request.archive,
                    destination: request.destination,
                    selectedEntries: request.selectedEntries,
                    conflictPolicy: request.conflictPolicy,
                    preserveTimestamps: request.preserveTimestamps,
                    resourcePolicy: request.resourcePolicy,
                    ui: request.ui
                ),
                password: transactionPassword
            )
            expectedArchiveRevision = bound.archiveRevision
            expectedDestinationIdentity = bound.destinationIdentity
            expectedPlanDigest = bound.planDigest
            expectedPublicationBinding = bound.publicationBinding
        case let (
            archiveRevision?,
            destinationIdentity?,
            planDigest?,
            publicationBinding?
        ):
            expectedArchiveRevision = archiveRevision
            expectedDestinationIdentity = destinationIdentity
            expectedPlanDigest = planDigest
            expectedPublicationBinding = publicationBinding
        default:
            throw ArchiveFailure.extractionPlanChanged
        }

        let initialState = try stateResolver.resolve(
            archive: request.archive.url,
            destination: request.destination
        )
        guard initialState.archiveRevision == expectedArchiveRevision,
              initialState.destinationIdentity == expectedDestinationIdentity
        else {
            throw ArchiveFailure.extractionPlanChanged
        }

        let sourceBinding = try makeArchiveSourceBinding(archive: request.archive)
        defer { sourceBinding.release() }
        let boundState = try stateResolver.resolve(
            archive: request.archive.url,
            destination: request.destination
        )
        guard boundState == initialState else {
            throw ArchiveFailure.extractionPlanChanged
        }
        try sourceBinding.verifyStable()

        let suppliedInventory = try await backend.freshExtractionInventory(
            archive: sourceBinding.locator,
            selectedEntries: request.selectedEntries,
            password: transactionPassword,
            policy: request.resourcePolicy
        )
        try sourceBinding.verifyStable()
        try Task.checkCancellation()
        let inventory = try normalizedInventory(
            suppliedInventory,
            policy: request.resourcePolicy
        )
        let validatedState = try stateResolver.resolve(
            archive: request.archive.url,
            destination: request.destination
        )
        guard validatedState == initialState else {
            throw ArchiveFailure.extractionPlanChanged
        }

        let destination = try fileSystem.openDirectoryNoFollow(at: request.destination)
        defer { destination.close() }
        let destinationIdentity = try fileSystem.identity(of: destination)
        guard destinationIdentity == validatedState.destinationRootNodeIdentity else {
            throw ArchiveFailure.extractionPlanChanged
        }
        let plan = try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
            inventory: inventory,
            selectedEntries: normalizedSelectedEntries(request.selectedEntries),
            destination: destination,
            conflictPolicy: request.conflictPolicy,
            preserveTimestamps: request.preserveTimestamps,
            resourcePolicy: request.resourcePolicy
        )
        guard plan.digest == expectedPlanDigest,
              plan.publicationBinding == expectedPublicationBinding
        else {
            throw ArchiveFailure.extractionPlanChanged
        }
        if !plan.destructiveReplacementPaths.isEmpty {
            guard let approval = request.replacementApproval else {
                throw ArchiveFailure.destructiveReplacementApprovalRequired
            }
            guard approval.archiveRevision == expectedArchiveRevision,
                  approval.destinationIdentity == expectedDestinationIdentity,
                  approval.conflictPolicy == .replace,
                  request.conflictPolicy == .replace,
                  approval.planDigest == expectedPlanDigest,
                  approval.publicationBinding == expectedPublicationBinding
            else {
                throw ArchiveFailure.extractionPlanChanged
            }
        }

        let namespace = try await namespaceProvider.namespace(
            forDestinationIdentity: destinationIdentity
        )
        let manifest = makeManifest(from: inventory)
        let transactionID = TransactionID()
        let header = ExtractionJournalHeader(
            transactionID: transactionID,
            operationID: request.operationID,
            archiveID: request.archive.archiveID,
            destinationURL: request.destination,
            destinationIdentity: destinationIdentity,
            stagingCleanupManifest: manifest,
            createdAt: Date()
        )

        let reservation = try await journal.register(
            transaction: header,
            namespace: namespace
        )
        let rootURL = namespace.url.appendingPathComponent(
            reservation.rootName,
            isDirectory: true
        )
        let rootIdentity: FileNodeIdentity
        let activated: ActivatedExtractionTransaction
        do {
            rootIdentity = try await journal.createTransactionRoot(reservation)
            activated = try await journal.activate(reservation)
        } catch let originalError {
            do {
                try await journal.relinquishPreparation(reservation)
                try await preparationAborter.abortPreparation(transactionID: transactionID)
            } catch {
                // Both halves are known here: what we were failing at, and what
                // stopped us undoing it.
                throw ArchiveFailure.rollbackFailed(
                    recoveryURL: rootURL,
                    cause: RollbackCause(original: originalError, rollback: error)
                )
            }
            throw originalError
        }
        defer { activated.close() }

        let context: ActiveContext
        do {
            context = try makeActiveContext(
                namespace: namespace,
                reservation: reservation,
                rootIdentity: rootIdentity,
                activated: activated
            )
        } catch {
            // Nothing had failed before this: building the context is itself the
            // failure, and it leaves the root behind.
            throw ArchiveFailure.rollbackFailed(
                recoveryURL: rootURL,
                cause: RollbackCause(original: nil, rollback: error)
            )
        }
        defer { context.close() }

        var applied: [AppliedMutation] = []
        var validatedStagedNodes: [StagedNode]?
        do {
            do {
                try sourceBinding.verifyStable()
                let materializationState = try stateResolver.resolve(
                    archive: request.archive.url,
                    destination: request.destination
                )
                guard materializationState == initialState else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                let stream = backend.extractToEmptyStagingDirectory(
                    archive: sourceBinding.locator,
                    destination: activated.stagingURL,
                    selectedEntries: request.selectedEntries,
                    cleanupManifest: manifest,
                    preserveTimestamps: request.preserveTimestamps,
                    policy: request.resourcePolicy,
                    password: transactionPassword
                )
                for try await value in stream {
                    await progress(value)
                }
                transactionPassword = nil
            } catch {
                transactionPassword = nil
                throw error
            }
            try sourceBinding.verifyAndRelease()

            let publicationState = try stateResolver.resolve(
                archive: request.archive.url,
                destination: request.destination
            )
            guard publicationState.archiveRevision == expectedArchiveRevision,
                  publicationState.destinationIdentity == expectedDestinationIdentity
            else {
                throw ArchiveFailure.extractionPlanChanged
            }
            let stagedNodes = try validateStaging(
                manifest: manifest,
                staging: activated.stagingHandle,
                requireComplete: true,
                stagingByteCap: request.resourcePolicy.output.stagingByteCap
            )
            validatedStagedNodes = stagedNodes
            do {
                try quarantine.apply(
                    to: stagedNodes.map {
                        QuarantineManifestEntry(
                            relativePath: $0.path,
                            kind: $0.kind,
                            identity: $0.identity
                        )
                    },
                    stagingRoot: activated.stagingURL,
                    stagingRootIdentity: activated.stagingIdentity,
                    fileSystem: fileSystem
                )
            } catch let error as FileSystemOperationError {
                switch error {
                case .identityMismatch, .symlinkEncountered, .notDirectory, .unsupportedNode:
                    throw UnsafeStagingAuthority()
                default:
                    throw error
                }
            }

            let publicationPlan = try ExtractionConflictPlanner(
                fileSystem: fileSystem
            ).plan(
                inventory: inventory,
                selectedEntries: normalizedSelectedEntries(request.selectedEntries),
                destination: destination,
                conflictPolicy: request.conflictPolicy,
                preserveTimestamps: request.preserveTimestamps,
                resourcePolicy: request.resourcePolicy
            )
            guard publicationPlan.digest == expectedPlanDigest,
                  publicationPlan.publicationBinding == expectedPublicationBinding,
                  publicationPlan.publicationExpectations == plan.publicationExpectations
            else {
                throw ArchiveFailure.extractionPlanChanged
            }

            let result = try await publishMissingTopLevelNodes(
                request: request,
                inventory: inventory,
                stagedNodes: stagedNodes,
                publicationExpectations: plan.publicationExpectations,
                replacementSnapshots: plan.replacementSnapshots,
                destinationRootIdentity: destinationIdentity,
                activated: activated,
                context: context,
                applied: &applied            )
            try Task.checkCancellation()
            try await validateCommitReadiness(
                transactionID: transactionID,
                destinationURL: request.destination,
                destinationRootIdentity: destinationIdentity,
                publicationExpectations: plan.publicationExpectations,
                listingPolicy: request.resourcePolicy.listing,
                activated: activated,
                context: context,
                applied: applied
            )
            do {
                try await journal.markCommitted(
                    transactionID: transactionID,
                    result: result
                )
            } catch let error as TransactionJournalError {
                if case let .commitStateUncertain(recoveryURL) = error {
                    throw CommitStateUncertain(recoveryURL: recoveryURL)
                }
                throw error
            }
            return result
        } catch let uncertainty as CommitStateUncertain {
            throw ArchiveFailure.rollbackFailed(
                recoveryURL: uncertainty.recoveryURL,
                cause: RollbackCause(original: nil, rollback: uncertainty)
            )
        } catch let authority as UnsafeStagingAuthority {
            throw ArchiveFailure.rollbackFailed(
                recoveryURL: rootURL,
                cause: RollbackCause(original: nil, rollback: authority)
            )
        } catch let authority as PostEffectAuthorityFailure {
            guard authority.allowsRollback else {
                throw ArchiveFailure.rollbackFailed(
                    recoveryURL: rootURL,
                    cause: RollbackCause(original: nil, rollback: authority)
                )
            }
            try await rollbackOrThrow(
                originalError: authority,
                transactionID: transactionID,
                recoveryURL: rootURL,
                manifest: manifest,
                expectedStagedNodes: validatedStagedNodes,
                destinationURL: request.destination,
                destinationRootIdentity: destinationIdentity,
                publicationExpectations: plan.publicationExpectations,
                listingPolicy: request.resourcePolicy.listing,
                activated: activated,
                context: context,
                applied: applied            )
            throw ArchiveFailure.extractionPlanChanged
        } catch let error as ArchiveFailure {
            if case let .rollbackFailed(recoveryURL, _) = error,
               recoveryURL.standardizedFileURL == rootURL.standardizedFileURL {
                throw error
            }
            try await rollbackOrThrow(
                originalError: error,
                transactionID: transactionID,
                recoveryURL: rootURL,
                manifest: manifest,
                expectedStagedNodes: validatedStagedNodes,
                destinationURL: request.destination,
                destinationRootIdentity: destinationIdentity,
                publicationExpectations: plan.publicationExpectations,
                listingPolicy: request.resourcePolicy.listing,
                activated: activated,
                context: context,
                applied: applied            )
            throw error
        } catch let originalError {
            try await rollbackOrThrow(
                originalError: originalError,
                transactionID: transactionID,
                recoveryURL: rootURL,
                manifest: manifest,
                expectedStagedNodes: validatedStagedNodes,
                destinationURL: request.destination,
                destinationRootIdentity: destinationIdentity,
                publicationExpectations: plan.publicationExpectations,
                listingPolicy: request.resourcePolicy.listing,
                activated: activated,
                context: context,
                applied: applied            )
            throw originalError
        }
    }

    private func normalizedInventory(
        _ inventory: ExtractionInventory,
        policy: ArchiveResourcePolicy
    ) throws -> ExtractionInventory {
        let entries = inventory.entries.map { entry in
            ExtractionInventoryEntry(
                path: normalizedPath(entry.path),
                kind: entry.kind,
                size: entry.size,
                linkTarget: entry.linkTarget,
                isExplicitDirectory: entry.isExplicitDirectory,
                posixMode: entry.posixMode
            )
        }
        return try ExtractionInventory.validated(
            entries: entries,
            advertisedDictionaryByteCount: inventory.advertisedDictionaryByteCount,
            policy: policy
        )
    }

    private func normalizedSelectedEntries(_ entries: [String]) -> [String] {
        entries.map(normalizedPath)
    }

    private func normalizedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
    }

    private func makeManifest(
        from inventory: ExtractionInventory
    ) -> StagingCleanupManifest {
        var kinds: [String: ExtractionNodeKind] = [:]
        for path in inventory.implicitDirectories {
            kinds[path] = .directory
        }
        for entry in inventory.entries {
            kinds[entry.path] = entry.kind
        }
        return StagingCleanupManifest(entries: kinds.map {
            StagingCleanupManifestEntry(relativePath: $0.key, kind: $0.value)
        }.sorted { $0.relativePath < $1.relativePath })
    }

    private func makeActiveContext(
        namespace: TransactionNamespaceLocator,
        reservation: TransactionRootReservation,
        rootIdentity: FileNodeIdentity,
        activated: ActivatedExtractionTransaction
    ) throws -> ActiveContext {
        let namespaceHandle = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespace.url,
            expected: namespace.identity
        )
        do {
            let rootHandle = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                parent: namespaceHandle,
                name: reservation.rootName,
                expected: rootIdentity
            )
            do {
                let rootNodes = try fileSystem.listNoFollow(rootHandle)
                let stagingName = activated.stagingURL.lastPathComponent
                guard rootNodes.count == 2,
                      rootNodes.first(where: { $0.name == stagingName })?.identity
                        == activated.stagingIdentity,
                      let journalNode = rootNodes.first(where: {
                          $0.name != stagingName
                      }),
                      journalNode.name == "journal",
                      journalNode.identity.kind == .regularFile
                else {
                    throw TransactionJournalError.unsafeRecoveryState(
                        "unexpected activated root occupancy"
                    )
                }
                return ActiveContext(
                    namespace: namespace,
                    namespaceHandle: namespaceHandle,
                    rootName: reservation.rootName,
                    rootIdentity: rootIdentity,
                    rootHandle: rootHandle,
                    journalNode: journalNode
                )
            } catch {
                rootHandle.close()
                throw error
            }
        } catch {
            namespaceHandle.close()
            throw error
        }
    }

    private func validateStaging(
        manifest: StagingCleanupManifest,
        staging: DirectoryHandle,
        requireComplete: Bool,
        stagingByteCap: UInt64?
    ) throws -> [StagedNode] {
        let kinds = Dictionary(uniqueKeysWithValues: manifest.entries.map {
            ($0.relativePath, $0.kind)
        })
        var allowedChildren: [String: Set<String>] = [:]
        for entry in manifest.entries {
            let components = pathComponents(entry.relativePath)
            let parent = components.dropLast().joined(separator: "/")
            if let name = components.last {
                allowedChildren[parent, default: []].insert(name)
            }
        }
        var observedNodes: [StagedNode] = []
        var totalStagingBytes: UInt64 = 0

        func validateDirectory(
            path: String,
            handle: DirectoryHandle
        ) throws {
            let observed = try fileSystem.listNoFollow(handle)
            let allowed = allowedChildren[path, default: []]
            guard Set(observed.map(\.name)).isSubset(of: allowed) else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "unexpected staged entry"
                )
            }
            for child in observed {
                if let stagingByteCap {
                    totalStagingBytes = try StagingByteAccounting.adding(
                        current: totalStagingBytes,
                        logical: child.byteCount,
                        allocated: child.allocatedByteCount,
                        limit: stagingByteCap
                    )
                }
                let childPath = path.isEmpty
                    ? child.name
                    : "\(path)/\(child.name)"
                guard kinds[childPath] == child.identity.kind else {
                    throw TransactionJournalError.unsafeRecoveryState(
                        "staged kind mismatch"
                    )
                }
                observedNodes.append(StagedNode(
                    path: childPath,
                    kind: child.identity.kind,
                    identity: child.identity
                ))
                if child.identity.kind == .directory {
                    // Staged content comes from the extractor, so its mode is
                    // the archive's, not the transaction's 0700. Adopt (repair
                    // the mode) rather than require it: the tree is already
                    // transaction-private, and the walk descends top-down so
                    // each parent is owned before its children are adopted.
                    let childHandle = try fileSystem
                        .adoptTransactionOwnedDirectoryNoFollow(
                            parent: handle,
                            name: child.name,
                            expected: child.identity
                        )
                    defer { childHandle.close() }
                    try validateDirectory(path: childPath, handle: childHandle)
                }
            }
        }

        try validateDirectory(path: "", handle: staging)
        if requireComplete {
            guard observedNodes.count == manifest.entries.count,
                  Set(observedNodes.map(\.path)) == Set(kinds.keys)
            else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "incomplete staged inventory"
                )
            }
        }
        return observedNodes.sorted { pathLess($0.path, $1.path) }
    }

    private func publishMissingTopLevelNodes(
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        stagedNodes: [StagedNode],
        publicationExpectations: [String: ExtractionPublicationExpectation],
        replacementSnapshots: [String: CapturedTreeManifest],
        destinationRootIdentity: FileNodeIdentity,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        applied: inout [AppliedMutation]
    ) async throws -> ExtractionResult {
        let nodesByPath = Dictionary(uniqueKeysWithValues: stagedNodes.map {
            ($0.path, $0)
        })
        var directoryModes: [String: UInt16] = [:]
        for entry in inventory.entries where entry.kind == .directory {
            if let mode = entry.posixMode {
                directoryModes[normalizedPath(entry.path)] = mode
            }
        }
        let state = PublicationState(
            applied: applied,
            directoryModes: directoryModes
        )
        defer {
            applied = state.applied
        }
        let topLevelPaths = stagedNodes
            .map(\.path)
            .filter { !$0.contains("/") }
            .sorted { pathLess($0, $1) }

        for path in topLevelPaths {
            guard let node = nodesByPath[path] else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "missing staged top-level identity"
                )
            }
            try await publishNode(
                originalPath: path,
                finalPath: path,
                node: node,
                request: request,
                inventory: inventory,
                nodesByPath: nodesByPath,
                publicationExpectations: publicationExpectations,
                replacementSnapshots: replacementSnapshots,
                destinationRootIdentity: destinationRootIdentity,
                activated: activated,
                context: context,
                state: state
            )
        }

        applied = state.applied
        let published = state.publishedByOriginalPath.values.sorted {
            pathLess($0.finalPath, $1.finalPath)
        }
        let skipped = state.skippedPaths.sorted(by: pathLess)
        return ExtractionResult(
            transactionID: activated.transactionID,
            publishedURLs: published.map(\.url),
            skippedPaths: skipped
        )
    }


    private func publishNode(
        originalPath: String,
        finalPath: String,
        node: StagedNode,
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        nodesByPath: [String: StagedNode],
        publicationExpectations: [String: ExtractionPublicationExpectation],
        replacementSnapshots: [String: CapturedTreeManifest],
        destinationRootIdentity: FileNodeIdentity,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        state: PublicationState
    ) async throws {
        try Task.checkCancellation()
        guard let expectation = publicationExpectations[originalPath],
              expectation.originalPath == originalPath
        else {
            throw ArchiveFailure.extractionPlanChanged
        }

        let stagedParentPath = parentPath(of: originalPath)
        let finalParentPath = parentPath(of: finalPath)
        let stagedParentIdentity = stagedParentPath.isEmpty
            ? activated.stagingIdentity
            : try requiredStagedDirectoryIdentity(
                stagedParentPath,
                nodesByPath: nodesByPath
            )
        let stagedParent = try fileSystem.openRelativeDirectoryNoFollow(
            root: activated.stagingHandle,
            components: pathComponents(stagedParentPath),
            expected: stagedParentIdentity
        )
        defer { stagedParent.close() }
        let destinationParent = try openApprovedDestinationParent(
            rootURL: request.destination,
            rootIdentity: destinationRootIdentity,
            relativePath: finalParentPath,
            publicationExpectations: publicationExpectations
        )
        let destinationName = try requiredLastComponent(finalPath)
        let existing: FileNode?
        do {
            existing = try fileSystem.statNoFollow(
                parent: destinationParent,
                name: destinationName
            )
            destinationParent.close()
        } catch {
            destinationParent.close()
            throw error
        }
        guard existing == expectation.existing else {
            throw ArchiveFailure.extractionPlanChanged
        }

        switch expectation.action {
        case .publish:
            try await attemptPublication(
                originalPath: originalPath,
                finalPath: finalPath,
                node: node,
                stagedParent: stagedParent,
                stagedParentPath: stagedParentPath,
                stagedParentIdentity: stagedParentIdentity,
                destinationParentPath: finalParentPath,
                destinationRootIdentity: destinationRootIdentity,
                publicationExpectations: publicationExpectations,
                request: request,
                inventory: inventory,
                activated: activated,
                context: context,
                state: state
            )
        case .mergeDirectory:
            guard node.kind == .directory,
                  existing?.identity.kind == .directory
            else {
                throw ArchiveFailure.extractionPlanChanged
            }
            // Task 4 changes replacement subtree semantics. Task 3 preserves
            // the current merge behavior while binding every child decision.
            let stagedDirectory = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                parent: stagedParent,
                name: try requiredLastComponent(originalPath),
                expected: node.identity
            )
            defer { stagedDirectory.close() }
            let children = try fileSystem.listNoFollow(stagedDirectory).sorted {
                pathLess(
                    "\(originalPath)/\($0.name)",
                    "\(originalPath)/\($1.name)"
                )
            }
            for child in children {
                let childOriginalPath = "\(originalPath)/\(child.name)"
                guard let childNode = nodesByPath[childOriginalPath],
                      childNode.identity == child.identity
                else {
                    throw TransactionJournalError.unsafeRecoveryState(
                        "staged child identity changed"
                    )
                }
                try await publishNode(
                    originalPath: childOriginalPath,
                    finalPath: "\(finalPath)/\(child.name)",
                    node: childNode,
                    request: request,
                    inventory: inventory,
                    nodesByPath: nodesByPath,
                    publicationExpectations: publicationExpectations,
                    replacementSnapshots: replacementSnapshots,
                    destinationRootIdentity: destinationRootIdentity,
                    activated: activated,
                    context: context,
                    state: state
                )
            }
        case .fail:
            throw ArchiveFailure.destinationConflict(path: originalPath)
        case .skip:
            addSkippedSubtree(originalPath, inventory: inventory, state: state)
        case let .keepBoth(plannedFinalPath):
            try await publishKeepBoth(
                originalPath: originalPath,
                plannedFinalPath: plannedFinalPath,
                node: node,
                stagedParent: stagedParent,
                stagedParentPath: stagedParentPath,
                stagedParentIdentity: stagedParentIdentity,
                destinationParentPath: finalParentPath,
                destinationRootIdentity: destinationRootIdentity,
                publicationExpectations: publicationExpectations,
                request: request,
                inventory: inventory,
                activated: activated,
                context: context,
                state: state
            )
        case .replace:
            guard let expectedExisting = expectation.existing,
                  let capturedManifest = replacementSnapshots[originalPath]
            else {
                throw ArchiveFailure.extractionPlanChanged
            }
            try await replaceBySwap(
                originalPath: originalPath,
                finalPath: finalPath,
                node: node,
                expectedExisting: expectedExisting,
                capturedManifest: capturedManifest,
                stagedParent: stagedParent,
                stagedParentPath: stagedParentPath,
                stagedParentIdentity: stagedParentIdentity,
                destinationParentPath: finalParentPath,
                destinationRootIdentity: destinationRootIdentity,
                publicationExpectations: publicationExpectations,
                request: request,
                inventory: inventory,
                activated: activated,
                context: context,
                state: state
            )
        case .ask:
            throw ArchiveFailure.unresolvedConflictPolicy
        }
    }

    private func replaceBySwap(
        originalPath: String,
        finalPath: String,
        node: StagedNode,
        expectedExisting: FileNode,
        capturedManifest: CapturedTreeManifest,
        stagedParent: DirectoryHandle,
        stagedParentPath: String,
        stagedParentIdentity: FileNodeIdentity,
        destinationParentPath: String,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        state: PublicationState
    ) async throws {
        guard try fileSystem.identity(of: stagedParent) == stagedParentIdentity else {
            throw TransactionJournalError.unsafeRecoveryState(
                "replacement parent identity changed"
            )
        }
        let stagedName = try requiredLastComponent(originalPath)
        let destinationName = try requiredLastComponent(finalPath)
        let recoveryURL = activated.stagingURL.deletingLastPathComponent()
        func rollbackFailure(_ rollback: Error) -> ArchiveFailure {
            ArchiveFailure.rollbackFailed(
                recoveryURL: recoveryURL,
                cause: RollbackCause(
                    original: ArchiveFailure.extractionPlanChanged,
                    rollback: rollback
                )
            )
        }
        if node.kind == .directory {
            try restoreArchiveDirectoryModes(
                stagedPath: originalPath,
                parent: stagedParent,
                name: stagedName,
                identity: node.identity,
                state: state
            )
        }

        let referenceParent = try openApprovedDestinationParent(
            rootURL: request.destination,
            rootIdentity: destinationRootIdentity,
            relativePath: destinationParentPath,
            publicationExpectations: publicationExpectations
        )
        let destinationParentIdentity: FileNodeIdentity
        do {
            destinationParentIdentity = try fileSystem.identity(of: referenceParent)
            guard let currentExisting = try fileSystem.statNoFollow(
                parent: referenceParent,
                name: destinationName
            ), currentExisting == expectedExisting else {
                throw ArchiveFailure.extractionPlanChanged
            }
            let currentManifest = try CapturedTreeManifest.capture(
                rootPath: originalPath,
                rootNode: currentExisting,
                parent: referenceParent,
                fileSystem: fileSystem,
                listingPolicy: request.resourcePolicy.listing
            )
            guard currentManifest == capturedManifest else {
                throw ArchiveFailure.extractionPlanChanged
            }
            referenceParent.close()
        } catch {
            referenceParent.close()
            throw error
        }

        let mutationID = JournalMutationID(rawValue: UUID())
        let stagedReference = JournalNodeReference(
            root: .staging,
            relativeParentPath: stagedParentPath,
            parentIdentity: stagedParentIdentity,
            name: stagedName
        )
        let destinationReference = JournalNodeReference(
            root: .destination,
            relativeParentPath: destinationParentPath,
            parentIdentity: destinationParentIdentity,
            name: destinationName
        )
        try await journal.armReplaceSwap(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            replacementIdentity: node.identity,
            expectedCaptured: capturedManifest,
            transactionID: activated.transactionID
        )
        try Task.checkCancellation()

        let armedStagedParent: DirectoryHandle
        do {
            armedStagedParent = try resolveParent(
                stagedReference,
                destinationURL: request.destination,
                destinationRootIdentity: destinationRootIdentity,
                publicationExpectations: publicationExpectations,
                activated: activated,
                context: context
            )
        } catch {
            throw PostEffectAuthorityFailure(
                reason: "armed replacement staging authority changed: \(error)"
            )
        }
        defer { armedStagedParent.close() }
        let destinationParent: DirectoryHandle
        do {
            destinationParent = try reopenDestinationParent(
                destinationURL: request.destination,
                expectedRootIdentity: destinationRootIdentity,
                relativeParentPath: destinationParentPath,
                expectedParentIdentity: destinationParentIdentity
            )
        } catch {
            throw PostEffectAuthorityFailure(
                reason: "armed replacement destination authority changed: \(error)"
            )
        }
        defer { destinationParent.close() }
        guard try fileSystem.statNoFollow(
            parent: armedStagedParent,
            name: stagedName
        )?.identity == node.identity,
        try fileSystem.statNoFollow(
            parent: destinationParent,
            name: destinationName
        ) == expectedExisting else {
            throw ArchiveFailure.extractionPlanChanged
        }

        let observation: SwapObservation
        do {
            observation = try fileSystem.swapObserved(
                leftParent: armedStagedParent,
                leftName: stagedName,
                expectedLeft: node.identity,
                rightParent: destinationParent,
                rightName: destinationName,
                expectedRight: expectedExisting.identity
            )
        } catch let error as FileSystemOperationError {
            if case .unsupportedTransactionalSwap = error { throw error }
            let currentStaged = try? fileSystem.statNoFollow(
                parent: armedStagedParent,
                name: stagedName
            )?.identity
            let currentDestination = try? fileSystem.statNoFollow(
                parent: destinationParent,
                name: destinationName
            )?.identity
            if currentDestination == node.identity, let currentStaged {
                do {
                    try reverseReplaceSwap(
                        stagedParent: armedStagedParent,
                        stagedName: stagedName,
                        capturedIdentity: currentStaged,
                        destinationParent: destinationParent,
                        destinationName: destinationName,
                        replacementIdentity: node.identity
                    )
                } catch {
                    throw rollbackFailure(error)
                }
                throw ArchiveFailure.extractionPlanChanged
            }
            throw rollbackFailure(
                SwapClaimRecoveryError.inverseObservationMismatch(
                    staged: currentStaged,
                    destination: currentDestination
                )
            )
        }

        guard observation.leftIdentity == expectedExisting.identity,
              observation.rightIdentity == node.identity,
              let currentCaptured = try fileSystem.statNoFollow(
                  parent: armedStagedParent,
                  name: stagedName
              ),
              currentCaptured.identity == expectedExisting.identity,
              try fileSystem.statNoFollow(
                  parent: destinationParent,
                  name: destinationName
              )?.identity == node.identity
        else {
            let currentStaged = try fileSystem.statNoFollow(
                parent: armedStagedParent,
                name: stagedName
            )?.identity
            let currentDestination = try fileSystem.statNoFollow(
                parent: destinationParent,
                name: destinationName
            )?.identity
            guard currentDestination == node.identity,
                  let currentStaged
            else {
                throw rollbackFailure(
                    SwapClaimRecoveryError.inverseObservationMismatch(
                        staged: currentStaged,
                        destination: currentDestination
                    )
                )
            }
            do {
                try reverseReplaceSwap(
                    stagedParent: armedStagedParent,
                    stagedName: stagedName,
                    capturedIdentity: currentStaged,
                    destinationParent: destinationParent,
                    destinationName: destinationName,
                    replacementIdentity: node.identity
                )
            } catch {
                throw rollbackFailure(error)
            }
            throw ArchiveFailure.extractionPlanChanged
        }

        let observedCaptured = try CapturedTreeManifest.capture(
            rootPath: originalPath,
            rootNode: currentCaptured,
            parent: armedStagedParent,
            fileSystem: fileSystem,
            listingPolicy: request.resourcePolicy.listing
        )
        guard capturedManifestMatchesAfterSwap(
            actual: observedCaptured,
            approved: capturedManifest
        ) else {
            do {
                try reverseReplaceSwap(
                    stagedParent: armedStagedParent,
                    stagedName: stagedName,
                    capturedIdentity: currentCaptured.identity,
                    destinationParent: destinationParent,
                    destinationName: destinationName,
                    replacementIdentity: node.identity
                )
            } catch {
                throw rollbackFailure(error)
            }
            throw ArchiveFailure.extractionPlanChanged
        }

        state.applied.append(.replaceSwap(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            replacementIdentity: node.identity,
            capturedManifest: capturedManifest,
            syncCompletion: ReplaceSwapSyncCompletion()
        ))
        try fileSystem.fsync(armedStagedParent)
        try state.markReplaceSwapParentSynced(
            mutationID: mutationID,
            source: true
        )
        try fileSystem.fsync(destinationParent)
        try state.markReplaceSwapParentSynced(
            mutationID: mutationID,
            source: false
        )
        addPublishedSubtree(
            originalPath: originalPath,
            finalPath: finalPath,
            request: request,
            inventory: inventory,
            state: state
        )
    }

    private func reverseReplaceSwap(
        stagedParent: DirectoryHandle,
        stagedName: String,
        capturedIdentity: FileNodeIdentity,
        destinationParent: DirectoryHandle,
        destinationName: String,
        replacementIdentity: FileNodeIdentity
    ) throws {
        let reverse = try fileSystem.swapObserved(
            leftParent: stagedParent,
            leftName: stagedName,
            expectedLeft: capturedIdentity,
            rightParent: destinationParent,
            rightName: destinationName,
            expectedRight: replacementIdentity
        )
        guard reverse.leftIdentity == replacementIdentity,
              reverse.rightIdentity == capturedIdentity
        else {
            throw SwapClaimRecoveryError.inverseObservationMismatch(
                staged: reverse.leftIdentity,
                destination: reverse.rightIdentity
            )
        }
        try fileSystem.fsync(stagedParent)
        try fileSystem.fsync(destinationParent)
    }

    private func reversePublishMove(
        stagedParent: DirectoryHandle,
        stagedName: String,
        destinationParent: DirectoryHandle,
        destinationName: String,
        publishedIdentity: FileNodeIdentity
    ) throws {
        let reverse = try fileSystem.moveExclusiveObserved(
            fromParent: destinationParent,
            fromName: destinationName,
            toParent: stagedParent,
            toName: stagedName,
            expectedSource: publishedIdentity
        )
        if reverse.sourceIdentity == nil,
           reverse.destinationIdentity == publishedIdentity {
            try fileSystem.fsync(destinationParent)
            try fileSystem.fsync(stagedParent)
            return
        }

        if reverse.sourceIdentity == nil,
           let capturedIdentity = reverse.destinationIdentity,
           capturedIdentity != publishedIdentity {
            let restore = try fileSystem.moveExclusiveObserved(
                fromParent: stagedParent,
                fromName: stagedName,
                toParent: destinationParent,
                toName: destinationName,
                expectedSource: capturedIdentity
            )
            guard restore.sourceIdentity == nil,
                  restore.destinationIdentity == capturedIdentity else {
                throw PostEffectAuthorityFailure(
                    reason: "foreign publication capture restoration mismatch"
                )
            }
            try fileSystem.fsync(stagedParent)
            try fileSystem.fsync(destinationParent)
        }

        throw PostEffectAuthorityFailure(
            reason: "publication inverse observation mismatch"
        )
    }

    private func attemptPublication(
        originalPath: String,
        finalPath: String,
        node: StagedNode,
        stagedParent: DirectoryHandle,
        stagedParentPath: String,
        stagedParentIdentity: FileNodeIdentity,
        destinationParentPath: String,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        state: PublicationState
    ) async throws {
        guard try fileSystem.identity(of: stagedParent) == stagedParentIdentity else {
            throw TransactionJournalError.unsafeRecoveryState(
                "publication parent identity changed"
            )
        }
        let referenceParent = try openApprovedDestinationParent(
            rootURL: request.destination,
            rootIdentity: destinationRootIdentity,
            relativePath: destinationParentPath,
            publicationExpectations: publicationExpectations
        )
        let destinationParentIdentity: FileNodeIdentity
        do {
            destinationParentIdentity = try fileSystem.identity(of: referenceParent)
            referenceParent.close()
        } catch {
            referenceParent.close()
            throw error
        }
        let stagedName = try requiredLastComponent(originalPath)
        let destinationName = try requiredLastComponent(finalPath)
        let stagedReference = JournalNodeReference(
            root: .staging,
            relativeParentPath: stagedParentPath,
            parentIdentity: stagedParentIdentity,
            name: stagedName
        )
        let destinationReference = JournalNodeReference(
            root: .destination,
            relativeParentPath: destinationParentPath,
            parentIdentity: destinationParentIdentity,
            name: destinationName
        )
        let mutationID = JournalMutationID(rawValue: UUID())
        try await journal.armPublishMove(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            publishedIdentity: node.identity,
            transactionID: activated.transactionID
        )
        try Task.checkCancellation()
        let armedStagedParent: DirectoryHandle
        do {
            armedStagedParent = try resolveParent(
                stagedReference,
                destinationURL: request.destination,
                destinationRootIdentity: destinationRootIdentity,
                publicationExpectations: publicationExpectations,
                activated: activated,
                context: context
            )
        } catch {
            throw PostEffectAuthorityFailure(
                reason: "armed publication staging authority changed: \(error)"
            )
        }
        defer { armedStagedParent.close() }
        // Publication renames the staged node and everything under it in a
        // single step, so this is the last moment at which the transaction can
        // still reach the subtree's directories. Their modes are restored here,
        // deepest-first, so the user receives what the archive recorded instead
        // of the private 0700 the transaction worked under.
        if node.kind == .directory {
            try restoreArchiveDirectoryModes(
                stagedPath: originalPath,
                parent: armedStagedParent,
                name: stagedName,
                identity: node.identity,
                state: state
            )
        }
        let destinationParent = try reopenDestinationParent(
            destinationURL: request.destination,
            expectedRootIdentity: destinationRootIdentity,
            relativeParentPath: destinationParentPath,
            expectedParentIdentity: destinationParentIdentity
        )
        defer { destinationParent.close() }
        guard try fileSystem.statNoFollow(
            parent: destinationParent,
            name: destinationName
        ) == nil else {
            throw ArchiveFailure.extractionPlanChanged
        }
        try Task.checkCancellation()
        let observation: MoveObservation
        do {
            observation = try fileSystem.moveExclusiveObserved(
                fromParent: armedStagedParent,
                fromName: stagedName,
                toParent: destinationParent,
                toName: destinationName,
                expectedSource: node.identity
            )
        } catch let error as FileSystemOperationError {
            if case .alreadyExists = error {
                throw ArchiveFailure.extractionPlanChanged
            }
            if case .identityMismatch = error {
                throw ArchiveFailure.extractionPlanChanged
            }
            throw error
        }
        guard observation.sourceIdentity == nil,
              observation.destinationIdentity == node.identity
        else {
            throw PostEffectAuthorityFailure(
                reason: "publication move completion could not be verified"
            )
        }
        state.applied.append(.publishMove(
            mutationID: mutationID,
            staged: stagedReference,
            destination: destinationReference,
            identity: node.identity
        ))
        let currentDestinationParent = try revalidateDestinationAuthorityAfterMove(
            destinationURL: request.destination,
            expectedRootIdentity: destinationRootIdentity,
            relativeParentPath: destinationParentPath,
            expectedParentIdentity: destinationParentIdentity,
            movedNodeIsInDestinationParent: true,
            movedParent: destinationParent,
            movedName: destinationName,
            expectedMovedIdentity: node.identity
        )
        defer { currentDestinationParent.close() }
        try fileSystem.fsync(armedStagedParent)
        try fileSystem.fsync(currentDestinationParent)
        addPublishedSubtree(
            originalPath: originalPath,
            finalPath: finalPath,
            request: request,
            inventory: inventory,
            state: state
        )
    }

    /// Restores archive-recorded modes on a staged directory subtree, children
    /// before parents.
    ///
    /// The post-order walk is required rather than stylistic: relaxing a parent
    /// first can remove the write or execute permission the transaction needs to
    /// reach its own children. Each directory is adopted before it is modified,
    /// so authority is re-proven at every level and a swapped node is rejected
    /// rather than chmod'ed.
    ///
    /// Only directories are touched; file modes are left as the extractor wrote
    /// them.
    private func restoreArchiveDirectoryModes(
        stagedPath: String,
        parent: DirectoryHandle,
        name: String,
        identity: FileNodeIdentity,
        state: PublicationState
    ) throws {
        try Task.checkCancellation()
        let handle = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: parent,
            name: name,
            expected: identity
        )
        defer { handle.close() }
        for child in try fileSystem.listNoFollow(handle)
        where child.identity.kind == .directory {
            try restoreArchiveDirectoryModes(
                stagedPath: stagedPath.isEmpty ? child.name : "\(stagedPath)/\(child.name)",
                parent: handle,
                name: child.name,
                identity: child.identity,
                state: state
            )
        }
        let requested = state.directoryModes[normalizedPath(stagedPath)]
            ?? Self.defaultPublishedDirectoryMode
        try Task.checkCancellation()
        try fileSystem.setTransactionOwnedDirectoryMode(
            handle,
            mode: Self.publishableDirectoryMode(requested)
        )
    }

    private func publishKeepBoth(
        originalPath: String,
        plannedFinalPath: String,
        node: StagedNode,
        stagedParent: DirectoryHandle,
        stagedParentPath: String,
        stagedParentIdentity: FileNodeIdentity,
        destinationParentPath: String,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        state: PublicationState
    ) async throws {
        guard parentPath(of: plannedFinalPath) == destinationParentPath else {
            throw ArchiveFailure.extractionPlanChanged
        }
        let candidateName = try requiredLastComponent(plannedFinalPath)
        let destinationParent = try openApprovedDestinationParent(
            rootURL: request.destination,
            rootIdentity: destinationRootIdentity,
            relativePath: destinationParentPath,
            publicationExpectations: publicationExpectations
        )
        let candidateIsAbsent: Bool
        do {
            candidateIsAbsent = try fileSystem.statNoFollow(
                parent: destinationParent,
                name: candidateName
            ) == nil
            destinationParent.close()
        } catch {
            destinationParent.close()
            throw error
        }
        guard candidateIsAbsent else {
            throw ArchiveFailure.extractionPlanChanged
        }
        try await attemptPublication(
            originalPath: originalPath,
            finalPath: plannedFinalPath,
            node: node,
            stagedParent: stagedParent,
            stagedParentPath: stagedParentPath,
            stagedParentIdentity: stagedParentIdentity,
            destinationParentPath: destinationParentPath,
            destinationRootIdentity: destinationRootIdentity,
            publicationExpectations: publicationExpectations,
            request: request,
            inventory: inventory,
            activated: activated,
            context: context,
            state: state
        )
    }

    private func reopenDestinationParent(
        destinationURL: URL,
        expectedRootIdentity: FileNodeIdentity,
        relativeParentPath: String,
        expectedParentIdentity: FileNodeIdentity
    ) throws -> DirectoryHandle {
        let root: DirectoryHandle
        do {
            root = try fileSystem.openDirectoryNoFollow(at: destinationURL)
        } catch is FileSystemOperationError {
            throw ArchiveFailure.extractionPlanChanged
        }
        defer { root.close() }

        do {
            guard try fileSystem.identity(of: root) == expectedRootIdentity else {
                throw ArchiveFailure.extractionPlanChanged
            }
            let parent = try fileSystem.openRelativeDirectoryNoFollow(
                root: root,
                components: pathComponents(relativeParentPath),
                expected: expectedParentIdentity
            )
            do {
                guard try fileSystem.identity(of: parent) == expectedParentIdentity else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                return parent
            } catch {
                parent.close()
                throw error
            }
        } catch let failure as ArchiveFailure {
            throw failure
        } catch is FileSystemOperationError {
            throw ArchiveFailure.extractionPlanChanged
        }
    }

    private func revalidateDestinationAuthorityAfterMove(
        destinationURL: URL,
        expectedRootIdentity: FileNodeIdentity,
        relativeParentPath: String,
        expectedParentIdentity: FileNodeIdentity,
        movedNodeIsInDestinationParent: Bool,
        movedParent: DirectoryHandle,
        movedName: String,
        expectedMovedIdentity: FileNodeIdentity
    ) throws -> DirectoryHandle {
        let currentDestinationParent: DirectoryHandle
        do {
            currentDestinationParent = try reopenDestinationParent(
                destinationURL: destinationURL,
                expectedRootIdentity: expectedRootIdentity,
                relativeParentPath: relativeParentPath,
                expectedParentIdentity: expectedParentIdentity
            )
        } catch {
            throw PostEffectAuthorityFailure(
                reason: "destination authority changed after move"
            )
        }

        let observedParent = movedNodeIsInDestinationParent
            ? currentDestinationParent
            : movedParent
        do {
            guard try fileSystem.statNoFollow(
                parent: observedParent,
                name: movedName
            )?.identity == expectedMovedIdentity else {
                currentDestinationParent.close()
                throw PostEffectAuthorityFailure(
                    reason: "moved destination identity changed"
                )
            }
            return currentDestinationParent
        } catch let failure as PostEffectAuthorityFailure {
            throw failure
        } catch {
            currentDestinationParent.close()
            throw PostEffectAuthorityFailure(
                reason: "moved destination identity could not be verified"
            )
        }
    }

    private func openApprovedDestinationParent(
        rootURL: URL,
        rootIdentity: FileNodeIdentity,
        relativePath: String,
        publicationExpectations: [String: ExtractionPublicationExpectation]
    ) throws -> DirectoryHandle {
        let root: DirectoryHandle
        do {
            root = try fileSystem.openDirectoryNoFollow(at: rootURL)
        } catch is FileSystemOperationError {
            throw ArchiveFailure.extractionPlanChanged
        }

        var current = root
        do {
            guard try fileSystem.identity(of: current) == rootIdentity else {
                throw ArchiveFailure.extractionPlanChanged
            }
            var traversed: [String] = []
            for component in pathComponents(relativePath) {
                traversed.append(component)
                let path = traversed.joined(separator: "/")
                guard let expectation = publicationExpectations[path],
                      expectation.action == .mergeDirectory,
                      let identity = expectation.existing?.identity,
                      identity.kind == .directory
                else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                let next = try fileSystem.openDirectoryNoFollow(
                    parent: current,
                    name: component,
                    expected: identity
                )
                current.close()
                current = next
            }
            return current
        } catch let failure as ArchiveFailure {
            current.close()
            throw failure
        } catch is FileSystemOperationError {
            current.close()
            throw ArchiveFailure.extractionPlanChanged
        } catch {
            current.close()
            throw error
        }
    }

    private func addPublishedSubtree(
        originalPath: String,
        finalPath: String,
        request: ExtractionRequest,
        inventory: ExtractionInventory,
        state: PublicationState
    ) {
        for entry in inventory.entries
        where entry.path == originalPath
            || entry.path.hasPrefix("\(originalPath)/") {
            let suffix = String(entry.path.dropFirst(originalPath.count))
            let mappedPath = finalPath + suffix
            state.publishedByOriginalPath[entry.path] = PublishedEntry(
                finalPath: mappedPath,
                url: appendingRelativePath(
                    mappedPath,
                    to: request.destination,
                    isDirectory: entry.kind == .directory
                )
            )
        }
    }

    private func addSkippedSubtree(
        _ originalPath: String,
        inventory: ExtractionInventory,
        state: PublicationState
    ) {
        for entry in inventory.entries
        where entry.path == originalPath
            || entry.path.hasPrefix("\(originalPath)/") {
            state.skippedPaths.insert(entry.path)
        }
    }

    private func appendingRelativePath(
        _ relativePath: String,
        to root: URL,
        isDirectory: Bool
    ) -> URL {
        let components = pathComponents(relativePath)
        var result = root
        for index in components.indices {
            result.appendPathComponent(
                components[index],
                isDirectory: index == components.index(before: components.endIndex)
                    ? isDirectory
                    : true
            )
        }
        return result
    }

    private func requiredStagedDirectoryIdentity(
        _ path: String,
        nodesByPath: [String: StagedNode]
    ) throws -> FileNodeIdentity {
        guard let node = nodesByPath[path], node.kind == .directory else {
            throw TransactionJournalError.unsafeRecoveryState(
                "missing staged parent authority"
            )
        }
        return node.identity
    }

    private func capturedManifestMatchesAfterSwap(
        actual: CapturedTreeManifest,
        approved: CapturedTreeManifest
    ) -> Bool {
        guard actual.rootPath == approved.rootPath,
              actual.entries.count == approved.entries.count
        else { return false }
        return zip(actual.entries, approved.entries).allSatisfy { actualEntry, approvedEntry in
            actualEntry.relativePath == approvedEntry.relativePath
                && actualEntry.identity == approvedEntry.identity
                && actualEntry.byteCount == approvedEntry.byteCount
                && actualEntry.allocatedByteCount == approvedEntry.allocatedByteCount
                && actualEntry.timestamps == approvedEntry.timestamps
                && actualEntry.linkTarget == approvedEntry.linkTarget
                && (
                    actualEntry.relativePath.isEmpty
                    || actualEntry.statusChangeTimestamp == approvedEntry.statusChangeTimestamp
                )
        }
    }

    private func requiredLastComponent(_ path: String) throws -> String {
        guard let component = pathComponents(path).last, !component.isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState(
                "missing path component"
            )
        }
        return component
    }

    private func parentPath(of path: String) -> String {
        pathComponents(path).dropLast().joined(separator: "/")
    }

    private func keepBothName(_ name: String, index: Int) -> String {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              dot != name.index(before: name.endIndex)
        else {
            return "\(name)_\(index)"
        }
        return "\(name[..<dot])_\(index)\(name[dot...])"
    }

    private func validateCommitReadiness(
        transactionID: TransactionID,
        destinationURL: URL,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        listingPolicy: ArchiveResourcePolicy.Listing,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        applied: [AppliedMutation]
    ) async throws {
        let armed = try await journal.recordsForRecovery(transactionID)
        let commitApplied = applied.map { mutation in
            guard let replaceSwapSyncCompletionBeforeCommit,
                  case let .replaceSwap(
                    mutationID,
                    staged,
                    destination,
                    replacementIdentity,
                    capturedManifest,
                    syncCompletion
                  ) = mutation else {
                return mutation
            }
            return AppliedMutation.replaceSwap(
                mutationID: mutationID,
                staged: staged,
                destination: destination,
                replacementIdentity: replacementIdentity,
                capturedManifest: capturedManifest,
                syncCompletion: replaceSwapSyncCompletionBeforeCommit(syncCompletion)
            )
        }
        guard armed.count == commitApplied.count else {
            throw PostEffectAuthorityFailure(
                reason: "armed mutation count does not match applied state"
            )
        }

        var appliedByID: [JournalMutationID: AppliedMutation] = [:]
        for mutation in commitApplied {
            let mutationID: JournalMutationID
            switch mutation {
            case let .publishMove(id, _, _, _),
                 let .replaceSwap(id, _, _, _, _, _):
                mutationID = id
            }
            guard appliedByID.updateValue(mutation, forKey: mutationID) == nil else {
                throw PostEffectAuthorityFailure(
                    reason: "duplicate applied mutation identifier"
                )
            }
        }

        for mutation in armed {
            switch mutation {
            case let .publishMove(
                mutationID,
                staged,
                destination,
                publishedIdentity
            ):
                guard case let .publishMove(
                    appliedID,
                    appliedStaged,
                    appliedDestination,
                    appliedIdentity
                )? = appliedByID.removeValue(forKey: mutationID),
                appliedID == mutationID,
                appliedStaged == staged,
                appliedDestination == destination,
                appliedIdentity == publishedIdentity else {
                    throw PostEffectAuthorityFailure(
                        reason: "armed publication does not match applied state"
                    )
                }
                let stagedParent = try resolveParent(
                    staged,
                    destinationURL: destinationURL,
                    destinationRootIdentity: destinationRootIdentity,
                    publicationExpectations: publicationExpectations,
                    activated: activated,
                    context: context
                )
                defer { stagedParent.close() }
                let destinationParent = try resolveParent(
                    destination,
                    destinationURL: destinationURL,
                    destinationRootIdentity: destinationRootIdentity,
                    publicationExpectations: publicationExpectations,
                    activated: activated,
                    context: context
                )
                defer { destinationParent.close() }
                guard try fileSystem.statNoFollow(
                    parent: stagedParent,
                    name: staged.name
                ) == nil,
                try fileSystem.statNoFollow(
                    parent: destinationParent,
                    name: destination.name
                )?.identity == publishedIdentity else {
                    throw PostEffectAuthorityFailure(
                        reason: "armed publication occupancy is not commit-ready"
                    )
                }
            case let .replaceSwap(
                mutationID,
                staged,
                destination,
                replacementIdentity,
                expectedCaptured,
                recoveryCapturedIdentity
            ):
                guard recoveryCapturedIdentity == nil,
                      case let .replaceSwap(
                    appliedID,
                    appliedStaged,
                    appliedDestination,
                    appliedReplacement,
                    appliedCaptured,
                    syncCompletion
                )? = appliedByID.removeValue(forKey: mutationID),
                appliedID == mutationID,
                appliedStaged == staged,
                appliedDestination == destination,
                appliedReplacement == replacementIdentity,
                appliedCaptured == expectedCaptured else {
                    throw PostEffectAuthorityFailure(
                        reason: "armed replacement does not match applied state"
                    )
                }
                guard syncCompletion.isComplete else {
                    throw PostEffectAuthorityFailure(
                        reason: "armed replacement parent sync is incomplete",
                        allowsRollback: true
                    )
                }
                let stagedParent = try resolveParent(
                    staged,
                    destinationURL: destinationURL,
                    destinationRootIdentity: destinationRootIdentity,
                    publicationExpectations: publicationExpectations,
                    activated: activated,
                    context: context
                )
                defer { stagedParent.close() }
                let destinationParent = try resolveParent(
                    destination,
                    destinationURL: destinationURL,
                    destinationRootIdentity: destinationRootIdentity,
                    publicationExpectations: publicationExpectations,
                    activated: activated,
                    context: context
                )
                defer { destinationParent.close() }
                guard let capturedRoot = try fileSystem.statNoFollow(
                    parent: stagedParent,
                    name: staged.name
                ),
                capturedRoot.identity == expectedCaptured.entries.first(where: {
                    $0.relativePath.isEmpty
                })?.identity,
                try fileSystem.statNoFollow(
                    parent: destinationParent,
                    name: destination.name
                )?.identity == replacementIdentity else {
                    throw PostEffectAuthorityFailure(
                        reason: "armed replacement occupancy is not commit-ready"
                    )
                }
                let currentCaptured = try CapturedTreeManifest.capture(
                    rootPath: expectedCaptured.rootPath,
                    rootNode: capturedRoot,
                    parent: stagedParent,
                    fileSystem: fileSystem,
                    listingPolicy: listingPolicy
                )
                guard capturedManifestMatchesAfterSwap(
                    actual: currentCaptured,
                    approved: expectedCaptured
                ) else {
                    throw PostEffectAuthorityFailure(
                        reason: "captured replacement manifest is not commit-ready"
                    )
                }
            }
        }
        guard appliedByID.isEmpty else {
            throw PostEffectAuthorityFailure(
                reason: "applied mutation is not armed"
            )
        }
    }

    private func rollbackOrThrow(
        originalError: Error,
        transactionID: TransactionID,
        recoveryURL: URL,
        manifest: StagingCleanupManifest,
        expectedStagedNodes: [StagedNode]?,
        destinationURL: URL,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        listingPolicy: ArchiveResourcePolicy.Listing,
        activated: ActivatedExtractionTransaction,
        context: ActiveContext,
        applied: [AppliedMutation]
    ) async throws {
        do {
            for mutation in applied.reversed() {
                switch mutation {
                case let .publishMove(_, staged, destinationReference, identity):
                    let fromParent = try resolveParent(
                        destinationReference,
                        destinationURL: destinationURL,
                        destinationRootIdentity: destinationRootIdentity,
                        publicationExpectations: publicationExpectations,
                        activated: activated,
                        context: context
                    )
                    defer { fromParent.close() }
                    let toParent = try resolveParent(
                        staged,
                        destinationURL: destinationURL,
                        destinationRootIdentity: destinationRootIdentity,
                        publicationExpectations: publicationExpectations,
                        activated: activated,
                        context: context
                    )
                    defer { toParent.close() }
                    try reversePublishMove(
                        stagedParent: toParent,
                        stagedName: staged.name,
                        destinationParent: fromParent,
                        destinationName: destinationReference.name,
                        publishedIdentity: identity
                    )
                    do {
                        let currentDestinationParent = try resolveParent(
                            destinationReference,
                            destinationURL: destinationURL,
                            destinationRootIdentity: destinationRootIdentity,
                            publicationExpectations: publicationExpectations,
                            activated: activated,
                            context: context
                        )
                        defer { currentDestinationParent.close() }
                        guard try fileSystem.statNoFollow(
                            parent: currentDestinationParent,
                            name: destinationReference.name
                        ) == nil else {
                            throw PostEffectAuthorityFailure(
                                reason: "publication rollback destination is occupied"
                            )
                        }
                    } catch {
                        throw PostEffectAuthorityFailure(
                            reason: "publication rollback destination authority changed: \(error)"
                        )
                    }
                case let .replaceSwap(
                    _,
                    staged,
                    destinationReference,
                    replacementIdentity,
                    capturedManifest,
                    _
                ):
                    let stagedParent = try resolveParent(
                        staged,
                        destinationURL: destinationURL,
                        destinationRootIdentity: destinationRootIdentity,
                        publicationExpectations: publicationExpectations,
                        activated: activated,
                        context: context
                    )
                    defer { stagedParent.close() }
                    let destinationParent = try resolveParent(
                        destinationReference,
                        destinationURL: destinationURL,
                        destinationRootIdentity: destinationRootIdentity,
                        publicationExpectations: publicationExpectations,
                        activated: activated,
                        context: context
                    )
                    defer { destinationParent.close() }
                    guard let capturedRoot = try fileSystem.statNoFollow(
                        parent: stagedParent,
                        name: staged.name
                    ),
                    capturedRoot.identity == capturedManifest.entries.first(where: {
                        $0.relativePath.isEmpty
                    })?.identity,
                    try fileSystem.statNoFollow(
                        parent: destinationParent,
                        name: destinationReference.name
                    )?.identity == replacementIdentity else {
                        throw TransactionJournalError.unsafeRecoveryState(
                            "replacement rollback occupancy changed"
                        )
                    }
                    let currentCaptured = try CapturedTreeManifest.capture(
                        rootPath: capturedManifest.rootPath,
                        rootNode: capturedRoot,
                        parent: stagedParent,
                        fileSystem: fileSystem,
                        listingPolicy: listingPolicy
                    )
                    guard capturedManifestMatchesAfterSwap(
                        actual: currentCaptured,
                        approved: capturedManifest
                    ) else {
                        throw TransactionJournalError.unsafeRecoveryState(
                            "replacement rollback captured manifest changed"
                        )
                    }
                    try reverseReplaceSwap(
                        stagedParent: stagedParent,
                        stagedName: staged.name,
                        capturedIdentity: capturedRoot.identity,
                        destinationParent: destinationParent,
                        destinationName: destinationReference.name,
                        replacementIdentity: replacementIdentity
                    )
                }
            }

            let currentStagedNodes = try validateStaging(
                manifest: manifest,
                staging: activated.stagingHandle,
                requireComplete: false,
                stagingByteCap: nil
            )
            if let expectedStagedNodes {
                let expectedIdentities = Dictionary(uniqueKeysWithValues: expectedStagedNodes.map {
                    ($0.path, $0.identity)
                })
                guard currentStagedNodes.allSatisfy({
                          expectedIdentities[$0.path] == $0.identity
                      })
                else {
                    throw TransactionJournalError.unsafeRecoveryState(
                        "staged identity changed after validation"
                    )
                }
            }
            try await journal.markRolledBack(transactionID)
            try cleanupOwnedInventory(
                manifest: manifest,
                root: activated.stagingHandle
            )
            try cleanupActiveRoot(activated: activated, context: context)
            try await journal.releaseRolledBack(transactionID)
        } catch {
            // `originalError` used to be discarded here (`_ = originalError`),
            // so a failed rollback reported neither why the extraction failed
            // nor why the cleanup could not undo it. Both now travel with the
            // error; they are usually different problems needing different
            // remedies.
            throw ArchiveFailure.rollbackFailed(
                recoveryURL: recoveryURL,
                cause: RollbackCause(original: originalError, rollback: error)
            )
        }
    }

    private func cleanupOwnedInventory(
        manifest: StagingCleanupManifest,
        root: DirectoryHandle
    ) throws {
        let kinds = Dictionary(uniqueKeysWithValues: manifest.entries.map {
            ($0.relativePath, $0.kind)
        })
        let ordered = manifest.entries.sorted {
            let leftDepth = pathComponents($0.relativePath).count
            let rightDepth = pathComponents($1.relativePath).count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return pathLess($1.relativePath, $0.relativePath)
        }
        for entry in ordered {
            let components = pathComponents(entry.relativePath)
            let parentComponents = Array(components.dropLast())
            // The manifest lists what the archive declares, not what reached
            // staging: an extractor that failed early may have created nothing.
            // A missing parent means the node cannot exist either, so there is
            // nothing to clean — same as the missing-node case just below.
            guard let parent = try openOwnedStagedParent(
                root: root,
                components: parentComponents
            ) else { continue }
            defer { parent.close() }
            guard let name = components.last,
                  let observed = try fileSystem.statNoFollow(parent: parent, name: name)
            else {
                try fileSystem.fsync(parent)
                continue
            }
            guard kinds[entry.relativePath] == observed.identity.kind else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "cleanup staged kind mismatch"
                )
            }
            if observed.identity.kind == .directory {
                // Cleanup runs on the rollback path, where the extractor may
                // have died mid-write and left archive-mode directories behind.
                // Adoption is what makes rollback possible in that state.
                let directory = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                    parent: parent,
                    name: name,
                    expected: observed.identity
                )
                let isEmpty = try fileSystem.listNoFollow(directory).isEmpty
                directory.close()
                guard isEmpty else {
                    throw TransactionJournalError.unsafeRecoveryState(
                        "cleanup staged directory not empty"
                    )
                }
            }
            try fileSystem.removeOwnedNoFollow(
                parent: parent,
                name: name,
                expected: observed.identity
            )
            try fileSystem.fsync(parent)
        }
        guard try fileSystem.listNoFollow(root).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState(
                "staging inventory remains"
            )
        }
    }


    /// Opens a staged parent directory, adopting every level on the way down.
    ///
    /// Staged directories do not reliably sit at the transaction's private 0700:
    /// the extractor creates them at the archive's mode, and publication
    /// deliberately restores the archive mode before renaming a node out of
    /// staging. When that rename does not happen (a skipped node, a name
    /// collision, a later failure) rollback moves the relaxed directory back
    /// into staging, and cleanup then has to descend through it.
    ///
    /// `openRelativeDirectoryNoFollow` does not repair modes, so using it here
    /// left `removeOwnedNoFollow`'s exact-0700 ownership check to fail with
    /// EPERM — turning an ordinary conflict into `rollbackFailed`. Adopting each
    /// level repairs it, matching how recovery walks the same trees.
    ///
    /// Returns `nil` when a component does not exist, mirroring
    /// `ExtractionRecovery.openOwnedPathIfPresent`: absence is an expected
    /// outcome on the rollback path, not corruption. Treating it as corruption
    /// would replace the caller's original error with `rollbackFailed` and hide
    /// why the extraction failed in the first place.
    private func openOwnedStagedParent(
        root: DirectoryHandle,
        components: [String]
    ) throws -> DirectoryHandle? {
        var current = try fileSystem.openRelativeDirectoryNoFollow(
            root: root,
            components: [],
            expected: nil
        )
        for component in components {
            guard let observed = try fileSystem.statNoFollow(
                parent: current,
                name: component
            ) else {
                current.close()
                return nil
            }
            guard observed.identity.kind == .directory else {
                current.close()
                throw TransactionJournalError.unsafeRecoveryState(
                    "cleanup staged parent kind"
                )
            }
            let next = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                parent: current,
                name: component,
                expected: observed.identity
            )
            current.close()
            current = next
        }
        return current
    }

    private func cleanupActiveRoot(
        activated: ActivatedExtractionTransaction,
        context: ActiveContext
    ) throws {
        let stagingName = activated.stagingURL.lastPathComponent
        activated.close()
        try fileSystem.removeOwnedNoFollow(
            parent: context.rootHandle,
            name: context.journalNode.name,
            expected: context.journalNode.identity
        )
        try fileSystem.removeOwnedNoFollow(
            parent: context.rootHandle,
            name: stagingName,
            expected: activated.stagingIdentity
        )
        try fileSystem.fsync(context.rootHandle)
        guard try fileSystem.listNoFollow(context.rootHandle).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState(
                "transaction root remains occupied"
            )
        }
        context.rootHandle.close()
        try fileSystem.removeOwnedNoFollow(
            parent: context.namespaceHandle,
            name: context.rootName,
            expected: context.rootIdentity
        )
        try fileSystem.fsync(context.namespaceHandle)
    }

    private func resolveParent(
        _ reference: JournalNodeReference,
        destinationURL: URL,
        destinationRootIdentity: FileNodeIdentity,
        publicationExpectations: [String: ExtractionPublicationExpectation],
        activated: ActivatedExtractionTransaction,
        context: ActiveContext
    ) throws -> DirectoryHandle {
        if reference.root == .destination {
            let parent = try openApprovedDestinationParent(
                rootURL: destinationURL,
                rootIdentity: destinationRootIdentity,
                relativePath: reference.relativeParentPath,
                publicationExpectations: publicationExpectations
            )
            do {
                guard try fileSystem.identity(of: parent) == reference.parentIdentity else {
                    throw ArchiveFailure.extractionPlanChanged
                }
                return parent
            } catch {
                parent.close()
                throw error
            }
        }

        let namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: context.namespace.url,
            expected: context.namespace.identity
        )
        defer { namespace.close() }
        let transactionRoot = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: context.rootName,
            expected: context.rootIdentity
        )
        defer { transactionRoot.close() }
        guard reference.root == .staging else {
            preconditionFailure("destination handled above")
        }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: transactionRoot,
            name: activated.stagingURL.lastPathComponent,
            expected: activated.stagingIdentity
        )
        defer { root.close() }
        let components = reference.relativeParentPath.isEmpty
            ? []
            : pathComponents(reference.relativeParentPath)
        return try fileSystem.openRelativeDirectoryNoFollow(
            root: root,
            components: components,
            expected: reference.parentIdentity
        )
    }

    private func pathComponents(_ path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func pathLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = pathComponents(lhs)
        let right = pathComponents(rhs)
        for index in 0..<min(left.count, right.count) {
            if left[index] == right[index] { continue }
            return Array(left[index].utf8).lexicographicallyPrecedes(
                Array(right[index].utf8)
            )
        }
        return left.count < right.count
    }
}
