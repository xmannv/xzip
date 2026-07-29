import Foundation

public struct OperationID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TransactionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum OperationState: String, Codable, Sendable {
    case queued
    case running
    case waitingForCredential
    case stopping
    case completed
    case failed
    case cancelled
}

public struct ArchiveSessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AuthenticationContextID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EditSessionKey: Hashable, Codable, Sendable {
    public let archiveID: ArchiveID
    public let entryPath: String

    public init(archiveID: ArchiveID, entryPath: String) {
        self.archiveID = archiveID
        self.entryPath = entryPath
    }
}

public enum OperationKind: String, Codable, Sendable {
    case open
    case list
    case test
    case extract
    case compress
    case add
    case repackAdd
    case delete
    case rename
    case create
    case readComment
    case saveBack
    case writeComment
    case beginEdit
    case endEdit
    case joinSplit
    case brokerCommand
}

public enum OperationConflictPolicy: String, Codable, Sendable {
    case replace
    case keepBoth
    case skip
    case ask
    case fail
}

public struct OperationResourceReference: Equatable, Codable, Sendable {
    public let identity: FileSystemIdentity?
    public let url: URL

    public init(identity: FileSystemIdentity?, url: URL) {
        self.identity = identity
        self.url = url
    }
}

public struct ArchiveReadOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference

    public init(archive: OperationResourceReference) {
        self.archive = archive
    }
}

public struct CompressionOperationPayload: Equatable, Codable, Sendable {
    public let sources: [OperationResourceReference]
    public let destination: OperationResourceReference
    public let formatIdentifier: String
    public let compressionLevel: Int
    public let encryptFileNames: Bool
    public let volumeSizeBytes: UInt64?
    public let exclusionPatterns: [String]
    public let preserveTimestamps: Bool
    public let conflictPolicy: OperationConflictPolicy

    public init(
        sources: [OperationResourceReference],
        destination: OperationResourceReference,
        formatIdentifier: String,
        compressionLevel: Int,
        encryptFileNames: Bool,
        volumeSizeBytes: UInt64?,
        exclusionPatterns: [String],
        preserveTimestamps: Bool,
        conflictPolicy: OperationConflictPolicy
    ) {
        self.sources = sources
        self.destination = destination
        self.formatIdentifier = formatIdentifier
        self.compressionLevel = compressionLevel
        self.encryptFileNames = encryptFileNames
        self.volumeSizeBytes = volumeSizeBytes
        self.exclusionPatterns = exclusionPatterns
        self.preserveTimestamps = preserveTimestamps
        self.conflictPolicy = conflictPolicy
    }
}

public struct ExtractionPlanDigest: Hashable, Codable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

public struct ExtractionPublicationNodeIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let generation: UInt64?
    public let kindRawValue: String

    public init(
        device: UInt64,
        inode: UInt64,
        generation: UInt64?,
        kindRawValue: String
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.kindRawValue = kindRawValue
    }
}

public enum ExtractionPublicationDecision: Hashable, Codable, Sendable {
    case publish
    case mergeDirectory
    case fail
    case skip
    case keepBoth(finalPath: String)
    case replace
    case ask
}

public struct ExtractionPublicationBindingEntry: Hashable, Codable, Sendable {
    public let originalPath: String
    public let expectedIdentity: ExtractionPublicationNodeIdentity?
    public let decision: ExtractionPublicationDecision

    public init(
        originalPath: String,
        expectedIdentity: ExtractionPublicationNodeIdentity?,
        decision: ExtractionPublicationDecision
    ) {
        self.originalPath = originalPath
        self.expectedIdentity = expectedIdentity
        self.decision = decision
    }
}

public struct DestructiveReplacementApproval: Hashable, Codable, Sendable {
    public let archiveRevision: ArchiveRevision
    public let destinationIdentity: ExtractionDestinationIdentity
    public let conflictPolicy: OperationConflictPolicy
    public let planDigest: ExtractionPlanDigest
    public let publicationBinding: [ExtractionPublicationBindingEntry]

    public init(
        archiveRevision: ArchiveRevision,
        destinationIdentity: ExtractionDestinationIdentity,
        conflictPolicy: OperationConflictPolicy,
        planDigest: ExtractionPlanDigest,
        publicationBinding: [ExtractionPublicationBindingEntry]
    ) {
        self.archiveRevision = archiveRevision
        self.destinationIdentity = destinationIdentity
        self.conflictPolicy = conflictPolicy
        self.planDigest = planDigest
        self.publicationBinding = publicationBinding
    }
}

public struct ExtractionOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let destination: OperationResourceReference
    public let selectedEntryPaths: [String]
    public let conflictPolicy: OperationConflictPolicy
    public let preserveTimestamps: Bool
    public let expectedArchiveRevision: ArchiveRevision?
    public let expectedDestinationIdentity: ExtractionDestinationIdentity?
    public let planDigest: ExtractionPlanDigest?
    public let publicationBinding: [ExtractionPublicationBindingEntry]?
    public let replacementApproval: DestructiveReplacementApproval?

    public init(
        archive: OperationResourceReference,
        destination: OperationResourceReference,
        selectedEntryPaths: [String],
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        expectedArchiveRevision: ArchiveRevision? = nil,
        expectedDestinationIdentity: ExtractionDestinationIdentity? = nil,
        planDigest: ExtractionPlanDigest? = nil,
        publicationBinding: [ExtractionPublicationBindingEntry]? = nil,
        replacementApproval: DestructiveReplacementApproval? = nil
    ) {
        self.archive = archive
        self.destination = destination
        self.selectedEntryPaths = selectedEntryPaths
        self.conflictPolicy = conflictPolicy
        self.preserveTimestamps = preserveTimestamps
        self.expectedArchiveRevision = expectedArchiveRevision
        self.expectedDestinationIdentity = expectedDestinationIdentity
        self.planDigest = planDigest
        self.publicationBinding = publicationBinding
        self.replacementApproval = replacementApproval
    }
}

