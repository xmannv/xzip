import Foundation

public struct ArchiveIncarnationToken: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum FileSystemIdentity: Hashable, Codable, Sendable {
    case stable(
        volumeIdentifier: UInt64,
        fileIdentifier: UInt64,
        generation: UInt64?
    )
    case canonicalPath(path: String, incarnation: ArchiveIncarnationToken)
}

public struct ExtractionDestinationIdentity: Hashable, Codable, Sendable {
    public let parent: FileSystemIdentity
    public let root: FileSystemIdentity

    public init(parent: FileSystemIdentity, root: FileSystemIdentity) {
        self.parent = parent
        self.root = root
    }
}

public struct ArchiveID: Hashable, Codable, Sendable {
    public let identity: FileSystemIdentity

    public init(identity: FileSystemIdentity) {
        self.identity = identity
    }
}

public struct ArchiveLocator: Equatable, Codable, Sendable {
    public let archiveID: ArchiveID
    public private(set) var url: URL

    public init(archiveID: ArchiveID, url: URL) {
        self.archiveID = archiveID
        self.url = url
    }

    public mutating func updateURL(_ url: URL) {
        self.url = url
    }
}

public struct ArchiveRevision: Hashable, Codable, Sendable {
    public let archiveID: ArchiveID
    public let fileSize: UInt64
    public let contentModificationDate: Date
    public let boundedContentFingerprint: Data?

    public init(
        archiveID: ArchiveID,
        fileSize: UInt64,
        contentModificationDate: Date,
        boundedContentFingerprint: Data?
    ) {
        self.archiveID = archiveID
        self.fileSize = fileSize
        self.contentModificationDate = contentModificationDate
        self.boundedContentFingerprint = boundedContentFingerprint
    }
}

public struct ResolvedArchive: Equatable, Sendable {
    public let locator: ArchiveLocator
    public let revision: ArchiveRevision

    public init(locator: ArchiveLocator, revision: ArchiveRevision) {
        self.locator = locator
        self.revision = revision
    }
}

public protocol ArchiveIdentityResolving: Sendable {
    func resolve(_ url: URL) throws -> ResolvedArchive
}
