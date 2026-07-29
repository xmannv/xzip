import Foundation
import XZIPCore
import XZIPDomain

public enum TransactionJournalError: Error, Equatable, Sendable {
    case unavailableDestinationVolume(UInt64)
    case invalidManifest(String)
    case capacityExceeded(limit: Int, observed: Int)
    case duplicateTransaction
    case invalidTransition
    case malformedIndex
    case incompatibleSchema(found: Int, expected: Int)
    case malformedJournal
    case missingTransaction
    case unsafeRecoveryState(String)
    case committedOutcomeUnavailable(operationID: OperationID)
    case committedOutcomeMismatch
    case commitStateUncertain(recoveryURL: URL)
}

/// These reach the user through the app's `error.localizedDescription`, so
/// without this they render as "(XZIPRuntime.TransactionJournalError error 0.)".
/// `unavailableDestinationVolume` is the one users actually hit: it is what an
/// extraction to a USB stick or other external volume fails with today.
extension TransactionJournalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailableDestinationVolume:
            return "Extracting to a different disk than the startup disk is not "
                + "supported yet. Extract to a folder on this Mac, then copy it "
                + "across."
        case let .invalidManifest(reason):
            return "The extraction record is not valid: \(reason)"
        case let .capacityExceeded(limit, observed):
            return "Too many extractions are in flight (\(observed), limit \(limit)). "
                + "Wait for one to finish and try again."
        case .duplicateTransaction:
            return "That extraction is already running."
        case .invalidTransition:
            return "The extraction was already past that stage."
        case .malformedIndex:
            return "The extraction records are damaged."
        case let .incompatibleSchema(found, expected):
            return "The extraction record schema \(found) is not supported; expected \(expected)."
        case .malformedJournal:
            return "The extraction log is damaged."
        case .missingTransaction:
            return "That extraction is no longer on record."
        case let .unsafeRecoveryState(detail):
            return "Leftover files from an interrupted extraction could not be "
                + "cleaned up safely: \(detail)"
        case .committedOutcomeUnavailable:
            return "The extraction finished but its result could not be read back."
        case .committedOutcomeMismatch:
            return "The extraction finished with a result that does not match its record."
        case let .commitStateUncertain(recoveryURL):
            return "It is unclear whether the extraction finished. Check "
                + "\(recoveryURL.path) before retrying."
        }
    }
}

public struct TransactionRootReservation: Hashable, Sendable {
    public let transactionID: TransactionID
    let namespace: TransactionNamespaceLocator
    let rootName: String
    fileprivate let leaseID: UUID

    init(
        transactionID: TransactionID,
        namespace: TransactionNamespaceLocator,
        rootName: String,
        leaseID: UUID
    ) {
        self.transactionID = transactionID
        self.namespace = namespace
        self.rootName = rootName
        self.leaseID = leaseID
    }
}

public struct TransactionRootLocator: Hashable, Codable, Sendable {
    public let namespace: TransactionNamespaceLocator
    public let rootName: String
    public let rootIdentity: FileNodeIdentity

    public init(
        namespace: TransactionNamespaceLocator,
        rootName: String,
        rootIdentity: FileNodeIdentity
    ) {
        self.namespace = namespace
        self.rootName = rootName
        self.rootIdentity = rootIdentity
    }
}

public enum TransactionRootKind: String, Codable, Sendable {
    case destination
    case staging
}

public struct JournalNodeReference: Hashable, Codable, Sendable {
    public let root: TransactionRootKind
    public let relativeParentPath: String
    public let parentIdentity: FileNodeIdentity
    public let name: String

    public init(
        root: TransactionRootKind,
        relativeParentPath: String,
        parentIdentity: FileNodeIdentity,
        name: String
    ) {
        self.root = root
        self.relativeParentPath = relativeParentPath
        self.parentIdentity = parentIdentity
        self.name = name
    }
}

public struct JournalMutationID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

enum JournalMutationEvent: Equatable, Sendable {
    case preparationFrameWritten
    case armedFrameWritten
    case recoveryProgressFrameWritten
    case journalFileSynced
    case transactionRootSynced
}

protocol JournalMutationObserving: Sendable {
    func didReach(_ event: JournalMutationEvent) throws
}

protocol JournalManifestPreparationObserving: Sendable {
    func didPrepareManifestEntry()
}

public struct StagingCleanupManifestEntry: Hashable, Codable, Sendable {
    public let relativePath: String
    public let kind: ExtractionNodeKind