public struct AddOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let sources: [OperationResourceReference]
    public let workingDirectory: OperationResourceReference?

    public init(
        archive: OperationResourceReference,
        sources: [OperationResourceReference],
        workingDirectory: OperationResourceReference?
    ) {
        self.archive = archive
        self.sources = sources
        self.workingDirectory = workingDirectory
    }
}

public struct DeleteOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let entryPaths: [String]

    public init(archive: OperationResourceReference, entryPaths: [String]) {
        self.archive = archive
        self.entryPaths = entryPaths
    }
}

public struct RenameOperationPair: Equatable, Codable, Sendable {
    public let entryPath: String
    public let newName: String

    public init(entryPath: String, newName: String) {
        self.entryPath = entryPath
        self.newName = newName
    }
}

public struct RenameOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let pairs: [RenameOperationPair]

    public init(archive: OperationResourceReference, pairs: [RenameOperationPair]) {
        self.archive = archive
        self.pairs = pairs
    }
}

public enum ArchiveEntryCreationKind: String, Equatable, Codable, Sendable {
    case file
    case folder
}

public struct CreateEntryOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let parentPath: String
    public let name: String
    public let kind: ArchiveEntryCreationKind

    public init(
        archive: OperationResourceReference,
        parentPath: String,
        name: String,
        kind: ArchiveEntryCreationKind
    ) {
        self.archive = archive
        self.parentPath = parentPath
        self.name = name
        self.kind = kind
    }
}

public struct EditSessionOperationPayload: Equatable, Codable, Sendable {
    public let key: EditSessionKey
    public let archive: OperationResourceReference

    public init(key: EditSessionKey, archive: OperationResourceReference) {
        self.key = key
        self.archive = archive
    }
}

public struct SaveBackOperationPayload: Equatable, Codable, Sendable {
    public let key: EditSessionKey
    public let archive: OperationResourceReference
    public let workingDirectory: OperationResourceReference

    public init(
        key: EditSessionKey,
        archive: OperationResourceReference,
        workingDirectory: OperationResourceReference
    ) {
        self.key = key
        self.archive = archive
        self.workingDirectory = workingDirectory
    }
}

public struct WriteCommentOperationPayload: Equatable, Codable, Sendable {
    public let archive: OperationResourceReference
    public let comment: String

    public init(archive: OperationResourceReference, comment: String) {
        self.archive = archive
        self.comment = comment
    }
}

public struct JoinSplitOperationPayload: Equatable, Codable, Sendable {
    public let parts: [OperationResourceReference]
    public let destination: OperationResourceReference
    public let preserveTimestamps: Bool

    public init(
        parts: [OperationResourceReference],
        destination: OperationResourceReference,
        preserveTimestamps: Bool
    ) {
        self.parts = parts
        self.destination = destination
        self.preserveTimestamps = preserveTimestamps
    }
}

public struct BrokerCommandOperationPayload: Equatable, Codable, Sendable {
    public let schemaVersion: UInt16
    public let encodedCommand: Data

    public init(schemaVersion: UInt16, encodedCommand: Data) {
        self.schemaVersion = schemaVersion
        self.encodedCommand = encodedCommand
    }
}

public enum OperationPayload: Equatable, Codable, Sendable {
    case open(ArchiveReadOperationPayload)
    case list(ArchiveReadOperationPayload)
    case test(ArchiveReadOperationPayload)
    case extract(ExtractionOperationPayload)
    case compress(CompressionOperationPayload)
    case add(AddOperationPayload)
    case repackAdd(AddOperationPayload)
    case delete(DeleteOperationPayload)
    case rename(RenameOperationPayload)
    case create(CreateEntryOperationPayload)
    case readComment(ArchiveReadOperationPayload)
    case saveBack(SaveBackOperationPayload)
    case writeComment(WriteCommentOperationPayload)
    case beginEdit(EditSessionOperationPayload)
    case endEdit(EditSessionOperationPayload)
    case joinSplit(JoinSplitOperationPayload)
    case brokerCommand(BrokerCommandOperationPayload)

    public var kind: OperationKind {
        switch self {
        case .open: return .open
        case .list: return .list
        case .test: return .test
        case .extract: return .extract
        case .compress: return .compress
        case .add: return .add
        case .repackAdd: return .repackAdd
        case .delete: return .delete
        case .rename: return .rename
        case .create: return .create
        case .readComment: return .readComment
        case .saveBack: return .saveBack
        case .writeComment: return .writeComment
        case .beginEdit: return .beginEdit
        case .endEdit: return .endEdit
        case .joinSplit: return .joinSplit
        case .brokerCommand: return .brokerCommand
        }
    }
}

public struct OperationUIMetadata: Equatable, Codable, Sendable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct OperationDescriptor: Equatable, Codable, Sendable {
    public let operationID: OperationID
    public let archiveID: ArchiveID?
    public let sessionID: ArchiveSessionID?
    public let payload: OperationPayload
    public let resourcePolicy: ArchiveResourcePolicy
    public let ui: OperationUIMetadata

    public var kind: OperationKind { payload.kind }

    public init(
        operationID: OperationID = OperationID(),
        archiveID: ArchiveID? = nil,
        sessionID: ArchiveSessionID? = nil,
        payload: OperationPayload,
        resourcePolicy: ArchiveResourcePolicy,
        ui: OperationUIMetadata
    ) {
        self.operationID = operationID
        self.archiveID = archiveID
        self.sessionID = sessionID
        self.payload = payload
        self.resourcePolicy = resourcePolicy
        self.ui = ui
    }
}
