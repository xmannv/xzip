import Foundation
import XZIPCore
import XZIPDomain

enum ExtractionRecoveryBoundary: Equatable, Sendable {
    case afterInverseRename
    case afterInverseSourceParentSync
    case afterInverseDestinationParentSync
    case afterInverseTargetVerification
    case afterRolledBackStagingRemoval
    case afterRolledBackPhasePersisted
    case afterRecoveryEntryReleased
}

protocol ExtractionRecoveryObserving: Sendable {
    func didReach(_ boundary: ExtractionRecoveryBoundary) throws
}

public protocol ExtractionPreparationAborting: Sendable {
    func abortPreparation(transactionID: TransactionID) async throws
}


protocol CommittedExtractionFinalizing: Sendable {
    func finalizeCommittedExtraction(operationID: OperationID) async throws
}

public actor ExtractionRecoveryCoordinator:
    ExtractionPreparationAborting,
    CommittedExtractionFinalizing
{
    private let journals: TransactionJournalStore
    private let fileSystem: any FileSystemOperations
    private let observer: (any ExtractionRecoveryObserving)?

    public init(
        journals: TransactionJournalStore,
        fileSystem: any FileSystemOperations
    ) {
        self.journals = journals
        self.fileSystem = fileSystem
        observer = nil
    }


    init(
        journals: TransactionJournalStore,
        fileSystem: any FileSystemOperations,
        observer: (any ExtractionRecoveryObserving)?
    ) {
        self.journals = journals
        self.fileSystem = fileSystem
        self.observer = observer
    }


    public func abortPreparation(transactionID: TransactionID) async throws {
        guard let entry = try await journals.beginPreparationAbort(
            transactionID: transactionID
        ) else {
            return
        }
        do {
            switch entry.phase {
            case .reserved:
                try recoverReserved(entry)
            case .rootCreated:
                try recoverPartialRoot(entry)
            case .active, .rolledBack, .committed:
                throw TransactionJournalError.invalidTransition
            }
            try await journals.completePreparationAbort(
                transactionID: transactionID
            )
        } catch {
            await journals.cancelPreparationAbort(transactionID: transactionID)
            throw error
        }
    }


    func finalizeCommittedExtraction(
        operationID: OperationID
    ) async throws {
        guard let entry = try await journals.committedEntryForFinalization(
            operationID: operationID
        ) else {
            return
        }
        try await cleanupCommitted(entry)
        try await journals.releaseCommitted(operationID: operationID)
    }

    public func recoverLiveTransactions() async throws {
        for entry in try await journals.recoveryEntries() {
            do {
                try await recover(entry)
            } catch let failure as ArchiveFailure {
                throw failure
            } catch {
                throw ArchiveFailure.rollbackFailed(
                    recoveryURL: entry.namespace.url.appendingPathComponent(
                        entry.rootName,
                        isDirectory: true
                    ),
                    cause: RollbackCause(original: nil, rollback: error)
                )
            }
        }
    }

    private func recover(_ entry: RecoveryIndexEntry) async throws {
        switch entry.phase {
        case .reserved:
            try recoverReserved(entry)
            try await journals.releaseRecoveryEntry(entry.header.transactionID)
        case .rootCreated:
            try recoverPartialRoot(entry)
            try await journals.releaseRecoveryEntry(entry.header.transactionID)
        case .active:
            let armedMutations = try await journals.recordsForRecovery(
                entry.header.transactionID
            )
            try await recoverActive(entry, armedMutations: armedMutations)
            try await journals.persistRecoveryPhase(
                .rolledBack,
                transactionID: entry.header.transactionID
            )
            try observer?.didReach(.afterRolledBackPhasePersisted)
            try cleanupRolledBack(entry)
            try await journals.releaseRecoveryEntry(entry.header.transactionID)
            try observer?.didReach(.afterRecoveryEntryReleased)
        case .rolledBack:
            try cleanupRolledBack(entry)
            try await journals.releaseRecoveryEntry(entry.header.transactionID)
        case .committed:
            try await cleanupCommitted(entry)
        }
    }

    private func recoverReserved(_ entry: RecoveryIndexEntry) throws {
        let namespace = try openNamespace(entry)
        defer { namespace.close() }
        guard let node = try fileSystem.statNoFollow(parent: namespace, name: entry.rootName) else {
            try fileSystem.fsync(namespace)
            return
        }
        guard node.identity.kind == .directory else {
            throw TransactionJournalError.unsafeRecoveryState("reserved root kind")
        }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: node.identity
        )
        defer { root.close() }
        guard try fileSystem.listNoFollow(root).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState("reserved root is not empty")
        }
        try fileSystem.fsync(root)
        root.close()
        try fileSystem.removeOwnedNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: node.identity
        )
    }

    private func recoverPartialRoot(_ entry: RecoveryIndexEntry) throws {
        let namespace = try openNamespace(entry)
        defer { namespace.close() }
        guard let expectedRoot = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        guard let observed = try fileSystem.statNoFollow(parent: namespace, name: entry.rootName) else {
            try fileSystem.fsync(namespace)
            return
        }
        guard observed.identity == expectedRoot else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedRoot,
                actual: observed.identity
            )
        }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expectedRoot
        )
        defer { root.close() }
        _ = try validateRootNames(root, journalMayExist: true)
        try validateEmptyKnownDirectory(root, name: "staging")
        try removeRegularIfPresent(root, name: "journal")
        try removeEmptyKnownDirectoryIfPresent(
            root,
            name: "staging",
            expected: nil,
            allowObservedIdentityAuthority: true
        )
        try finishRootRemoval(entry, namespace: namespace, root: root)
    }

    private func recoverActive(
        _ entry: RecoveryIndexEntry,
        armedMutations: [RecoveryJournalMutation]
    ) async throws {
        let root = try openRoot(entry)
        defer { root.close() }
        _ = try validateRootNames(root, journalMayExist: true)
        let staging = try openKnownDirectory(
            root,
            name: "staging",
            expected: entry.stagingIdentity        )
        defer { staging.close() }

        try await recoverArmedMutations(
            armedMutations,
            entry: entry,
            root: root
        )
        try validateInventory(
            staging,
            nodes: manifestNodes(entry.header.stagingCleanupManifest)
        )
    }

    private func cleanupRolledBack(
        _ entry: RecoveryIndexEntry
    ) throws {
        let namespace = try openNamespace(entry)
        defer { namespace.close() }
        guard let expectedRoot = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        guard let observed = try fileSystem.statNoFollow(parent: namespace, name: entry.rootName) else {
            try fileSystem.fsync(namespace)
            return
        }
        guard observed.identity == expectedRoot else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedRoot,
                actual: observed.identity
            )
        }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expectedRoot
        )
        defer { root.close() }
        let rootNames = try validateRootNames(root, journalMayExist: true)
        let stagingNodes = manifestNodes(entry.header.stagingCleanupManifest)
        guard entry.stagingIdentity != nil else {
            throw TransactionJournalError.unsafeRecoveryState(
                "missing persisted staging identity"
            )
        }
        if rootNames.contains("staging") {
            let staging = try openKnownDirectory(
                root,
                name: "staging",
                expected: entry.stagingIdentity            )
            defer { staging.close() }
            try validateInventory(staging, nodes: stagingNodes)
            try cleanupInventory(staging, nodes: stagingNodes)
        } else {
            try fileSystem.fsync(root)
        }
        try removeRegularIfPresent(root, name: "journal")
        try removeEmptyKnownDirectoryIfPresent(
            root,
            name: "staging",
            expected: entry.stagingIdentity,
            allowObservedIdentityAuthority: false
        )
        try observer?.didReach(.afterRolledBackStagingRemoval)
        try finishRootRemoval(entry, namespace: namespace, root: root)
    }

    private func cleanupCommitted(_ entry: RecoveryIndexEntry) async throws {
        let namespace = try openNamespace(entry)
        defer { namespace.close() }
        guard let expectedRoot = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        guard let observed = try fileSystem.statNoFollow(parent: namespace, name: entry.rootName) else {
            try fileSystem.fsync(namespace)
            return
        }
        guard observed.identity == expectedRoot else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedRoot,
                actual: observed.identity
            )
        }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expectedRoot
        )
        defer { root.close() }
        let rootNames = try validateRootNames(root, journalMayExist: true)
        var stagingNodes = manifestNodes(entry.header.stagingCleanupManifest)
        guard entry.stagingIdentity != nil else {
            throw TransactionJournalError.unsafeRecoveryState(
                "missing persisted staging identity"
            )
        }

        if rootNames.contains("journal") {
            let armedMutations = try await journals.recordsForRecovery(
                entry.header.transactionID
            )
            stagingNodes = try committedStagingNodes(
                original: stagingNodes,
                armedMutations: armedMutations
            )
            let staging = try openKnownDirectory(
                root,
                name: "staging",
                expected: entry.stagingIdentity            )
            defer { staging.close() }
            try validateCommittedReplaceManifests(
                armedMutations,
                entry: entry,
                root: root
            )
            try validateInventory(staging, nodes: stagingNodes)
            try cleanupInventory(staging, nodes: stagingNodes)
            try removeRegularIfPresent(root, name: "journal")
        }

        try validatePostAuthorityState(
            root,
            entry: entry,
            stagingNodes: stagingNodes
        )
        try removeEmptyKnownDirectoryIfPresent(
            root,
            name: "staging",
            expected: entry.stagingIdentity,
            allowObservedIdentityAuthority: false
        )
        try finishRootRemoval(entry, namespace: namespace, root: root)
    }

    private func committedStagingNodes(
        original: [InventoryNode],
        armedMutations: [RecoveryJournalMutation]
    ) throws -> [InventoryNode] {
        var nodes = Dictionary(uniqueKeysWithValues: original.map { ($0.path, $0) })
        for mutation in armedMutations {
            guard case let .replaceSwap(_, staged, _, _, capturedManifest, _) = mutation else {
                continue
            }
            let stagedPath = staged.relativeParentPath.isEmpty
                ? staged.name
                : "\(staged.relativeParentPath)/\(staged.name)"
            for path in Array(nodes.keys) where path == stagedPath || path.hasPrefix(stagedPath + "/") {
                nodes.removeValue(forKey: path)
            }
            for entry in capturedManifest.entries {
                let path = entry.relativePath.isEmpty
                    ? stagedPath
                    : "\(stagedPath)/\(entry.relativePath)"
                nodes[path] = InventoryNode(
                    path: path,
                    kind: entry.identity.kind,
                    expectedIdentity: entry.identity
                )
            }
        }
        return nodes.values.sorted { $0.path < $1.path }
    }

    private func validateCommittedReplaceManifests(
        _ armedMutations: [RecoveryJournalMutation],
        entry: RecoveryIndexEntry,
        root: DirectoryHandle
    ) throws {
        let classifier = SwapClaimRecoveryClassifier()
        for mutation in armedMutations {
            guard case let .replaceSwap(
                _,
                staged,
                _,
                _,
                expectedCaptured,
                _
            ) = mutation,
            let expectedRootIdentity = expectedCaptured.entries.first(
                where: { $0.relativePath.isEmpty }
            )?.identity else {
                continue
            }
            let stagedParent = try resolveParent(
                staged,
                entry: entry,
                transactionRoot: root
            )
            defer { stagedParent.close() }
            let stagedNode = try fileSystem.statNoFollow(
                parent: stagedParent,
                name: staged.name
            )
            // A prior cleanup attempt may have durably removed this exact private
            // node before crashing. Absence is therefore already-cleaned state;
            // committed recovery never consults the public destination.
            if stagedNode == nil { continue }
            let actualManifest: CapturedTreeManifest?
            if let stagedNode {
                actualManifest = try CapturedTreeManifest.capture(
                    rootPath: expectedCaptured.rootPath,
                    rootNode: stagedNode,
                    parent: stagedParent,
                    fileSystem: fileSystem,
                    listingPolicy: capturedValidationPolicy(expectedCaptured)
                )
            } else {
                actualManifest = nil
            }
            let manifestMatches = actualManifest.map {
                capturedManifestMatchesAfterSwap(
                    actual: $0,
                    approved: expectedCaptured
                )
            } ?? false
            switch classifier.classifyCommitted(
                stagedIdentity: stagedNode?.identity,
                expectedCapturedIdentity: expectedRootIdentity,
                capturedManifestMatches: manifestMatches
            ) {
            case .cleanupCaptured:
                continue
            case .unresolved:
                if stagedNode?.identity == expectedRootIdentity, !manifestMatches {
                    throw SwapClaimRecoveryError.capturedManifestMismatch
                }
                throw SwapClaimRecoveryError.unsafeCommittedPrivateState(
                    actual: stagedNode?.identity
                )
            }
        }
    }

    private func capturedValidationPolicy(
        _ manifest: CapturedTreeManifest
    ) -> ArchiveResourcePolicy.Listing {
        let pathBytes = manifest.entries.reduce(0) {
            $0 + $1.relativePath.utf8.count
        }
        let maximumPathBytes = manifest.entries.map {
            $0.relativePath.utf8.count
        }.max() ?? 1
        let maximumDepth = manifest.entries.map {
            $0.relativePath.split(separator: "/").count
        }.max() ?? 1
        return ArchiveResourcePolicy.Listing(
            browserEntryCap: max(1, manifest.entries.count),
            listingHardCap: max(1, manifest.entries.count),
            totalPathByteCap: max(1, pathBytes),
            maximumPathByteCount: max(1, maximumPathBytes),
            maximumPathDepth: max(1, maximumDepth)
        )
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

    private func recoverArmedMutations(
        _ mutations: [RecoveryJournalMutation],
        entry: RecoveryIndexEntry,
        root: DirectoryHandle
    ) async throws {
        let classifier = SwapClaimRecoveryClassifier()
        for mutation in mutations.reversed() {
            switch mutation {
            case let .replaceSwap(
                mutationID,
                staged,
                destination,
                replacementIdentity,
                expectedCaptured,
                recoveryCapturedIdentity
            ):
                guard let expectedCapturedIdentity = expectedCaptured.entries.first(
                    where: { $0.relativePath.isEmpty }
                )?.identity else {
                    throw TransactionJournalError.malformedJournal
                }
                let stagedParent = try resolveParent(
                    staged,
                    entry: entry,
                    transactionRoot: root
                )
                defer { stagedParent.close() }
                let destinationParent = try resolveParent(
                    destination,
                    entry: entry,
                    transactionRoot: root
                )
                defer { destinationParent.close() }
                let occupancy = ReplaceSwapOccupancy(
                    staged: try fileSystem.statNoFollow(
                        parent: stagedParent,
                        name: staged.name
                    )?.identity,
                    destination: try fileSystem.statNoFollow(
                        parent: destinationParent,
                        name: destination.name
                    )?.identity
                )

                if let recoveryCaptured = recoveryCapturedIdentity {
                    try await journals.recordReplaceSwapRecoveryCapture(
                        mutationID: mutationID,
                        capturedIdentity: recoveryCaptured,
                        transactionID: entry.header.transactionID
                    )
                    if occupancy.staged == replacementIdentity,
                       occupancy.destination == recoveryCaptured {
                        try synchronizeRecoveredReplaceParents(
                            stagedParent,
                            stagedReference: staged,
                            destinationParent,
                            destinationReference: destination
                        )
                        continue
                    }
                    guard occupancy.staged == recoveryCaptured,
                          occupancy.destination == replacementIdentity else {
                        throw SwapClaimRecoveryError.unsafeActiveOccupancy(
                            staged: occupancy.staged,
                            destination: occupancy.destination
                        )
                    }
                    try reverseArmedReplaceSwap(
                        capturedIdentity: recoveryCaptured,
                        staged: staged,
                        stagedParent: stagedParent,
                        replacementIdentity: replacementIdentity,
                        destination: destination,
                        destinationParent: destinationParent
                    )
                    continue
                }

                switch classifier.classifyActive(
                    occupancy: occupancy,
                    replacementIdentity: replacementIdentity,
                    expectedCapturedIdentity: expectedCapturedIdentity
                ) {
                case .noEffect:
                    try synchronizeArmedParents(
                        stagedParent,
                        stagedReference: staged,
                        destinationParent,
                        destinationReference: destination
                    )
                case let .reverseSwap(capturedIdentity):
                    if capturedIdentity != expectedCapturedIdentity {
                        try await journals.recordReplaceSwapRecoveryCapture(
                            mutationID: mutationID,
                            capturedIdentity: capturedIdentity,
                            transactionID: entry.header.transactionID
                        )
                    }
                    try reverseArmedReplaceSwap(
                        capturedIdentity: capturedIdentity,
                        staged: staged,
                        stagedParent: stagedParent,
                        replacementIdentity: replacementIdentity,
                        destination: destination,
                        destinationParent: destinationParent
                    )
                case .unresolved:
                    throw SwapClaimRecoveryError.unsafeActiveOccupancy(
                        staged: occupancy.staged,
                        destination: occupancy.destination
                    )
                }
            case let .publishMove(_, staged, destination, publishedIdentity):
                try recoverArmedPublishMove(
                    staged: staged,
                    destination: destination,
                    publishedIdentity: publishedIdentity,
                    entry: entry,
                    root: root
                )
            }
        }
    }

    private func reverseArmedReplaceSwap(
        capturedIdentity: FileNodeIdentity,
        staged: JournalNodeReference,
        stagedParent: DirectoryHandle,
        replacementIdentity: FileNodeIdentity,
        destination: JournalNodeReference,
        destinationParent: DirectoryHandle
    ) throws {
        let observation = try fileSystem.swapObserved(
            leftParent: stagedParent,
            leftName: staged.name,
            expectedLeft: capturedIdentity,
            rightParent: destinationParent,
            rightName: destination.name,
            expectedRight: replacementIdentity
        )
        guard observation.leftIdentity == replacementIdentity,
              observation.rightIdentity == capturedIdentity else {
            throw SwapClaimRecoveryError.inverseObservationMismatch(
                staged: observation.leftIdentity,
                destination: observation.rightIdentity
            )
        }
        try observer?.didReach(.afterInverseRename)
        try synchronizeRecoveredReplaceParents(
            stagedParent,
            stagedReference: staged,
            destinationParent,
            destinationReference: destination
        )
    }

    private func synchronizeRecoveredReplaceParents(
        _ stagedParent: DirectoryHandle,
        stagedReference: JournalNodeReference,
        _ destinationParent: DirectoryHandle,
        destinationReference: JournalNodeReference
    ) throws {
        try fileSystem.fsync(stagedParent)
        try observer?.didReach(.afterInverseSourceParentSync)
        if stagedReference.parentIdentity != destinationReference.parentIdentity {
            try fileSystem.fsync(destinationParent)
        }
        try observer?.didReach(.afterInverseDestinationParentSync)
    }

    private func recoverArmedPublishMove(
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity,
        entry: RecoveryIndexEntry,
        root: DirectoryHandle
    ) throws {
        let stagedParent = try resolveParent(
            staged,
            entry: entry,
            transactionRoot: root
        )
        defer { stagedParent.close() }
        let destinationParent = try resolveParent(
            destination,
            entry: entry,
            transactionRoot: root
        )
        defer { destinationParent.close() }
        let stagedState = try fileSystem.statNoFollow(
            parent: stagedParent,
            name: staged.name
        )?.identity
        let destinationState = try fileSystem.statNoFollow(
            parent: destinationParent,
            name: destination.name
        )?.identity

        if stagedState == publishedIdentity, destinationState == nil {
            try makeRecoveredPublishInverseDurable(
                staged: staged,
                stagedParent: stagedParent,
                destination: destination,
                destinationParent: destinationParent,
                publishedIdentity: publishedIdentity
            )
            return
        }
        if stagedState == publishedIdentity,
           let destinationState,
           destinationState != publishedIdentity {
            try synchronizeArmedParents(
                stagedParent,
                stagedReference: staged,
                destinationParent,
                destinationReference: destination
            )
            return
        }
        if stagedState == nil, destinationState == publishedIdentity {
            let observation = try fileSystem.moveExclusiveObserved(
                fromParent: destinationParent,
                fromName: destination.name,
                toParent: stagedParent,
                toName: staged.name,
                expectedSource: publishedIdentity
            )
            if observation.sourceIdentity == nil,
               observation.destinationIdentity == publishedIdentity {
                try observer?.didReach(.afterInverseRename)
                try makeRecoveredPublishInverseDurable(
                    staged: staged,
                    stagedParent: stagedParent,
                    destination: destination,
                    destinationParent: destinationParent,
                    publishedIdentity: publishedIdentity
                )
                return
            }
            if observation.sourceIdentity == nil,
               let foreign = observation.destinationIdentity,
               foreign != publishedIdentity {
                try restoreForeignPublishCapture(
                    foreignIdentity: foreign,
                    staged: staged,
                    stagedParent: stagedParent,
                    destination: destination,
                    destinationParent: destinationParent
                )
            }
            throw TransactionJournalError.unsafeRecoveryState(
                "ambiguous armed publication inverse"
            )
        }
        if let foreign = stagedState,
           foreign != publishedIdentity,
           destinationState == nil {
            try restoreForeignPublishCapture(
                foreignIdentity: foreign,
                staged: staged,
                stagedParent: stagedParent,
                destination: destination,
                destinationParent: destinationParent
            )
        }
        throw TransactionJournalError.unsafeRecoveryState(
            "ambiguous armed publication"
        )
    }

    private func makeRecoveredPublishInverseDurable(
        staged: JournalNodeReference,
        stagedParent: DirectoryHandle,
        destination: JournalNodeReference,
        destinationParent: DirectoryHandle,
        publishedIdentity: FileNodeIdentity
    ) throws {
        try fileSystem.fsync(destinationParent)
        try observer?.didReach(.afterInverseSourceParentSync)
        if staged.parentIdentity != destination.parentIdentity {
            try fileSystem.fsync(stagedParent)
        }
        try observer?.didReach(.afterInverseDestinationParentSync)
        guard try fileSystem.statNoFollow(
            parent: destinationParent,
            name: destination.name
        ) == nil,
        try fileSystem.statNoFollow(
            parent: stagedParent,
            name: staged.name
        )?.identity == publishedIdentity else {
            throw TransactionJournalError.unsafeRecoveryState(
                "publication inverse verification"
            )
        }
        try observer?.didReach(.afterInverseTargetVerification)
    }

    private func restoreForeignPublishCapture(
        foreignIdentity: FileNodeIdentity,
        staged: JournalNodeReference,
        stagedParent: DirectoryHandle,
        destination: JournalNodeReference,
        destinationParent: DirectoryHandle
    ) throws {
        guard try fileSystem.statNoFollow(
            parent: destinationParent,
            name: destination.name
        ) == nil,
        try fileSystem.statNoFollow(
            parent: stagedParent,
            name: staged.name
        )?.identity == foreignIdentity else {
            throw TransactionJournalError.unsafeRecoveryState(
                "foreign publication capture cannot be restored safely"
            )
        }
        let restoration = try fileSystem.moveExclusiveObserved(
            fromParent: stagedParent,
            fromName: staged.name,
            toParent: destinationParent,
            toName: destination.name,
            expectedSource: foreignIdentity
        )
        guard restoration.sourceIdentity == nil,
              restoration.destinationIdentity == foreignIdentity else {
            throw TransactionJournalError.unsafeRecoveryState(
                "foreign publication restoration could not be verified"
            )
        }
        try synchronizeArmedParents(
            stagedParent,
            stagedReference: staged,
            destinationParent,
            destinationReference: destination
        )
        throw TransactionJournalError.unsafeRecoveryState(
            "foreign publication capture restored; recovery evidence retained"
        )
    }

    private func synchronizeArmedParents(
        _ stagedParent: DirectoryHandle,
        stagedReference: JournalNodeReference,
        _ destinationParent: DirectoryHandle,
        destinationReference: JournalNodeReference
    ) throws {
        try fileSystem.fsync(stagedParent)
        if stagedReference.parentIdentity != destinationReference.parentIdentity {
            try fileSystem.fsync(destinationParent)
        }
    }

    private struct InventoryNode: Hashable {
        let path: String
        let kind: ExtractionNodeKind
        let expectedIdentity: FileNodeIdentity?
    }

    private func manifestNodes(
        _ manifest: StagingCleanupManifest
    ) -> [InventoryNode] {
        manifest.entries.map {
            InventoryNode(path: $0.relativePath, kind: $0.kind, expectedIdentity: nil)
        }
    }

    private func validateInventory(
        _ base: DirectoryHandle,
        nodes: [InventoryNode]
    ) throws {
        var allowedChildren: [String: Set<String>] = [:]
        var byPath: [String: InventoryNode] = [:]
        for node in nodes {
            byPath[node.path] = node
            guard !node.path.isEmpty else { continue }
            let components = node.path.split(separator: "/").map(String.init)
            let parent = components.dropLast().joined(separator: "/")
            allowedChildren[parent, default: []].insert(components.last!)
        }

        if let baseAuthority = byPath[""] {
            let actual = try fileSystem.identity(of: base)
            guard baseAuthority.kind == .directory else {
                throw TransactionJournalError.unsafeRecoveryState("inventory base kind")
            }
            if let expected = baseAuthority.expectedIdentity, expected != actual {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: actual
                )
            }
        }

        func validateDirectory(_ path: String, handle: DirectoryHandle) throws {
            let allowed = allowedChildren[path, default: []]
            let observed = try fileSystem.listNoFollow(handle)
            guard Set(observed.map(\.name)).isSubset(of: allowed) else {
                throw TransactionJournalError.unsafeRecoveryState("unexpected owned entry")
            }
            for child in observed {
                let childPath = path.isEmpty ? child.name : "\(path)/\(child.name)"
                guard let authority = byPath[childPath],
                      child.identity.kind == authority.kind
                else { throw TransactionJournalError.unsafeRecoveryState("inventory kind") }
                if let expected = authority.expectedIdentity, expected != child.identity {
                    throw FileSystemOperationError.identityMismatch(
                        expected: expected,
                        actual: child.identity
                    )
                }
                if child.identity.kind == .directory {
                    // Recovery inspects a staged tree left behind by a process
                    // that died mid-extraction, so its directories still carry
                    // the archive's mode. Adopt (repair to 0700) instead of
                    // requiring it, otherwise a crashed transaction could never
                    // be reconciled and recovery would fail on every launch.
                    let childHandle = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                        parent: handle,
                        name: child.name,
                        expected: child.identity
                    )
                    defer { childHandle.close() }
                    try validateDirectory(childPath, handle: childHandle)
                }
            }
        }

        try validateDirectory("", handle: base)
    }

    private func cleanupInventory(
        _ base: DirectoryHandle,
        nodes: [InventoryNode]
    ) throws {
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        let ordered = nodes.filter { !$0.path.isEmpty }.sorted {
            let leftDepth = $0.path.split(separator: "/").count
            let rightDepth = $1.path.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0.path > $1.path
        }
        for node in ordered {
            let components = node.path.split(separator: "/").map(String.init)
            let parentComponents = Array(components.dropLast())
            guard let parent = try openOwnedPathIfPresent(
                base,
                components: parentComponents,
                authorities: byPath
            ) else {
                try fileSystem.fsync(base)
                continue
            }
            defer { parent.close() }
            let name = components.last!
            guard let observed = try fileSystem.statNoFollow(parent: parent, name: name) else {
                try fileSystem.fsync(parent)
                continue
            }
            guard observed.identity.kind == node.kind else {
                throw TransactionJournalError.unsafeRecoveryState("cleanup kind")
            }
            if let expected = node.expectedIdentity, expected != observed.identity {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: observed.identity
                )
            }
            if node.kind == .directory {
                // Same reason as `validateInventory`: staged directories being
                // cleaned up after a crash carry the archive's mode.
                let directory = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                    parent: parent,
                    name: name,
                    expected: observed.identity
                )
                let isEmpty = try fileSystem.listNoFollow(directory).isEmpty
                directory.close()
                guard isEmpty else {
                    throw TransactionJournalError.unsafeRecoveryState("cleanup directory not empty")
                }
            }
            try fileSystem.removeOwnedNoFollow(
                parent: parent,
                name: name,
                expected: observed.identity
            )
        }
        guard try fileSystem.listNoFollow(base).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState("owned inventory remains")
        }
    }

    private func validatePostAuthorityState(
        _ root: DirectoryHandle,
        entry: RecoveryIndexEntry,
        stagingNodes: [InventoryNode]
    ) throws {
        let names = try validateRootNames(root, journalMayExist: false)
        guard !names.contains("journal") else {
            throw TransactionJournalError.unsafeRecoveryState("journal unexpectedly present")
        }
        if names.contains("staging") {
            let staging = try openKnownDirectory(
                root,
                name: "staging",
                expected: entry.stagingIdentity
            )
            defer { staging.close() }
            try validateInventory(staging, nodes: stagingNodes)
            guard try fileSystem.listNoFollow(staging).isEmpty else {
                throw TransactionJournalError.unsafeRecoveryState("post-authority staging not empty")
            }
        } else {
            try fileSystem.fsync(root)
        }
    }

    private func validateRootNames(
        _ root: DirectoryHandle,
        journalMayExist: Bool
    ) throws -> Set<String> {
        let names = Set(try fileSystem.listNoFollow(root).map(\.name))
        var allowed = Set(["staging"])
        if journalMayExist { allowed.insert("journal") }
        guard names.isSubset(of: allowed) else {
            throw TransactionJournalError.unsafeRecoveryState("unexpected transaction root entry")
        }
        return names
    }

    private func validateEmptyKnownDirectory(
        _ root: DirectoryHandle,
        name: String
    ) throws {
        guard let node = try fileSystem.statNoFollow(parent: root, name: name) else {
            try fileSystem.fsync(root)
            return
        }
        guard node.identity.kind == .directory else {
            throw TransactionJournalError.unsafeRecoveryState("\(name) kind")
        }
        let directory = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: name,
            expected: node.identity
        )
        defer { directory.close() }
        guard try fileSystem.listNoFollow(directory).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState("\(name) not empty")
        }
    }

    private func removeRegularIfPresent(
        _ root: DirectoryHandle,
        name: String
    ) throws {
        guard let node = try fileSystem.statNoFollow(parent: root, name: name) else {
            try fileSystem.fsync(root)
            return
        }
        guard node.identity.kind == .regularFile else {
            throw TransactionJournalError.unsafeRecoveryState("\(name) kind")
        }
        let verified = try fileSystem.openRegularFileNoFollow(
            parent: root,
            name: name,
            expected: node.identity,
            access: .readOnly
        )
        verified.close()
        try fileSystem.removeOwnedNoFollow(
            parent: root,
            name: name,
            expected: node.identity
        )
    }

    private func removeEmptyKnownDirectoryIfPresent(
        _ root: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?,
        allowObservedIdentityAuthority: Bool
    ) throws {
        guard let node = try fileSystem.statNoFollow(parent: root, name: name) else {
            try fileSystem.fsync(root)
            return
        }
        guard node.identity.kind == .directory else {
            throw TransactionJournalError.unsafeRecoveryState("\(name) kind")
        }
        let authority: FileNodeIdentity
        if let expected {
            guard node.identity == expected else {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: node.identity
                )
            }
            authority = expected
        } else {
            guard allowObservedIdentityAuthority else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "missing persisted \(name) identity"
                )
            }
            authority = node.identity
        }
        let directory = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: name,
            expected: authority
        )
        let empty = try fileSystem.listNoFollow(directory).isEmpty
        directory.close()
        guard empty else {
            throw TransactionJournalError.unsafeRecoveryState("\(name) not empty")
        }
        try fileSystem.removeOwnedNoFollow(
            parent: root,
            name: name,
            expected: authority
        )
    }

    private func finishRootRemoval(
        _ entry: RecoveryIndexEntry,
        namespace: DirectoryHandle,
        root: DirectoryHandle
    ) throws {
        guard let expected = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        guard try fileSystem.listNoFollow(root).isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState("transaction root not empty")
        }
        try fileSystem.fsync(root)
        let actual = try fileSystem.identity(of: root)
        guard actual == expected else {
            throw FileSystemOperationError.identityMismatch(expected: expected, actual: actual)
        }
        root.close()
        try fileSystem.removeOwnedNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expected
        )
    }

    private func openNamespace(
        _ entry: RecoveryIndexEntry
    ) throws -> DirectoryHandle {
        try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: entry.namespace.url,
            expected: entry.namespace.identity
        )
    }

    private func openRoot(
        _ entry: RecoveryIndexEntry
    ) throws -> DirectoryHandle {
        guard let expected = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        let namespace = try openNamespace(entry)
        defer { namespace.close() }
        return try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expected
        )
    }

    private func openKnownDirectory(
        _ root: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        guard let expected else {
            throw TransactionJournalError.unsafeRecoveryState(
                "missing persisted \(name) identity"
            )
        }
        guard let node = try fileSystem.statNoFollow(parent: root, name: name),
              node.identity.kind == .directory
        else { throw TransactionJournalError.unsafeRecoveryState("missing \(name)") }
        guard node.identity == expected else {
            throw FileSystemOperationError.identityMismatch(
                expected: expected,
                actual: node.identity
            )
        }
        return try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: name,
            expected: expected
        )
    }

    private func openOwnedPathIfPresent(
        _ base: DirectoryHandle,
        components: [String],
        authorities: [String: InventoryNode]
    ) throws -> DirectoryHandle? {
        let baseIdentity = try fileSystem.identity(of: base)
        if let expected = authorities[""]?.expectedIdentity,
           expected != baseIdentity {
            throw FileSystemOperationError.identityMismatch(
                expected: expected,
                actual: baseIdentity
            )
        }
        if components.isEmpty {
            return try fileSystem.openRelativeDirectoryNoFollow(
                root: base,
                components: [],
                expected: baseIdentity
            )
        }
        var current = try fileSystem.openRelativeDirectoryNoFollow(
            root: base,
            components: [],
            expected: baseIdentity
        )
        var traversed: [String] = []
        for component in components {
            traversed.append(component)
            guard let node = try fileSystem.statNoFollow(parent: current, name: component) else {
                current.close()
                return nil
            }
            guard node.identity.kind == .directory else {
                current.close()
                throw TransactionJournalError.unsafeRecoveryState("owned parent kind")
            }
            let path = traversed.joined(separator: "/")
            if let expected = authorities[path]?.expectedIdentity,
               expected != node.identity {
                current.close()
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: node.identity
                )
            }
            // Walking down to an owned staged path: intermediate directories are
            // extractor-created, so adopt them as we descend.
            let next = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
                parent: current,
                name: component,
                expected: node.identity
            )
            current.close()
            current = next
        }
        return current
    }

    private func resolveParent(
        _ reference: JournalNodeReference,
        entry: RecoveryIndexEntry,
        transactionRoot: DirectoryHandle
    ) throws -> DirectoryHandle {
        let base: DirectoryHandle
        switch reference.root {
        case .destination:
            base = try fileSystem.openDirectoryNoFollow(at: entry.header.destinationURL)
            let actual = try fileSystem.identity(of: base)
            guard actual == entry.header.destinationIdentity else {
                base.close()
                throw FileSystemOperationError.identityMismatch(
                    expected: entry.header.destinationIdentity,
                    actual: actual
                )
            }
        case .staging:
            base = try openKnownDirectory(
                transactionRoot,
                name: "staging",
                expected: entry.stagingIdentity
            )
        }
        if reference.relativeParentPath.isEmpty {
            let actual = try fileSystem.identity(of: base)
            guard actual == reference.parentIdentity else {
                base.close()
                throw FileSystemOperationError.identityMismatch(
                    expected: reference.parentIdentity,
                    actual: actual
                )
            }
            return base
        }
        let components = reference.relativeParentPath.split(separator: "/").map(String.init)
        let result = try fileSystem.openRelativeDirectoryNoFollow(
            root: base,
            components: components,
            expected: reference.parentIdentity
        )
        base.close()
        return result
    }
}