    public init(relativePath: String, kind: ExtractionNodeKind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

public struct StagingCleanupManifest: Hashable, Codable, Sendable {
    public let entries: [StagingCleanupManifestEntry]

    public init(entries: [StagingCleanupManifestEntry]) {
        self.entries = entries
    }
}

public struct ExtractionJournalHeader: Hashable, Codable, Sendable {
    private static let headerSchemaVersion = 2

    let schemaVersion: Int
    public let transactionID: TransactionID
    public let operationID: OperationID
    public let archiveID: ArchiveID
    public let destinationURL: URL
    public let destinationIdentity: FileNodeIdentity
    public let stagingCleanupManifest: StagingCleanupManifest
    public let createdAt: Date

    public init(
        transactionID: TransactionID,
        operationID: OperationID,
        archiveID: ArchiveID,
        destinationURL: URL,
        destinationIdentity: FileNodeIdentity,
        stagingCleanupManifest: StagingCleanupManifest,
        createdAt: Date
    ) {
        schemaVersion = Self.headerSchemaVersion
        self.transactionID = transactionID
        self.operationID = operationID
        self.archiveID = archiveID
        self.destinationURL = destinationURL
        self.destinationIdentity = destinationIdentity
        self.stagingCleanupManifest = stagingCleanupManifest
        self.createdAt = createdAt
    }
}


public final class ActivatedExtractionTransaction: @unchecked Sendable {
    public let transactionID: TransactionID
    let stagingURL: URL
    let stagingIdentity: FileNodeIdentity
    let stagingHandle: DirectoryHandle

    init(
        transactionID: TransactionID,
        stagingURL: URL,
        stagingIdentity: FileNodeIdentity,
        stagingHandle: DirectoryHandle
    ) {
        self.transactionID = transactionID
        self.stagingURL = stagingURL
        self.stagingIdentity = stagingIdentity
        self.stagingHandle = stagingHandle
    }

    deinit {
        close()
    }

    public func close() {
        stagingHandle.close()
    }
}

public enum ExtractionJournalRecord: Hashable, Codable, Sendable {
    case replaceManifestChunk(
        mutationID: JournalMutationID,
        sequence: Int,
        entries: [CapturedTreeManifestEntry]
    )
    case replaceSwapArmed(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCapturedRootIdentity: FileNodeIdentity,
        manifestEntryCount: Int,
        manifestDigest: Data
    )
    case replaceSwapRecoveryCapture(
        mutationID: JournalMutationID,
        capturedIdentity: FileNodeIdentity
    )
    case publishMoveArmed(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity
    )
}

public enum RecoveryJournalMutation: Hashable, Sendable {
    case replaceSwap(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCaptured: CapturedTreeManifest,
        recoveryCapturedIdentity: FileNodeIdentity?
    )
    case publishMove(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity
    )
}

public enum DurableOperationEffectResolution: String, Hashable, Codable, Sendable {
    case absent
    case unfinished
    case rolledBack
    case committed
}

enum TransactionRecoveryPhase: String, Codable, Sendable {
    case reserved
    case rootCreated
    case active
    case rolledBack
    case committed
}

struct PersistedExtractionJournal: Hashable, Codable, Sendable {
    let header: ExtractionJournalHeader
    let namespace: TransactionNamespaceLocator
    let rootName: String
    let rootIdentity: FileNodeIdentity?
    let records: [ExtractionJournalRecord]
    let resolution: DurableOperationEffectResolution
    let phase: TransactionRecoveryPhase
}

public protocol DurableOperationEffectResolving: Sendable {
    func resolution(
        for operationID: OperationID
    ) async throws -> DurableOperationEffectResolution
}


public enum DurableExtractionResolution: Equatable, Sendable {
    case absent
    case unfinished
    case rolledBack
    case committed(ExtractionResult)
}

public protocol DurableExtractionResolving: Sendable {
    func resolveExtraction(
        for operationID: OperationID
    ) async throws -> DurableExtractionResolution
}

public protocol ExtractionJournalStore: Sendable {
    func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation

    func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity

    func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction

    func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws


    func armReplaceSwap(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCaptured: CapturedTreeManifest,
        transactionID: TransactionID
    ) async throws

    func armPublishMove(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity,
        transactionID: TransactionID
    ) async throws

    func recordsForRecovery(
        _ transactionID: TransactionID
    ) async throws -> [RecoveryJournalMutation]

    func markRolledBack(_ transactionID: TransactionID) async throws
    func releaseRolledBack(_ transactionID: TransactionID) async throws

    func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws
}

public extension ExtractionJournalStore {
    func armReplaceSwap(
        mutationID _: JournalMutationID,
        staged _: JournalNodeReference,
        destination _: JournalNodeReference,
        replacementIdentity _: FileNodeIdentity,
        expectedCaptured _: CapturedTreeManifest,
        transactionID _: TransactionID
    ) async throws {
        throw TransactionJournalError.invalidTransition
    }

    func armPublishMove(
        mutationID _: JournalMutationID,
        staged _: JournalNodeReference,
        destination _: JournalNodeReference,
        publishedIdentity _: FileNodeIdentity,
        transactionID _: TransactionID
    ) async throws {
        throw TransactionJournalError.invalidTransition
    }

    func recordsForRecovery(
        _ transactionID: TransactionID
    ) async throws -> [RecoveryJournalMutation] {
        throw TransactionJournalError.invalidTransition
    }
}

fileprivate struct CommittedPublishedPathDocument:
    Hashable,
    Codable,
    Sendable
{
    let relativePath: String
    let isDirectory: Bool
}

fileprivate struct CommittedExtractionOutcomeDocument:
    Hashable,
    Codable,
    Sendable
{
    let transactionID: TransactionID
    let published: [CommittedPublishedPathDocument]
    let skippedPaths: [String]
}

struct RecoveryIndexEntry: Hashable, Codable, Sendable {
    let header: ExtractionJournalHeader
    let namespace: TransactionNamespaceLocator
    let rootName: String
    var rootIdentity: FileNodeIdentity?
    var stagingIdentity: FileNodeIdentity?
    var phase: TransactionRecoveryPhase
    fileprivate var committedOutcome: CommittedExtractionOutcomeDocument?
}

private struct RecoveryIndexDocument: Codable {
    let schemaVersion: Int
    let entries: [RecoveryIndexEntry]
}

private struct TransactionPreparationLease: Sendable {
    let id: UUID
    var rootIdentity: FileNodeIdentity?
}

private enum JournalAppendDurability {
    case deferred
    case mutationBarrier
}

private struct EncodedJournalRecord {
    let payloadByteCount: Int
    let frame: Data
}

private struct ReplaceManifestPreparation {
    var nextSequence: Int
    var entries: [CapturedTreeManifestEntry]
}

public actor TransactionJournalStore:
    ExtractionJournalStore,
    DurableOperationEffectResolving,
    DurableExtractionResolving
{
    private static let headerSchemaVersion = 2
    private static let currentIndexSchemaVersion = 3
    private static let migratableEmptyIndexSchemaVersion = 2
    private static let readableIndexSchemaVersions: Set<Int> = [3]
    private static let journalName = "journal"
    private static let stagingName = "staging"
    private static let maximumManifestChunkFrameBytes = 64 * 1024

    private let indexDirectory: DirectoryHandle
    private let indexFileName: String
    private let replacementName: String
    private let policy: ArchiveResourcePolicy
    private let fileSystem: any FileSystemOperations
    private let mutationObserver: (any JournalMutationObserving)?
    private let manifestPreparationObserver: (any JournalManifestPreparationObserving)?
    private var entries: [TransactionID: RecoveryIndexEntry]?
    private var preparationLeases: [TransactionID: TransactionPreparationLease] = [:]
    private var preparationAbortClaims: Set<TransactionID> = []

    public init(
        indexDirectory: DirectoryHandle,
        indexFileName: String,
        policy: ArchiveResourcePolicy,
        fileSystem: any FileSystemOperations
    ) {
        self.indexDirectory = indexDirectory
        self.indexFileName = indexFileName
        self.replacementName = ".\(indexFileName).replacement.tmp"
        self.policy = policy
        self.fileSystem = fileSystem
        self.mutationObserver = nil
        self.manifestPreparationObserver = nil
    }

    init(
        indexDirectory: DirectoryHandle,
        indexFileName: String,
        policy: ArchiveResourcePolicy,
        fileSystem: any FileSystemOperations,
        mutationObserver: (any JournalMutationObserving)?,
        manifestPreparationObserver: (any JournalManifestPreparationObserving)? = nil
    ) {
        self.indexDirectory = indexDirectory
        self.indexFileName = indexFileName
        self.replacementName = ".\(indexFileName).replacement.tmp"
        self.policy = policy
        self.fileSystem = fileSystem
        self.mutationObserver = mutationObserver
        self.manifestPreparationObserver = manifestPreparationObserver
    }

    public func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation {
        try loadIfNeeded()
        try validateHeader(transaction)
        guard namespace.identity.device == transaction.destinationIdentity.device else {
            throw TransactionJournalError.unavailableDestinationVolume(
                transaction.destinationIdentity.device
            )
        }
        let verifiedNamespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespace.url,
            expected: namespace.identity
        )
        verifiedNamespace.close()

        let rootName = "transaction-\(transaction.transactionID.rawValue.uuidString.lowercased())"
        if let existing = entries?[transaction.transactionID] {
            guard existing.header == transaction,
                  existing.namespace == namespace,
                  existing.rootName == rootName
            else { throw TransactionJournalError.duplicateTransaction }
            guard !preparationAbortClaims.contains(transaction.transactionID),
                  existing.phase == .reserved
                    || existing.phase == .rootCreated
                    || existing.phase == .active
            else { throw TransactionJournalError.invalidTransition }
            let lease: TransactionPreparationLease
            if let current = preparationLeases[transaction.transactionID] {
                lease = current
            } else {
                lease = TransactionPreparationLease(
                    id: UUID(),
                    rootIdentity: existing.rootIdentity
                )
                preparationLeases[transaction.transactionID] = lease
            }
            return TransactionRootReservation(
                transactionID: transaction.transactionID,
                namespace: namespace,
                rootName: rootName,
                leaseID: lease.id
            )
        }
        guard !(entries?.values.contains { $0.header.operationID == transaction.operationID } ?? false) else {
            throw TransactionJournalError.duplicateTransaction
        }

        let entry = RecoveryIndexEntry(
            header: transaction,
            namespace: namespace,
            rootName: rootName,
            rootIdentity: nil,
            stagingIdentity: nil,
            phase: .reserved,
            committedOutcome: nil
        )
        var candidate = entries ?? [:]
        candidate[transaction.transactionID] = entry
        try validateIndexCapacity(candidate)
        try persist(candidate)
        entries = candidate
        let lease = TransactionPreparationLease(id: UUID(), rootIdentity: nil)
        preparationLeases[transaction.transactionID] = lease
        return TransactionRootReservation(
            transactionID: transaction.transactionID,
            namespace: namespace,
            rootName: rootName,
            leaseID: lease.id
        )
    }


    public func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity {
        try loadIfNeeded()
        guard !preparationAbortClaims.contains(reservation.transactionID),
              var lease = preparationLeases[reservation.transactionID],
              lease.id == reservation.leaseID,
              var entry = entries?[reservation.transactionID],
              entry.namespace == reservation.namespace,
              entry.rootName == reservation.rootName,
              entry.phase == .reserved || entry.phase == .rootCreated
        else { throw TransactionJournalError.invalidTransition }

        let namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: entry.namespace.url,
            expected: entry.namespace.identity
        )
        defer { namespace.close() }

        let root: DirectoryHandle
        let rootIdentity: FileNodeIdentity
        if let expected = lease.rootIdentity ?? entry.rootIdentity {
            root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                parent: namespace,
                name: entry.rootName,
                expected: expected
            )
            rootIdentity = try fileSystem.identity(of: root)
            guard rootIdentity == expected else {
                root.close()
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: rootIdentity
                )
            }
        } else {
            guard try fileSystem.statNoFollow(
                parent: namespace,
                name: entry.rootName
            ) == nil else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "reserved root already exists without lease authority"
                )
            }
            root = try fileSystem.createTransactionDirectoryExclusive(
                parent: namespace,
                name: entry.rootName
            )
            rootIdentity = try fileSystem.identity(of: root)
            guard rootIdentity.kind == .directory else {
                root.close()
                throw FileSystemOperationError.notDirectory(entry.rootName)
            }
            lease.rootIdentity = rootIdentity
            preparationLeases[reservation.transactionID] = lease
        }
        defer { root.close() }

        try fileSystem.fsync(root)
        try fileSystem.fsync(namespace)
        if entry.phase == .reserved {
            entry.rootIdentity = rootIdentity
            entry.phase = .rootCreated
            try replaceEntry(entry)
        } else {
            guard entry.rootIdentity == rootIdentity else {
                throw TransactionJournalError.invalidTransition
            }
        }
        return rootIdentity
    }

    public func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction {
        try loadIfNeeded()
        guard !preparationAbortClaims.contains(reservation.transactionID),
              let lease = preparationLeases[reservation.transactionID],
              lease.id == reservation.leaseID,
              var entry = entries?[reservation.transactionID],
              entry.namespace == reservation.namespace,
              entry.rootName == reservation.rootName,
              entry.phase == .rootCreated || entry.phase == .active,
              let rootIdentity = entry.rootIdentity,
              lease.rootIdentity == rootIdentity
        else { throw TransactionJournalError.invalidTransition }

        let namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: entry.namespace.url,
            expected: entry.namespace.identity
        )
        defer { namespace.close() }
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: rootIdentity
        )
        defer { root.close() }

        try fileSystem.fsync(root)
        try fileSystem.fsync(namespace)
        try provisionInfrastructure(root)
        let allowed = Set([Self.journalName, Self.stagingName])
        let observed = Set(try fileSystem.listNoFollow(root).map(\.name))
        guard observed == allowed else {
            throw TransactionJournalError.unsafeRecoveryState("unexpected transaction root entry")
        }
        try fileSystem.fsync(root)

        let activated = try makeActivatedTransaction(entry: entry, root: root)
        if entry.phase == .active {
            preparationLeases.removeValue(forKey: reservation.transactionID)
            return activated
        }

        let original = entries ?? [:]
        entry.stagingIdentity = activated.stagingIdentity
        entry.phase = .active
        var candidate = original
        candidate[entry.header.transactionID] = entry
        do {
            try persist(candidate)
            entries = candidate
        } catch let activationError {
            activated.close()
            do {
                try restoreOriginalIndexAfterFailedPersistence(
                    original: original,
                    candidate: candidate
                )
            } catch {
                entries = nil
                throw error
            }
            throw activationError
        }
        preparationLeases.removeValue(forKey: reservation.transactionID)
        return activated
    }


    public func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws {
        guard let lease = preparationLeases[reservation.transactionID],
              lease.id == reservation.leaseID
        else { throw TransactionJournalError.invalidTransition }
        preparationLeases.removeValue(forKey: reservation.transactionID)
    }



    public func armReplaceSwap(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCaptured: CapturedTreeManifest,
        transactionID: TransactionID
    ) async throws {
        try loadIfNeeded()
        guard let entry = entries?[transactionID], entry.phase == .active else {
            throw TransactionJournalError.invalidTransition
        }
        let rootEntry = try expectedCapturedRootEntry(expectedCaptured)
        guard exactPath(expectedCaptured.rootPath, matches: manifestRootPath(destination)) else {
            throw TransactionJournalError.malformedJournal
        }
        let armed = ExtractionJournalRecord.replaceSwapArmed(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            replacementIdentity: replacementIdentity,
            expectedCapturedRootIdentity: rootEntry.identity,
            manifestEntryCount: expectedCaptured.entries.count,
            manifestDigest: expectedCaptured.digest
        )
        try validateRecord(armed)

        let encodedArmed = try encodedRecord(armed)
        let (preparationByteBudget, budgetUnderflow) = cap.subtractingReportingOverflow(
            encodedArmed.frame.count
        )
        guard !budgetUnderflow else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: encodedArmed.frame.count
            )
        }
        var encoded = try encodedManifestChunks(
            mutationID: mutationID,
            entries: expectedCaptured.entries,
            preparationByteBudget: preparationByteBudget,
            armedFrameByteCount: encodedArmed.frame.count
        )
        encoded.append(encodedArmed)
        try appendArmedMutation(
            encoded,
            mutationID: mutationID,
            entry: entry
        )
    }

    public func armPublishMove(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity,
        transactionID: TransactionID
    ) async throws {
        try loadIfNeeded()
        guard let entry = entries?[transactionID], entry.phase == .active else {
            throw TransactionJournalError.invalidTransition
        }
        let armed = ExtractionJournalRecord.publishMoveArmed(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            publishedIdentity: publishedIdentity
        )
        try validateRecord(armed)
        try appendArmedMutation(
            [try encodedRecord(armed)],
            mutationID: mutationID,
            entry: entry
        )
    }

    func recordReplaceSwapRecoveryCapture(
        mutationID: JournalMutationID,
        capturedIdentity: FileNodeIdentity,
        transactionID: TransactionID
    ) throws {
        try loadIfNeeded()
        guard let entry = entries?[transactionID], entry.phase == .active else {
            throw TransactionJournalError.invalidTransition
        }
        let journalRead = try readJournalWithValidLength(
            entry,
            allowTruncatedTail: true
        )
        let mutations = try reconstructRecoveryMutations(journalRead.records)
        if let recorded = mutations.compactMap({ mutation -> FileNodeIdentity? in
            guard case let .replaceSwap(id, _, _, _, _, identity) = mutation,
                  id == mutationID else {
                return nil
            }
            return identity
        }).first {
            guard recorded == capturedIdentity else {
                throw TransactionJournalError.malformedJournal
            }
            let root = try openRoot(entry)
            defer { root.close() }
            let journalIdentity = try requireNode(
                root,
                name: Self.journalName,
                kind: .regularFile
            )
            let journal = try fileSystem.openRegularFileNoFollow(
                parent: root,
                name: Self.journalName,
                expected: journalIdentity,
                access: .readWrite
            )
            defer { journal.close() }
            try journal.fsync()
            try mutationObserver?.didReach(.journalFileSynced)
            try fileSystem.fsync(root)
            try mutationObserver?.didReach(.transactionRootSynced)
            return
        }
        guard mutations.contains(where: { mutation in
            guard case let .replaceSwap(id, staged, destination, _, _, _) = mutation else {
                return false
            }
            return id == mutationID
                && capturedIdentity.device == staged.parentIdentity.device
                && capturedIdentity.device == destination.parentIdentity.device
        }) else {
            throw TransactionJournalError.malformedJournal
        }
        let record = ExtractionJournalRecord.replaceSwapRecoveryCapture(
            mutationID: mutationID,
            capturedIdentity: capturedIdentity
        )
        try validateRecord(record)
        let encoded = try encodedRecord(record)
        let root = try openRoot(entry)
        defer { root.close() }
        let journalIdentity = try requireNode(
            root,
            name: Self.journalName,
            kind: .regularFile
        )
        let journal = try fileSystem.openRegularFileNoFollow(
            parent: root,
            name: Self.journalName,
            expected: journalIdentity,
            access: .readWrite
        )
        defer { journal.close() }
        let current = try journal.seekToEnd()
        guard current == UInt64(journalRead.totalLength) else {
            throw TransactionJournalError.malformedJournal
        }
        let tailLength = journalRead.totalLength - journalRead.validLength
        guard tailLength <= encoded.frame.count else {
            throw TransactionJournalError.malformedJournal
        }
        let (projected, overflow) = journalRead.validLength.addingReportingOverflow(
            encoded.frame.count
        )
        guard !overflow,
              encoded.payloadByteCount <= cap,
              encoded.frame.count <= cap,
              projected <= cap else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: overflow ? Int.max : projected
            )
        }
        try journal.seek(toOffset: UInt64(journalRead.validLength))
        try append(
            encoded.frame,
            journal: journal,
            transactionRoot: root,
            durability: .mutationBarrier,
            event: .recoveryProgressFrameWritten
        )
    }

    public func recordsForRecovery(
        _ transactionID: TransactionID
    ) async throws -> [RecoveryJournalMutation] {
        try loadIfNeeded()
        guard let entry = entries?[transactionID] else {
            throw TransactionJournalError.missingTransaction
        }
        let records = try readJournal(
            entry,
            allowTruncatedTail: entry.phase == .active
        )
        return try reconstructRecoveryMutations(records)
    }

    func liveTransactions() async throws -> [PersistedExtractionJournal] {
        try loadIfNeeded()
        return try (entries ?? [:]).values
            .sorted { $0.header.createdAt < $1.header.createdAt }
            .map { entry in
                let records: [ExtractionJournalRecord]
                if entry.phase == .active {
                    records = try readJournal(entry, allowTruncatedTail: true)
                } else {
                    records = []
                }
                return persisted(entry, records: records)
            }
    }

    public func resolution(
        for operationID: OperationID
    ) async throws -> DurableOperationEffectResolution {
        try loadIfNeeded()
        guard let entry = entries?.values.first(where: { $0.header.operationID == operationID }) else {
            return .absent
        }
        return resolution(for: entry.phase)
    }


    public func resolveExtraction(
        for operationID: OperationID
    ) async throws -> DurableExtractionResolution {
        try loadIfNeeded()
        guard let entry = entries?.values.first(where: {
            $0.header.operationID == operationID
        }) else {
            return .absent
        }
        switch entry.phase {
        case .reserved, .rootCreated, .active:
            return .unfinished
        case .rolledBack:
            return .rolledBack
        case .committed:
            guard let outcome = entry.committedOutcome else {
                throw TransactionJournalError.committedOutcomeUnavailable(
                    operationID: operationID
                )
            }
            try validatePersistedOutcome(outcome, entry: entry)
            return .committed(try materialize(outcome, entry: entry))
        }
    }

    public func markRolledBack(_ transactionID: TransactionID) async throws {
        try loadIfNeeded()
        guard var entry = entries?[transactionID] else {
            throw TransactionJournalError.missingTransaction
        }
        if entry.phase == .rolledBack { return }
        guard entry.phase == .active else { throw TransactionJournalError.invalidTransition }
        entry.phase = .rolledBack
        try replaceEntry(entry)
    }

    public func releaseRolledBack(_ transactionID: TransactionID) async throws {
        try loadIfNeeded()
        guard let entry = entries?[transactionID] else { return }
        guard entry.phase == .rolledBack else { throw TransactionJournalError.invalidTransition }
        try requireDurableRootAbsence(entry)
        try removeEntry(entry)
    }

    public func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws {
        try loadIfNeeded(synchronizeCleanIndexDirectory: false)
        guard var entry = entries?[transactionID] else {
            throw TransactionJournalError.missingTransaction
        }
        let recoveryURL = entry.namespace.url.appendingPathComponent(
            entry.rootName,
            isDirectory: true
        )

        if entry.phase == .committed {
            guard let persistedOutcome = entry.committedOutcome else {
                throw TransactionJournalError.committedOutcomeUnavailable(
                    operationID: entry.header.operationID
                )
            }
            let retryOutcome: CommittedExtractionOutcomeDocument
            do {
                retryOutcome = try normalizedOutcome(
                    transactionID: transactionID,
                    result: result,
                    entry: entry
                )
            } catch {
                throw TransactionJournalError.committedOutcomeMismatch
            }
            guard retryOutcome == persistedOutcome else {
                throw TransactionJournalError.committedOutcomeMismatch
            }
            do {
                try fileSystem.fsync(indexDirectory)
            } catch {
                entries = nil
                throw TransactionJournalError.commitStateUncertain(
                    recoveryURL: recoveryURL
                )
            }
            return
        }

        guard entry.phase == .active else {
            throw TransactionJournalError.invalidTransition
        }
        let outcome = try normalizedOutcome(
            transactionID: transactionID,
            result: result,
            entry: entry
        )
        entry.phase = .committed
        entry.committedOutcome = outcome
        var candidate = entries ?? [:]
        candidate[transactionID] = entry
        let encodedCandidate = try encodedIndex(candidate)

        try persistCommittedCandidate(
            encodedData: encodedCandidate,
            recoveryURL: recoveryURL
        )
        entries = candidate
    }

    func releaseCommitted(operationID: OperationID) async throws {
        try loadIfNeeded()
        guard let entry = entries?.values.first(where: {
            $0.header.operationID == operationID
        }) else {
            return
        }
        guard entry.phase == .committed else {
            throw TransactionJournalError.invalidTransition
        }
        guard let outcome = entry.committedOutcome else {
            throw TransactionJournalError.committedOutcomeUnavailable(
                operationID: operationID
            )
        }
        try validatePersistedOutcome(outcome, entry: entry)
        try requireDurableRootAbsence(entry)
        try removeEntry(entry)
    }

    func recoveryEntries() throws -> [RecoveryIndexEntry] {
        try loadIfNeeded()
        let values = Array((entries ?? [:]).values)
        let limit = max(0, policy.journal.maximumRecoveryCountPerLaunch)
        guard values.count <= limit else {
            throw TransactionJournalError.capacityExceeded(
                limit: limit,
                observed: values.count
            )
        }
        return values.sorted {
            if $0.header.createdAt == $1.header.createdAt {
                return $0.header.transactionID.rawValue.uuidString
                    < $1.header.transactionID.rawValue.uuidString
            }
            return $0.header.createdAt < $1.header.createdAt
        }
    }


    func recoveryEntry(
        transactionID: TransactionID
    ) throws -> RecoveryIndexEntry? {
        try loadIfNeeded()
        return entries?[transactionID]
    }


    func beginPreparationAbort(
        transactionID: TransactionID
    ) throws -> RecoveryIndexEntry? {
        try loadIfNeeded()
        guard !preparationAbortClaims.contains(transactionID),
              preparationLeases[transactionID] == nil
        else { throw TransactionJournalError.invalidTransition }
        guard let entry = entries?[transactionID] else {
            return nil
        }
        guard entry.phase == .reserved || entry.phase == .rootCreated else {
            throw TransactionJournalError.invalidTransition
        }
        preparationAbortClaims.insert(transactionID)
        return entry
    }

    func completePreparationAbort(transactionID: TransactionID) throws {
        guard preparationAbortClaims.contains(transactionID),
              let entry = entries?[transactionID],
              entry.phase == .reserved || entry.phase == .rootCreated
        else {
            preparationAbortClaims.remove(transactionID)
            throw TransactionJournalError.invalidTransition
        }
        defer { preparationAbortClaims.remove(transactionID) }
        try removeEntry(entry)
    }

    func cancelPreparationAbort(transactionID: TransactionID) {
        preparationAbortClaims.remove(transactionID)
    }


    func committedEntryForFinalization(
        operationID: OperationID
    ) throws -> RecoveryIndexEntry? {
        try loadIfNeeded()
        guard let entry = entries?.values.first(where: {
            $0.header.operationID == operationID
        }) else {
            return nil
        }
        guard entry.phase == .committed else {
            throw TransactionJournalError.invalidTransition
        }
        guard let outcome = entry.committedOutcome else {
            throw TransactionJournalError.committedOutcomeUnavailable(
                operationID: operationID
            )
        }
        try validatePersistedOutcome(outcome, entry: entry)
        return entry
    }





    func persistRecoveryPhase(
        _ phase: TransactionRecoveryPhase,
        transactionID: TransactionID
    ) throws {
        try loadIfNeeded()
        guard var entry = entries?[transactionID] else {
            throw TransactionJournalError.missingTransaction
        }
        if entry.phase == phase { return }
        guard entry.phase == .active, phase == .rolledBack else {
            throw TransactionJournalError.invalidTransition
        }
        entry.phase = phase
        try replaceEntry(entry)
    }

    func releaseRecoveryEntry(_ transactionID: TransactionID) throws {
        try loadIfNeeded()
        guard let entry = entries?[transactionID] else { return }
        guard entry.phase == .reserved
                || entry.phase == .rootCreated
                || entry.phase == .rolledBack
        else { throw TransactionJournalError.invalidTransition }
        // Same requirement the two sibling release paths already enforce: the
        // root must be gone, and its removal must have reached disk, before the
        // index forgets the entry. Without this the recovery path could persist
        // "this transaction no longer exists" while the unlink was still only in
        // the page cache; a crash there leaves a root that recovery can never
        // find again, because recovery is driven entirely by the index and never
        // scans the namespace. This call also supplies the fsync that the unlink
        // sites (`recoverReserved`, `finishRootRemoval`) do not perform — they
        // fsync only on the branch where the root was already absent.
        try requireDurableRootAbsence(entry)
        try removeEntry(entry)
    }

    private var cap: Int {
        max(0, policy.journal.maximumJournalBytes)
    }

    private func loadIfNeeded(
        synchronizeCleanIndexDirectory: Bool = true
    ) throws {
        guard entries == nil else { return }
        guard let node = try fileSystem.statNoFollow(
            parent: indexDirectory,
            name: indexFileName
        ) else {
            try cleanupReplacementTemporary(
                synchronizeWhenAbsent: synchronizeCleanIndexDirectory
            )
            entries = [:]
            return
        }
        guard node.identity.kind == .regularFile else {
            throw TransactionJournalError.malformedIndex
        }
        let data: Data
        do {
            let handle = try fileSystem.openRegularFileNoFollow(
                parent: indexDirectory,
                name: indexFileName,
                expected: node.identity,
                access: .readOnly
            )
            defer { handle.close() }
            data = try readAll(handle, requireNonempty: true)
        }
        let document: RecoveryIndexDocument
        do {
            document = try JSONDecoder().decode(RecoveryIndexDocument.self, from: data)
        } catch {
            throw TransactionJournalError.malformedIndex
        }
        if document.schemaVersion == Self.migratableEmptyIndexSchemaVersion {
            try migrateEmptyLegacyIndex(
                document,
                indexNode: node,
                indexData: data
            )
            entries = [:]
            return
        }
        guard Self.readableIndexSchemaVersions.contains(document.schemaVersion) else {
            throw TransactionJournalError.incompatibleSchema(
                found: document.schemaVersion,
                expected: Self.currentIndexSchemaVersion
            )
        }
        for entry in document.entries where entry.header.schemaVersion != Self.headerSchemaVersion {
            throw TransactionJournalError.incompatibleSchema(
                found: entry.header.schemaVersion,
                expected: Self.headerSchemaVersion
            )
        }
        try cleanupReplacementTemporary(
            synchronizeWhenAbsent: synchronizeCleanIndexDirectory
        )
        var loaded: [TransactionID: RecoveryIndexEntry] = [:]
        var operations: Set<OperationID> = []
        for entry in document.entries {
            try validateLoadedEntry(entry)
            guard loaded[entry.header.transactionID] == nil,
                  operations.insert(entry.header.operationID).inserted
            else { throw TransactionJournalError.malformedIndex }
            loaded[entry.header.transactionID] = entry
        }
        entries = loaded
    }

    private func migrateEmptyLegacyIndex(
        _ document: RecoveryIndexDocument,
        indexNode: FileNode,
        indexData: Data
    ) throws {
        let incompatible = TransactionJournalError.incompatibleSchema(
            found: document.schemaVersion,
            expected: Self.currentIndexSchemaVersion
        )
        guard document.entries.isEmpty else { throw incompatible }

        let canonical = try encodedIndex([:])
        let children = try fileSystem.listNoFollow(indexDirectory)
        guard let persistedIndex = children.first(where: {
            exactPath($0.name, matches: indexFileName)
        }),
        persistedIndex.identity == indexNode.identity
        else { throw incompatible }

        let remaining = children.filter {
            !exactPath($0.name, matches: indexFileName)
        }
        guard remaining.count <= 1 else { throw incompatible }

        let replacementIdentity: FileNodeIdentity?
        if let temporary = remaining.first {
            guard exactPath(temporary.name, matches: replacementName),
                  temporary.identity.kind == .regularFile
            else { throw incompatible }
            let data = try readIndexFile(
                named: replacementName,
                expected: temporary.identity
            )
            guard data == canonical else { throw incompatible }
            replacementIdentity = temporary.identity
        } else {
            replacementIdentity = nil
        }

        try persistEmptyLegacyIndexMigration(
            canonical: canonical,
            originalIndexData: indexData,
            indexIdentity: indexNode.identity,
            replacementIdentity: replacementIdentity,
            incompatible: incompatible
        )
    }

    private func persistEmptyLegacyIndexMigration(
        canonical: Data,
        originalIndexData: Data,
        indexIdentity: FileNodeIdentity,
        replacementIdentity: FileNodeIdentity?,
        incompatible: TransactionJournalError
    ) throws {
        let temporaryIdentity: FileNodeIdentity
        let createdTemporary: Bool
        if let replacementIdentity {
            temporaryIdentity = replacementIdentity
            createdTemporary = false
        } else {
            let temporary = try fileSystem.createRegularFileExclusive(
                parent: indexDirectory,
                name: replacementName
            )
            do {
                try temporary.write(canonical)
                try temporary.fsync()
                temporary.close()
                temporaryIdentity = try requireNode(
                    indexDirectory,
                    name: replacementName,
                    kind: .regularFile
                )
                createdTemporary = true
            } catch {
                temporary.close()
                entries = nil
                throw error
            }
        }

        do {
            let observation = try fileSystem.swapObserved(
                leftParent: indexDirectory,
                leftName: replacementName,
                expectedLeft: temporaryIdentity,
                rightParent: indexDirectory,
                rightName: indexFileName,
                expectedRight: indexIdentity
            )
            guard observation.leftIdentity == indexIdentity,
                  observation.rightIdentity == temporaryIdentity
            else {
                try restoreEmptyLegacyIndexMigration(
                    indexIdentity: indexIdentity,
                    temporaryIdentity: temporaryIdentity
                )
                try removeCreatedMigrationTemporaryIfNeeded(
                    createdTemporary,
                    identity: temporaryIdentity
                )
                throw incompatible
            }

            let migratedData = try readIndexFile(
                named: indexFileName,
                expected: temporaryIdentity
            )
            let displacedData = try readIndexFile(
                named: replacementName,
                expected: indexIdentity
            )
            guard migratedData == canonical,
                  displacedData == originalIndexData
            else {
                try restoreEmptyLegacyIndexMigration(
                    indexIdentity: indexIdentity,
                    temporaryIdentity: temporaryIdentity
                )
                try removeCreatedMigrationTemporaryIfNeeded(
                    createdTemporary,
                    identity: temporaryIdentity
                )
                throw incompatible
            }

            try fileSystem.fsync(indexDirectory)
            try fileSystem.removeOwnedNoFollow(
                parent: indexDirectory,
                name: replacementName,
                expected: indexIdentity
            )
            try fileSystem.fsync(indexDirectory)
        } catch let error as FileSystemOperationError {
            entries = nil
            if case .identityMismatch = error {
                try removeCreatedMigrationTemporaryIfNeeded(
                    createdTemporary,
                    identity: temporaryIdentity
                )
                throw incompatible
            }
            throw error
        } catch {
            entries = nil
            throw error
        }
    }

    private func restoreEmptyLegacyIndexMigration(
        indexIdentity: FileNodeIdentity,
        temporaryIdentity: FileNodeIdentity
    ) throws {
        let observation = try fileSystem.swapObserved(
            leftParent: indexDirectory,
            leftName: replacementName,
            expectedLeft: indexIdentity,
            rightParent: indexDirectory,
            rightName: indexFileName,
            expectedRight: temporaryIdentity
        )
        guard observation.leftIdentity == temporaryIdentity,
              observation.rightIdentity == indexIdentity
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "index migration rollback mismatch"
            )
        }
        try fileSystem.fsync(indexDirectory)
    }

    private func removeCreatedMigrationTemporaryIfNeeded(
        _ created: Bool,
        identity: FileNodeIdentity
    ) throws {
        guard created else { return }
        try fileSystem.removeOwnedNoFollow(
            parent: indexDirectory,
            name: replacementName,
            expected: identity
        )
        try fileSystem.fsync(indexDirectory)
    }

    private func readIndexFile(
        named name: String,
        expected identity: FileNodeIdentity
    ) throws -> Data {
        let handle = try fileSystem.openRegularFileNoFollow(
            parent: indexDirectory,
            name: name,
            expected: identity,
            access: .readOnly
        )
        defer { handle.close() }
        return try readAll(handle, requireNonempty: true)
    }


    private func validateLoadedEntry(
        _ entry: RecoveryIndexEntry
    ) throws {
        try validateHeader(entry.header)
        guard entry.rootName
                == "transaction-\(entry.header.transactionID.rawValue.uuidString.lowercased())",
              entry.namespace.url.isFileURL,
              entry.namespace.url.path.hasPrefix("/"),
              entry.namespace.identity.kind == .directory,
              entry.namespace.identity.device == entry.header.destinationIdentity.device
        else { throw TransactionJournalError.malformedIndex }

        switch entry.phase {
        case .reserved:
            guard entry.rootIdentity == nil,
                  entry.stagingIdentity == nil
            else { throw TransactionJournalError.malformedIndex }
        case .rootCreated:
            guard let rootIdentity = entry.rootIdentity,
                  rootIdentity.kind == .directory,
                  rootIdentity.device == entry.namespace.identity.device,
                  entry.stagingIdentity == nil
            else { throw TransactionJournalError.malformedIndex }
        case .active, .rolledBack, .committed:
            guard let rootIdentity = entry.rootIdentity,
                  let stagingIdentity = entry.stagingIdentity,
                  rootIdentity.kind == .directory,
                  stagingIdentity.kind == .directory,
                  rootIdentity.device == entry.namespace.identity.device,
                  stagingIdentity.device == rootIdentity.device
            else { throw TransactionJournalError.malformedIndex }
        }

        if entry.phase == .committed {
            guard let outcome = entry.committedOutcome else {
                throw TransactionJournalError.malformedIndex
            }
            try validatePersistedOutcome(outcome, entry: entry)
        } else {
            guard entry.committedOutcome == nil else {
                throw TransactionJournalError.malformedIndex
            }
        }
    }

    private func persist(_ candidate: [TransactionID: RecoveryIndexEntry]) throws {
        let data = try encodedIndex(candidate)
        try cleanupReplacementTemporary()
        let temporary = try fileSystem.createRegularFileExclusive(
            parent: indexDirectory,
            name: replacementName
        )
        do {
            try temporary.write(data)
            try temporary.fsync()
            temporary.close()
            let identity = try requireNode(
                indexDirectory,
                name: replacementName,
                kind: .regularFile
            )
            try fileSystem.replaceRegularFileAtomically(
                parent: indexDirectory,
                temporaryName: replacementName,
                destinationName: indexFileName,
                expectedTemporary: identity
            )
            try fileSystem.fsync(indexDirectory)
        } catch {
            temporary.close()
            entries = nil
            throw error
        }
    }


    private func persistCommittedCandidate(
        encodedData: Data,
        recoveryURL: URL
    ) throws {
        var replacementSucceeded = false
        let temporary: DurableFileHandle
        do {
            try cleanupReplacementTemporary()
            temporary = try fileSystem.createRegularFileExclusive(
                parent: indexDirectory,
                name: replacementName
            )
        } catch {
            entries = nil
            throw error
        }
        do {
            try temporary.write(encodedData)
            try temporary.fsync()
            temporary.close()
            let identity = try requireNode(
                indexDirectory,
                name: replacementName,
                kind: .regularFile
            )
            try fileSystem.replaceRegularFileAtomically(
                parent: indexDirectory,
                temporaryName: replacementName,
                destinationName: indexFileName,
                expectedTemporary: identity
            )
            replacementSucceeded = true
            try fileSystem.fsync(indexDirectory)
        } catch {
            temporary.close()
            entries = nil
            if replacementSucceeded {
                throw TransactionJournalError.commitStateUncertain(
                    recoveryURL: recoveryURL
                )
            }
            throw error
        }
    }

    private func cleanupReplacementTemporary(
        synchronizeWhenAbsent: Bool = true
    ) throws {
        guard let node = try fileSystem.statNoFollow(
            parent: indexDirectory,
            name: replacementName
        ) else {
            if synchronizeWhenAbsent {
                try fileSystem.fsync(indexDirectory)
            }
            return
        }
        guard node.identity.kind == .regularFile else {
            throw TransactionJournalError.unsafeRecoveryState("invalid index replacement node")
        }
        let verified = try fileSystem.openRegularFileNoFollow(
            parent: indexDirectory,
            name: replacementName,
            expected: node.identity,
            access: .readOnly
        )
        verified.close()
        try fileSystem.removeOwnedNoFollow(
            parent: indexDirectory,
            name: replacementName,
            expected: node.identity
        )
    }

    private func encodedIndex(
        _ candidate: [TransactionID: RecoveryIndexEntry]
    ) throws -> Data {
        let normalizedEntries = try candidate.values.map { entry in
            try validateLoadedEntry(entry)
            return entry
        }
        let document = RecoveryIndexDocument(
            schemaVersion: Self.currentIndexSchemaVersion,
            entries: normalizedEntries.sorted {
                $0.header.transactionID.rawValue.uuidString
                    < $1.header.transactionID.rawValue.uuidString
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= cap else {
            throw TransactionJournalError.capacityExceeded(limit: cap, observed: data.count)
        }
        return data
    }

    private func validateIndexCapacity(_ candidate: [TransactionID: RecoveryIndexEntry]) throws {
        _ = try encodedIndex(candidate)
    }

    private func replaceEntry(_ entry: RecoveryIndexEntry) throws {
        var candidate = entries ?? [:]
        candidate[entry.header.transactionID] = entry
        do {
            try persist(candidate)
            entries = candidate
        } catch {
            entries = nil
            throw error
        }
    }


    private func restoreOriginalIndexAfterFailedPersistence(
        original: [TransactionID: RecoveryIndexEntry],
        candidate: [TransactionID: RecoveryIndexEntry]
    ) throws {
        entries = nil
        try loadIfNeeded()
        if entries == original {
            return
        }
        guard entries == candidate else {
            entries = nil
            throw TransactionJournalError.unsafeRecoveryState(
                "index state changed after failed persistence"
            )
        }
        do {
            try persist(original)
            entries = original
        } catch {
            entries = nil
            throw error
        }
    }

    private func removeEntry(_ entry: RecoveryIndexEntry) throws {
        let original = entries ?? [:]
        var candidate = original
        candidate.removeValue(forKey: entry.header.transactionID)
        do {
            try persist(candidate)
            entries = candidate
        } catch let releaseError {
            do {
                try restoreOriginalIndexAfterFailedPersistence(
                    original: original,
                    candidate: candidate
                )
            } catch {
                entries = nil
                throw error
            }
            throw releaseError
        }
    }


    /// Requires that `entry`'s transaction root is absent, and that its removal
    /// is durable, before the caller drops the entry from the index.
    private func requireDurableRootAbsence(_ entry: RecoveryIndexEntry) throws {
        // `.reserved` is the one phase that legitimately carries no root
        // identity: the name was reserved but no root was ever created, so there
        // is nothing to compare against. Every later phase must have one, and a
        // missing identity there means a corrupt index.
        let expectedRoot: FileNodeIdentity?
        if entry.phase == .reserved {
            expectedRoot = entry.rootIdentity
        } else {
            guard let identity = entry.rootIdentity else {
                throw TransactionJournalError.malformedIndex
            }
            expectedRoot = identity
        }

        let namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: entry.namespace.url,
            expected: entry.namespace.identity
        )
        defer { namespace.close() }
        if let observed = try fileSystem.statNoFollow(parent: namespace, name: entry.rootName) {
            // A node under the reserved name that is not the root we expected is
            // a different kind of problem than our own leftover root, and worth
            // distinguishing. With no expected identity, any node present is
            // simply still-present.
            if let expectedRoot, observed.identity != expectedRoot {
                throw FileSystemOperationError.identityMismatch(
                    expected: expectedRoot,
                    actual: observed.identity
                )
            }
            throw TransactionJournalError.unsafeRecoveryState("transaction root still present")
        }
        try fileSystem.fsync(namespace)
    }

    private func validateHeader(_ header: ExtractionJournalHeader) throws {
        guard header.schemaVersion == Self.headerSchemaVersion else {
            throw TransactionJournalError.incompatibleSchema(
                found: header.schemaVersion,
                expected: Self.headerSchemaVersion
            )
        }
        guard header.destinationURL.isFileURL,
              header.destinationURL.path.hasPrefix("/"),
              header.destinationIdentity.kind == .directory
        else { throw TransactionJournalError.malformedIndex }
        try validateManifest(header.stagingCleanupManifest)
    }

    private func validateManifest(_ manifest: StagingCleanupManifest) throws {
        guard manifest.entries.count <= max(0, policy.listing.listingHardCap) else {
            throw TransactionJournalError.invalidManifest("manifest entry count")
        }
        let paths = manifest.entries.map(\.relativePath)
        guard paths == paths.sorted() else {
            throw TransactionJournalError.invalidManifest("manifest order")
        }
        var collisionKeys: Set<String> = []
        var kinds: [String: ExtractionNodeKind] = [:]
        var totalPathBytes = 0
        for entry in manifest.entries {
            let components = try validatedRelativePath(entry.relativePath)
            guard [.regularFile, .directory, .symbolicLink].contains(entry.kind) else {
                throw TransactionJournalError.invalidManifest(entry.relativePath)
            }
            let pathBytes = entry.relativePath.utf8.count
            let (nextTotal, overflow) = totalPathBytes.addingReportingOverflow(pathBytes)
            guard !overflow, nextTotal <= max(0, policy.listing.totalPathByteCap) else {
                throw TransactionJournalError.invalidManifest("manifest path bytes")
            }
            totalPathBytes = nextTotal

            let normalized = components.joined(separator: "/")
                .precomposedStringWithCanonicalMapping
            let key = normalized
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .precomposedStringWithCanonicalMapping
            guard collisionKeys.insert(key).inserted else {
                throw TransactionJournalError.invalidManifest(entry.relativePath)
            }
            kinds[normalized] = entry.kind
            if components.count > 1 {
                for count in 1..<components.count {
                    let parent = components.prefix(count).joined(separator: "/")
                        .precomposedStringWithCanonicalMapping
                    guard kinds[parent] == .directory else {
                        throw TransactionJournalError.invalidManifest(entry.relativePath)
                    }
                }
            }
        }
    }

    private func expectedCapturedRootEntry(
        _ manifest: CapturedTreeManifest
    ) throws -> CapturedTreeManifestEntry {
        guard let root = manifest.entries.first,
              root.relativePath.utf8.isEmpty
        else { throw TransactionJournalError.malformedJournal }
        return root
    }

    private func exactPath(_ lhs: String, matches rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private func manifestRootPath(_ destination: JournalNodeReference) -> String {
        destination.relativeParentPath.isEmpty
            ? destination.name
            : destination.relativeParentPath + "/" + destination.name
    }

    private func encodedRecord(
        _ record: ExtractionJournalRecord,
        enforceJournalCap: Bool = true
    ) throws -> EncodedJournalRecord {
        let payload = try JSONEncoder().encode(record)
        let (frameSize, overflow) = payload.count.addingReportingOverflow(
            JournalFrame.headerSize
        )
        guard !overflow else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: Int.max
            )
        }
        if enforceJournalCap {
            guard payload.count <= cap, frameSize <= cap else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: frameSize
                )
            }
        }
        return EncodedJournalRecord(
            payloadByteCount: payload.count,
            frame: JournalFrame.encode(payload: payload)
        )
    }

    private func encodedManifestChunks(
        mutationID: JournalMutationID,
        entries: [CapturedTreeManifestEntry],
        preparationByteBudget: Int,
        armedFrameByteCount: Int
    ) throws -> [EncodedJournalRecord] {
        let chunkLimit = min(cap, Self.maximumManifestChunkFrameBytes)
        guard chunkLimit >= JournalFrame.headerSize else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: JournalFrame.headerSize
            )
        }

        func requirePreparationBudget(_ preparedFrameBytes: Int) throws {
            let (observed, overflow) = preparedFrameBytes.addingReportingOverflow(
                armedFrameByteCount
            )
            guard !overflow, preparedFrameBytes <= preparationByteBudget else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: overflow ? Int.max : observed
                )
            }
        }

        var result: [EncodedJournalRecord] = []
        var completedFrameBytes = 0
        var currentEntries: [CapturedTreeManifestEntry] = []
        var currentEncoded: EncodedJournalRecord?
        var sequence = 0

        for entry in entries {
            manifestPreparationObserver?.didPrepareManifestEntry()
            var candidateEntries = currentEntries
            candidateEntries.append(entry)
            let candidateRecord = ExtractionJournalRecord.replaceManifestChunk(
                mutationID: mutationID,
                sequence: sequence,
                entries: candidateEntries
            )
            try validateRecord(candidateRecord)
            let candidate = try encodedRecord(
                candidateRecord,
                enforceJournalCap: false
            )
            if candidate.frame.count <= chunkLimit {
                let (preparedFrameBytes, overflow) = completedFrameBytes
                    .addingReportingOverflow(candidate.frame.count)
                guard !overflow else {
                    throw TransactionJournalError.capacityExceeded(
                        limit: cap,
                        observed: Int.max
                    )
                }
                try requirePreparationBudget(preparedFrameBytes)
                currentEntries = candidateEntries
                currentEncoded = candidate
                continue
            }

            guard let completed = currentEncoded, !currentEntries.isEmpty else {
                throw TransactionJournalError.capacityExceeded(
                    limit: chunkLimit,
                    observed: candidate.frame.count
                )
            }
            result.append(completed)
            let (nextCompletedFrameBytes, completedBytesOverflow) = completedFrameBytes
                .addingReportingOverflow(completed.frame.count)
            guard !completedBytesOverflow else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: Int.max
                )
            }
            completedFrameBytes = nextCompletedFrameBytes

            let (nextSequence, sequenceOverflow) = sequence.addingReportingOverflow(1)
            guard !sequenceOverflow else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: Int.max
                )
            }
            sequence = nextSequence
            currentEntries = [entry]
            currentEncoded = try encodedRecord(
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: sequence,
                    entries: currentEntries
                ),
                enforceJournalCap: false
            )
            guard let currentEncoded,
                  currentEncoded.frame.count <= chunkLimit
            else {
                throw TransactionJournalError.capacityExceeded(
                    limit: chunkLimit,
                    observed: currentEncoded?.frame.count ?? Int.max
                )
            }
            let (preparedFrameBytes, overflow) = completedFrameBytes
                .addingReportingOverflow(currentEncoded.frame.count)
            guard !overflow else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: Int.max
                )
            }
            try requirePreparationBudget(preparedFrameBytes)
        }

        guard let currentEncoded, !currentEntries.isEmpty else {
            throw TransactionJournalError.malformedJournal
        }
        result.append(currentEncoded)
        return result
    }

    private func appendArmedMutation(
        _ encoded: [EncodedJournalRecord],
        mutationID: JournalMutationID,
        entry: RecoveryIndexEntry
    ) throws {
        let existing = try readJournal(entry, allowTruncatedTail: false)
        _ = try reconstructRecoveryMutations(existing)
        guard !journalMutationIDs(existing).contains(mutationID),
              !encoded.isEmpty
        else { throw TransactionJournalError.malformedJournal }

        let root = try openRoot(entry)
        defer { root.close() }
        let journalIdentity = try requireNode(
            root,
            name: Self.journalName,
            kind: .regularFile
        )
        let journal = try fileSystem.openRegularFileNoFollow(
            parent: root,
            name: Self.journalName,
            expected: journalIdentity,
            access: .readWrite
        )
        defer { journal.close() }

        let current = try journal.seekToEnd()
        guard current <= UInt64(Int.max) else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: Int.max
            )
        }
        var projected = Int(current)
        for value in encoded {
            guard value.payloadByteCount <= cap, value.frame.count <= cap else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: value.frame.count
                )
            }
            let (next, overflow) = projected.addingReportingOverflow(
                value.frame.count
            )
            guard !overflow, next <= cap else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: overflow ? Int.max : next
                )
            }
            projected = next
        }

        for (index, value) in encoded.enumerated() {
            let isArmed = index == encoded.index(before: encoded.endIndex)
            try append(
                value.frame,
                journal: journal,
                transactionRoot: root,
                durability: isArmed ? .mutationBarrier : .deferred,
                event: isArmed ? .armedFrameWritten : .preparationFrameWritten
            )
        }
    }

    private func append(
        _ frame: Data,
        journal: DurableFileHandle,
        transactionRoot: DirectoryHandle,
        durability: JournalAppendDurability,
        event: JournalMutationEvent
    ) throws {
        try journal.write(frame)
        try mutationObserver?.didReach(event)
        guard durability == .mutationBarrier else { return }
        try journal.fsync()
        try mutationObserver?.didReach(.journalFileSynced)
        try fileSystem.fsync(transactionRoot)
        try mutationObserver?.didReach(.transactionRootSynced)
    }

    private func journalMutationIDs(
        _ records: [ExtractionJournalRecord]
    ) -> Set<JournalMutationID> {
        Set(records.map { record in
            switch record {
            case .replaceManifestChunk(let mutationID, _, _),
                 .replaceSwapArmed(let mutationID, _, _, _, _, _, _),
                 .replaceSwapRecoveryCapture(let mutationID, _),
                 .publishMoveArmed(let mutationID, _, _, _):
                return mutationID
            }
        })
    }

    private func reconstructRecoveryMutations(
        _ records: [ExtractionJournalRecord]
    ) throws -> [RecoveryJournalMutation] {
        var preparations: [JournalMutationID: ReplaceManifestPreparation] = [:]
        var completed: Set<JournalMutationID> = []
        var replaceMutationIndexes: [JournalMutationID: Int] = [:]
        var mutations: [RecoveryJournalMutation] = []

        for record in records {
            switch record {
            case .replaceManifestChunk(let mutationID, let sequence, let entries):
                guard !completed.contains(mutationID), !entries.isEmpty else {
                    throw TransactionJournalError.malformedJournal
                }
                var preparation = preparations[mutationID]
                    ?? ReplaceManifestPreparation(nextSequence: 0, entries: [])
                guard sequence == preparation.nextSequence,
                      entriesAreStrictlyCanonical(
                          after: preparation.entries.last,
                          entries: entries
                      )
                else { throw TransactionJournalError.malformedJournal }
                preparation.entries.append(contentsOf: entries)
                let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
                guard !overflow else {
                    throw TransactionJournalError.malformedJournal
                }
                preparation.nextSequence = nextSequence
                preparations[mutationID] = preparation

            case .replaceSwapArmed(
                let mutationID,
                let staged,
                let destination,
                let replacementIdentity,
                let expectedCapturedRootIdentity,
                let manifestEntryCount,
                let manifestDigest
            ):
                guard let preparation = preparations.removeValue(forKey: mutationID),
                      preparation.nextSequence > 0,
                      preparation.entries.count == manifestEntryCount
                else { throw TransactionJournalError.malformedJournal }
                let manifest: CapturedTreeManifest
                do {
                    manifest = try CapturedTreeManifest(
                        rootPath: manifestRootPath(destination),
                        entries: preparation.entries
                    )
                } catch {
                    throw TransactionJournalError.malformedJournal
                }
                let rootEntry = try expectedCapturedRootEntry(manifest)
                guard manifest.entries == preparation.entries,
                      rootEntry.identity == expectedCapturedRootIdentity,
                      manifest.digest == manifestDigest,
                      completed.insert(mutationID).inserted
                else { throw TransactionJournalError.malformedJournal }
                replaceMutationIndexes[mutationID] = mutations.count
                mutations.append(.replaceSwap(
                    mutationID: mutationID,
                    staged: staged,
                    destination: destination,
                    replacementIdentity: replacementIdentity,
                    expectedCaptured: manifest,
                    recoveryCapturedIdentity: nil
                ))

            case .replaceSwapRecoveryCapture(
                let mutationID,
                let capturedIdentity
            ):
                guard let index = replaceMutationIndexes[mutationID],
                      case let .replaceSwap(
                          id,
                          staged,
                          destination,
                          replacementIdentity,
                          expectedCaptured,
                          nil
                      ) = mutations[index]
                else { throw TransactionJournalError.malformedJournal }
                mutations[index] = .replaceSwap(
                    mutationID: id,
                    staged: staged,
                    destination: destination,
                    replacementIdentity: replacementIdentity,
                    expectedCaptured: expectedCaptured,
                    recoveryCapturedIdentity: capturedIdentity
                )

            case .publishMoveArmed(
                let mutationID,
                let staged,
                let destination,
                let publishedIdentity
            ):
                guard !completed.contains(mutationID),
                      preparations[mutationID] == nil
                else { throw TransactionJournalError.malformedJournal }
                completed.insert(mutationID)
                mutations.append(.publishMove(
                    mutationID: mutationID,
                    staged: staged,
                    destination: destination,
                    publishedIdentity: publishedIdentity
                ))
            }
        }
        return mutations
    }

    private func entriesAreStrictlyCanonical(
        after previous: CapturedTreeManifestEntry?,
        entries: [CapturedTreeManifestEntry]
    ) -> Bool {
        var previousPath = previous.map { Data($0.relativePath.utf8) }
        for entry in entries {
            let path = Data(entry.relativePath.utf8)
            if let previousPath,
               !previousPath.lexicographicallyPrecedes(path) {
                return false
            }
            previousPath = path
        }
        return true
    }

    private func validateRecord(_ record: ExtractionJournalRecord) throws {
        let supportedKinds: Set<ExtractionNodeKind> = [
            .regularFile,
            .directory,
            .symbolicLink,
        ]
        switch record {
        case .replaceManifestChunk(_, let sequence, let entries):
            guard sequence >= 0,
                  !entries.isEmpty,
                  entries.allSatisfy({ supportedKinds.contains($0.identity.kind) }),
                  entriesAreStrictlyCanonical(after: nil, entries: entries)
            else { throw TransactionJournalError.malformedJournal }

        case .replaceSwapArmed(
            _,
            let staged,
            let destination,
            let replacementIdentity,
            let expectedCapturedRootIdentity,
            let manifestEntryCount,
            let manifestDigest
        ):
            guard staged.root == .staging,
                  destination.root == .destination,
                  supportedKinds.contains(replacementIdentity.kind),
                  supportedKinds.contains(expectedCapturedRootIdentity.kind),
                  replacementIdentity.device == staged.parentIdentity.device,
                  replacementIdentity.device == destination.parentIdentity.device,
                  expectedCapturedRootIdentity.device == destination.parentIdentity.device,
                  manifestEntryCount > 0,
                  manifestDigest.count == 32
            else { throw TransactionJournalError.malformedJournal }
            try validateReference(staged)
            try validateReference(destination)

        case .replaceSwapRecoveryCapture(_, let capturedIdentity):
            guard supportedKinds.contains(capturedIdentity.kind) else {
                throw TransactionJournalError.malformedJournal
            }

        case .publishMoveArmed(_, let staged, let destination, let identity):
            guard staged.root == .staging,
                  destination.root == .destination,
                  supportedKinds.contains(identity.kind),
                  identity.device == staged.parentIdentity.device,
                  identity.device == destination.parentIdentity.device
            else { throw TransactionJournalError.malformedJournal }
            try validateReference(staged)
            try validateReference(destination)
        }
    }

    private func validateReference(_ reference: JournalNodeReference) throws {
        guard reference.parentIdentity.kind == .directory,
              reference.name == reference.name.precomposedStringWithCanonicalMapping,
              reference.name.utf8.count <= max(0, policy.listing.maximumPathByteCount)
        else { throw TransactionJournalError.malformedJournal }
        if !reference.relativeParentPath.isEmpty {
            do {
                _ = try validatedRelativePath(reference.relativeParentPath)
            } catch {
                throw TransactionJournalError.malformedJournal
            }
        }
        do {
            try ArchiveComponentValidator.validate(reference.name)
        } catch {
            throw TransactionJournalError.malformedJournal
        }
    }

    private func validatedRelativePath(_ path: String) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              path == path.precomposedStringWithCanonicalMapping
        else { throw TransactionJournalError.invalidManifest(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.joined(separator: "/") == path,
              components.count <= max(0, policy.listing.maximumPathDepth),
              path.utf8.count <= max(0, policy.listing.maximumPathByteCount)
        else { throw TransactionJournalError.invalidManifest(path) }
        do {
            for component in components {
                try ArchiveComponentValidator.validate(component)
            }
        } catch {
            throw TransactionJournalError.invalidManifest(path)
        }
        return components
    }


    private func normalizedOutcome(
        transactionID: TransactionID,
        result: ExtractionResult,
        entry: RecoveryIndexEntry
    ) throws -> CommittedExtractionOutcomeDocument {
        guard result.transactionID == transactionID,
              transactionID == entry.header.transactionID
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "committed outcome transaction mismatch"
            )
        }
        let published = try result.publishedURLs.map {
            try normalizedPublishedPath(
                $0,
                destinationURL: entry.header.destinationURL
            )
        }
        let skipped = try result.skippedPaths.map {
            try validatedOutcomeRelativePath($0).joined(separator: "/")
        }
        let outcome = CommittedExtractionOutcomeDocument(
            transactionID: transactionID,
            published: published,
            skippedPaths: skipped
        )
        try validateOutcomeCollections(outcome, entry: entry)
        return outcome
    }

    private func normalizedPublishedPath(
        _ url: URL,
        destinationURL: URL
    ) throws -> CommittedPublishedPathDocument {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              components.query == nil,
              components.fragment == nil
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "invalid committed published URL"
            )
        }
        var rawComponents = url.path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard rawComponents.first == "" else {
            throw TransactionJournalError.unsafeRecoveryState(
                "published URL is not absolute"
            )
        }
        rawComponents.removeFirst()
        if url.hasDirectoryPath, rawComponents.last == "" {
            rawComponents.removeLast()
        }
        guard rawComponents.allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !$0.contains("\0")
                && isNFC($0)
        }) else {
            throw TransactionJournalError.unsafeRecoveryState(
                "invalid committed published path component"
            )
        }

        let destination = destinationURL.standardizedFileURL
        let standardized = url.standardizedFileURL
        let destinationComponents = destination.pathComponents
        let publishedComponents = standardized.pathComponents
        guard publishedComponents.count > destinationComponents.count,
              Array(publishedComponents.prefix(destinationComponents.count))
                == destinationComponents
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "committed published path escapes destination"
            )
        }
        let relativeComponents = Array(
            publishedComponents.dropFirst(destinationComponents.count)
        )
        let normalizedComponents = try relativeComponents.map {
            try validatedOutcomeComponent($0)
        }
        var canonical = destination
        for index in normalizedComponents.indices {
            canonical.appendPathComponent(
                normalizedComponents[index],
                isDirectory: index == normalizedComponents.index(before: normalizedComponents.endIndex)
                    ? standardized.hasDirectoryPath
                    : false
            )
        }
        // Compared against the *standardized* URL, not the raw one: `canonical`
        // is built from the standardized destination and the components taken
        // from `standardized`, so the raw URL is the one spelling that cannot
        // appear here. On macOS, standardizing an existing `/private/tmp/…` path
        // yields `/tmp/…`, so comparing the two spellings rejected every
        // legitimate publication into such a destination — after staging had
        // succeeded, which then rolled the whole extraction back and left the
        // destination empty.
        //
        // This does not weaken the check. Its purpose is to prove that the
        // published path is exactly the destination plus validated components,
        // with nothing lost or rewritten by `validatedOutcomeComponent`, and
        // both sides are now derived in the same space. `.`/`..`/empty/non-NFC
        // components are still rejected on the raw path above, before any
        // standardization, so a traversal spelling cannot be normalized into
        // acceptance here; containment is likewise still enforced in the
        // standardized space.
        guard canonical.absoluteString == standardized.absoluteString else {
            throw TransactionJournalError.unsafeRecoveryState(
                "noncanonical committed published URL"
            )
        }
        return CommittedPublishedPathDocument(
            relativePath: normalizedComponents.joined(separator: "/"),
            isDirectory: standardized.hasDirectoryPath
        )
    }

    private func validatedOutcomeRelativePath(
        _ path: String
    ) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              isNFC(path)
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "invalid committed relative path"
            )
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw TransactionJournalError.unsafeRecoveryState(
                "empty committed relative path"
            )
        }
        return try components.map(validatedOutcomeComponent)
    }

    private func validatedOutcomeComponent(_ component: String) throws -> String {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\0"),
              isNFC(component)
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "invalid committed path component"
            )
        }
        return component
    }


    private func isNFC(_ value: String) -> Bool {
        value.utf8.elementsEqual(
            value.precomposedStringWithCanonicalMapping.utf8
        )
    }

    private func validateOutcomeCollections(
        _ outcome: CommittedExtractionOutcomeDocument,
        entry: RecoveryIndexEntry
    ) throws {
        guard outcome.transactionID == entry.header.transactionID else {
            throw TransactionJournalError.unsafeRecoveryState(
                "persisted committed transaction mismatch"
            )
        }
        for published in outcome.published {
            let normalized = try validatedOutcomeRelativePath(
                published.relativePath
            ).joined(separator: "/")
            guard normalized == published.relativePath else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "noncanonical committed published path"
                )
            }
        }
        for skipped in outcome.skippedPaths {
            let normalized = try validatedOutcomeRelativePath(skipped)
                .joined(separator: "/")
            guard normalized == skipped else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "noncanonical committed skipped path"
                )
            }
        }
        guard isStrictlySorted(outcome.published.map(\.relativePath)),
              isStrictlySorted(outcome.skippedPaths)
        else {
            throw TransactionJournalError.unsafeRecoveryState(
                "committed outcome paths are duplicate or unsorted"
            )
        }
        let (totalCount, countOverflow) = outcome.published.count
            .addingReportingOverflow(outcome.skippedPaths.count)
        guard !countOverflow,
              totalCount <= entry.header.stagingCleanupManifest.entries.count
        else {
            throw TransactionJournalError.capacityExceeded(
                limit: entry.header.stagingCleanupManifest.entries.count,
                observed: countOverflow ? Int.max : totalCount
            )
        }
        try validateOutcomeByteCapacity(outcome)
    }

    private func validatePersistedOutcome(
        _ outcome: CommittedExtractionOutcomeDocument,
        entry: RecoveryIndexEntry
    ) throws {
        do {
            try validateOutcomeCollections(outcome, entry: entry)
        } catch {
            throw TransactionJournalError.malformedIndex
        }
    }

    private func validateOutcomeByteCapacity(
        _ outcome: CommittedExtractionOutcomeDocument
    ) throws {
        _ = try Self.checkedOutcomeByteCount(
            publishedPathByteCounts: outcome.published.map {
                $0.relativePath.utf8.count
            },
            skippedPathByteCounts: outcome.skippedPaths.map {
                $0.utf8.count
            },
            cap: cap
        )
    }


    static func checkedOutcomeByteCount(
        publishedPathByteCounts: [Int],
        skippedPathByteCounts: [Int],
        cap: Int
    ) throws -> Int {
        var total = MemoryLayout<UUID>.size

        func add(_ value: Int) throws {
            guard value >= 0 else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: Int.max
                )
            }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: Int.max
                )
            }
            total = next
        }

        try add(MemoryLayout<UInt64>.size * 2)
        for byteCount in publishedPathByteCounts {
            try add(MemoryLayout<UInt64>.size)
            try add(byteCount)
            try add(1)
        }
        for byteCount in skippedPathByteCounts {
            try add(MemoryLayout<UInt64>.size)
            try add(byteCount)
        }
        guard total <= cap else {
            throw TransactionJournalError.capacityExceeded(
                limit: cap,
                observed: total
            )
        }
        return total
    }

    private func isStrictlySorted(_ paths: [String]) -> Bool {
        guard paths.count > 1 else { return true }
        for index in 1..<paths.count {
            guard outcomePathLess(paths[index - 1], paths[index]) else {
                return false
            }
        }
        return true
    }

    private func outcomePathLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "/", omittingEmptySubsequences: false)
        for index in 0..<min(left.count, right.count) {
            if left[index] == right[index] { continue }
            return Array(left[index].utf8).lexicographicallyPrecedes(
                Array(right[index].utf8)
            )
        }
        return left.count < right.count
    }

    private func materialize(
        _ outcome: CommittedExtractionOutcomeDocument,
        entry: RecoveryIndexEntry
    ) throws -> ExtractionResult {
        let publishedURLs = try outcome.published.map { published in
            let components = try validatedOutcomeRelativePath(
                published.relativePath
            )
            var url = entry.header.destinationURL
            for index in components.indices {
                url.appendPathComponent(
                    components[index],
                    isDirectory: index == components.index(before: components.endIndex)
                        ? published.isDirectory
                        : false
                )
            }
            return url
        }
        return ExtractionResult(
            transactionID: outcome.transactionID,
            publishedURLs: publishedURLs,
            skippedPaths: outcome.skippedPaths
        )
    }

    private func provisionInfrastructure(_ root: DirectoryHandle) throws {
        if let journal = try fileSystem.statNoFollow(parent: root, name: Self.journalName) {
            guard journal.identity.kind == .regularFile else {
                throw TransactionJournalError.unsafeRecoveryState("journal kind")
            }
            let handle = try fileSystem.openRegularFileNoFollow(
                parent: root,
                name: Self.journalName,
                expected: journal.identity,
                access: .readWrite
            )
            try handle.fsync()
            handle.close()
        } else {
            let handle = try fileSystem.createRegularFileExclusive(
                parent: root,
                name: Self.journalName
            )
            try handle.fsync()
            handle.close()
        }
        if let staging = try fileSystem.statNoFollow(parent: root, name: Self.stagingName) {
            guard staging.identity.kind == .directory else {
                throw TransactionJournalError.unsafeRecoveryState("staging kind")
            }
            let handle = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                parent: root,
                name: Self.stagingName,
                expected: staging.identity
            )
            try fileSystem.fsync(handle)
            handle.close()
        } else {
            let handle = try fileSystem.createTransactionDirectoryExclusive(
                parent: root,
                name: Self.stagingName
            )
            try fileSystem.fsync(handle)
            handle.close()
        }
        try fileSystem.fsync(root)
    }


    private func makeActivatedTransaction(
        entry: RecoveryIndexEntry,
        root: DirectoryHandle
    ) throws -> ActivatedExtractionTransaction {
        let stagingIdentity = try requireNode(
            root,
            name: Self.stagingName,
            kind: .directory
        )
        if entry.phase == .active {
            guard let expectedStagingIdentity = entry.stagingIdentity else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "activated capability identity unavailable"
                )
            }
            guard stagingIdentity == expectedStagingIdentity else {
                throw TransactionJournalError.unsafeRecoveryState(
                    "activated capability identity replacement"
                )
            }
        } else {
            guard entry.phase == .rootCreated,
                  entry.stagingIdentity == nil
            else { throw TransactionJournalError.invalidTransition }
        }

        let stagingHandle = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: Self.stagingName,
            expected: stagingIdentity
        )
        let rootURL = entry.namespace.url.appendingPathComponent(
            entry.rootName,
            isDirectory: true
        )
        return ActivatedExtractionTransaction(
            transactionID: entry.header.transactionID,
            stagingURL: rootURL.appendingPathComponent(
                Self.stagingName,
                isDirectory: true
            ),
            stagingIdentity: stagingIdentity,
            stagingHandle: stagingHandle
        )
    }

    private func openRoot(_ entry: RecoveryIndexEntry) throws -> DirectoryHandle {
        guard let expected = entry.rootIdentity else {
            throw TransactionJournalError.unsafeRecoveryState("missing root identity")
        }
        let namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: entry.namespace.url,
            expected: entry.namespace.identity
        )
        defer { namespace.close() }
        return try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: entry.rootName,
            expected: expected
        )
    }

    private func readJournalWithValidLength(
        _ entry: RecoveryIndexEntry,
        allowTruncatedTail: Bool
    ) throws -> (
        records: [ExtractionJournalRecord],
        validLength: Int,
        totalLength: Int
    ) {
        let root = try openRoot(entry)
        defer { root.close() }
        let identity = try requireNode(root, name: Self.journalName, kind: .regularFile)
        let handle = try fileSystem.openRegularFileNoFollow(
            parent: root,
            name: Self.journalName,
            expected: identity,
            access: .readOnly
        )
        defer { handle.close() }
        let data = try readAll(handle, requireNonempty: false)
        var records: [ExtractionJournalRecord] = []
        var offset = 0
        while offset < data.count {
            let header: JournalFrame.Header?
            do {
                header = try JournalFrame.decodeHeader(
                    in: data,
                    at: offset,
                    maximumPayloadLength: cap
                )
            } catch JournalFrameError.payloadTooLarge {
                throw TransactionJournalError.capacityExceeded(limit: cap, observed: Int.max)
            } catch {
                // Wrong magic: the log is not merely cut short, it is not framed
                // the way this writer frames it. Never silently skipped, even for
                // an active transaction.
                throw TransactionJournalError.malformedJournal
            }
            guard let header else {
                // Not enough bytes left for a header at all.
                if allowTruncatedTail { break }
                throw TransactionJournalError.malformedJournal
            }

            let (payloadStart, startOverflow) = offset.addingReportingOverflow(
                JournalFrame.headerSize
            )
            let (payloadEnd, endOverflow) = payloadStart.addingReportingOverflow(
                header.payloadLength
            )
            guard !startOverflow, !endOverflow, payloadEnd <= cap else {
                throw TransactionJournalError.capacityExceeded(limit: cap, observed: Int.max)
            }
            guard payloadEnd <= data.count else {
                if allowTruncatedTail { break }
                throw TransactionJournalError.malformedJournal
            }
            let payload = data.subdata(in: payloadStart..<payloadEnd)

            guard JournalFrame.matches(checksum: header.checksum, payload: payload) else {
                // A bad CRC on the *final* frame is the signature of a crash
                // during the append: the record was never completed, so no
                // mutation followed it and dropping it is correct.
                //
                // A bad CRC with more frames after it cannot be explained that
                // way — the writer only ever appends, so a completed frame
                // preceded these. That is bit rot or interference, and replaying
                // around it risks acting on a record whose content is unknown.
                if allowTruncatedTail, payloadEnd == data.count { break }
                throw TransactionJournalError.malformedJournal
            }

            let record: ExtractionJournalRecord
            do {
                record = try JSONDecoder().decode(ExtractionJournalRecord.self, from: payload)
                try validateRecord(record)
            } catch let error as TransactionJournalError {
                throw error
            } catch {
                throw TransactionJournalError.malformedJournal
            }
            records.append(record)
            offset = payloadEnd
        }
        return (records, offset, data.count)
    }

    private func readJournal(
        _ entry: RecoveryIndexEntry,
        allowTruncatedTail: Bool
    ) throws -> [ExtractionJournalRecord] {
        try readJournalWithValidLength(
            entry,
            allowTruncatedTail: allowTruncatedTail
        ).records
    }

static func readChunkCount(forLimit limit: Int) -> Int {
        let nonnegative = max(0, limit)
        if nonnegative == Int.max { return 64 * 1_024 }
        return min(64 * 1_024, max(1, nonnegative + 1))
    }

    private func readAll(
        _ handle: DurableFileHandle,
        requireNonempty: Bool
    ) throws -> Data {
        try handle.seek(toOffset: 0)
        var data = Data()
        let chunkCount = Self.readChunkCount(forLimit: cap)
        while true {
            let chunk = try handle.read(upToCount: chunkCount)
            if chunk.isEmpty { break }
            let (next, overflow) = data.count.addingReportingOverflow(chunk.count)
            guard !overflow, next <= cap else {
                throw TransactionJournalError.capacityExceeded(
                    limit: cap,
                    observed: overflow ? Int.max : next
                )
            }
            data.append(chunk)
        }
        if requireNonempty, data.isEmpty { throw TransactionJournalError.malformedIndex }
        return data
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
            base = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                parent: transactionRoot,
                name: Self.stagingName,
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
        let components = try validatedRelativePath(reference.relativeParentPath)
        let result = try fileSystem.openRelativeDirectoryNoFollow(
            root: base,
            components: components,
            expected: reference.parentIdentity
        )
        base.close()
        return result
    }

    private func requireNode(
        _ parent: DirectoryHandle,
        name: String,
        kind: ExtractionNodeKind
    ) throws -> FileNodeIdentity {
        guard let node = try fileSystem.statNoFollow(parent: parent, name: name) else {
            throw TransactionJournalError.unsafeRecoveryState("missing \(name)")
        }
        guard node.identity.kind == kind else {
            throw TransactionJournalError.unsafeRecoveryState("wrong kind for \(name)")
        }
        return node.identity
    }

    private func locator(
        for entry: RecoveryIndexEntry,
        rootIdentity: FileNodeIdentity
    ) -> TransactionRootLocator {
        TransactionRootLocator(
            namespace: entry.namespace,
            rootName: entry.rootName,
            rootIdentity: rootIdentity
        )
    }

    private func persisted(
        _ entry: RecoveryIndexEntry,
        records: [ExtractionJournalRecord]
    ) -> PersistedExtractionJournal {
        PersistedExtractionJournal(
            header: entry.header,
            namespace: entry.namespace,
            rootName: entry.rootName,
            rootIdentity: entry.rootIdentity,
            records: records,
            resolution: resolution(for: entry.phase),
            phase: entry.phase
        )
    }

    private func resolution(
        for phase: TransactionRecoveryPhase
    ) -> DurableOperationEffectResolution {
        switch phase {
        case .reserved, .rootCreated, .active:
            return .unfinished
        case .rolledBack:
            return .rolledBack
        case .committed:
            return .committed
        }
    }
}
