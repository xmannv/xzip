import Foundation
import XZIPDomain

public enum ExtractionNodeKind: String, Codable, Sendable {
    case regularFile, directory, symbolicLink
    case hardLink, fifo, socket, blockDevice, characterDevice, unknown
}

public struct ExtractionInventoryEntry: Codable, Hashable, Sendable {
    public let path: String
    public let kind: ExtractionNodeKind
    public let size: UInt64
    public let linkTarget: String?
    public let isExplicitDirectory: Bool

    /// The permission bits the archive recorded for this node, if it recorded
    /// any (`nil` for archives written without POSIX modes, e.g. many Windows
    /// zips).
    ///
    /// Only the low 9 bits are carried; set-user/group-ID and sticky bits are
    /// deliberately dropped so a hostile archive cannot request them. The
    /// extraction transaction restores directory modes from this value just
    /// before publication, which is why it needs no durable representation:
    /// recovery only ever inverts a publication, never replays one.
    public let posixMode: UInt16?

    public init(
        path: String,
        kind: ExtractionNodeKind,
        size: UInt64,
        linkTarget: String?,
        isExplicitDirectory: Bool,
        posixMode: UInt16? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.linkTarget = linkTarget
        self.isExplicitDirectory = isExplicitDirectory
        self.posixMode = posixMode
    }
}

public enum ExtractionInventoryError: Error, Equatable, Sendable {
    case invalidPath(String)
    case unsupportedNode(path: String, kind: ExtractionNodeKind)
    case symlinkParent(String)
    case nonDirectoryParent(String)
    case destinationCollision(first: String, second: String)
    case entryCountExceeded(limit: Int)
    case pathDepthExceeded(path: String, limit: Int)
    case pathByteCountExceeded(path: String, limit: Int)
    case totalPathByteCountExceeded(limit: Int)
    case advertisedOutputByteCountOverflow
    case advertisedOutputByteCountExceeded(limit: UInt64)
    case advertisedDictionaryByteCountExceeded(limit: UInt64)
}

/// Same reason as the sibling error types: the app renders
/// `error.localizedDescription`, so without this these read as
/// "(XZIPCore.ExtractionInventoryError error 4.)".
///
/// These are the refusals that happen *before* anything is written, so the
/// wording names the offending entry where one exists: a user told which path in
/// the archive is the problem can decide whether to trust the archive at all.
extension ExtractionInventoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "The archive contains an unusable path: \(path)"
        case let .unsupportedNode(path, kind):
            return "The archive contains an unsupported \(kind): \(path)"
        case let .symlinkParent(path):
            return "The archive would extract through a symbolic link: \(path)"
        case let .nonDirectoryParent(path):
            return "The archive expects \(path) to be a folder, and it is not."
        case let .destinationCollision(first, second):
            return "Two entries would be written to the same file: "
                + "\(first) and \(second)"
        case let .entryCountExceeded(limit):
            return "The archive holds more than \(limit) entries."
        case let .pathDepthExceeded(path, limit):
            return "A path in the archive nests deeper than \(limit) levels: \(path)"
        case let .pathByteCountExceeded(path, limit):
            return "A path in the archive is longer than \(limit) bytes: \(path)"
        case let .totalPathByteCountExceeded(limit):
            return "The archive's paths total more than \(limit) bytes."
        case .advertisedOutputByteCountOverflow:
            return "The archive reports a nonsensical uncompressed size."
        case let .advertisedOutputByteCountExceeded(limit):
            return "The archive would extract to more than \(limit) bytes."
        case let .advertisedDictionaryByteCountExceeded(limit):
            return "The archive needs more than \(limit) bytes of memory to decompress."
        }
    }
}

public struct ExtractionInventory: Codable, Hashable, Sendable {
    public let entries: [ExtractionInventoryEntry]
    public let implicitDirectories: Set<String>
    public let advertisedOutputByteCount: UInt64
    public let advertisedDictionaryByteCount: UInt64

    public init(
        entries: [ExtractionInventoryEntry],
        implicitDirectories: Set<String>,
        advertisedOutputByteCount: UInt64,
        advertisedDictionaryByteCount: UInt64
    ) {
        self.entries = entries
        self.implicitDirectories = implicitDirectories
        self.advertisedOutputByteCount = advertisedOutputByteCount
        self.advertisedDictionaryByteCount = advertisedDictionaryByteCount
    }

    public static func validated(
        entries: [ExtractionInventoryEntry],
        advertisedDictionaryByteCount: UInt64,
        policy: ArchiveResourcePolicy
    ) throws -> ExtractionInventory {
        guard entries.count <= policy.listing.listingHardCap else {
            throw ExtractionInventoryError.entryCountExceeded(
                limit: policy.listing.listingHardCap
            )
        }
        guard advertisedDictionaryByteCount <= policy.output.advertisedDictionaryByteCap else {
            throw ExtractionInventoryError.advertisedDictionaryByteCountExceeded(
                limit: policy.output.advertisedDictionaryByteCap
            )
        }

        var totalPathByteCount = 0
        var advertisedOutputByteCount: UInt64 = 0
        var componentsByPath: [String: [String]] = [:]
        var explicitEntriesByDestination: [String: ExtractionInventoryEntry] = [:]
        var destinationPaths: [String: String] = [:]

        for entry in entries {
            let components = try validatedComponents(of: entry.path)
            guard components.count <= policy.listing.maximumPathDepth else {
                throw ExtractionInventoryError.pathDepthExceeded(
                    path: entry.path,
                    limit: policy.listing.maximumPathDepth
                )
            }

            let pathByteCount = entry.path.utf8.count
            guard pathByteCount <= policy.listing.maximumPathByteCount else {
                throw ExtractionInventoryError.pathByteCountExceeded(
                    path: entry.path,
                    limit: policy.listing.maximumPathByteCount
                )
            }
            let (nextTotalPathByteCount, pathByteCountOverflow) =
                totalPathByteCount.addingReportingOverflow(pathByteCount)
            guard !pathByteCountOverflow,
                  nextTotalPathByteCount <= policy.listing.totalPathByteCap
            else {
                throw ExtractionInventoryError.totalPathByteCountExceeded(
                    limit: policy.listing.totalPathByteCap
                )
            }
            totalPathByteCount = nextTotalPathByteCount

            switch entry.kind {
            case .regularFile, .directory, .symbolicLink:
                break
            case .hardLink, .fifo, .socket, .blockDevice, .characterDevice, .unknown:
                throw ExtractionInventoryError.unsupportedNode(
                    path: entry.path,
                    kind: entry.kind
                )
            }

            let destination = destinationKey(entry.path)
            if let existing = destinationPaths[destination] {
                throw ExtractionInventoryError.destinationCollision(
                    first: existing,
                    second: entry.path
                )
            }
            destinationPaths[destination] = entry.path
            explicitEntriesByDestination[destination] = entry
            componentsByPath[entry.path] = components

            let (nextOutputByteCount, outputOverflow) =
                advertisedOutputByteCount.addingReportingOverflow(entry.size)
            guard !outputOverflow else {
                throw ExtractionInventoryError.advertisedOutputByteCountOverflow
            }
            guard nextOutputByteCount <= policy.output.advertisedOutputByteCap else {
                throw ExtractionInventoryError.advertisedOutputByteCountExceeded(
                    limit: policy.output.advertisedOutputByteCap
                )
            }
            advertisedOutputByteCount = nextOutputByteCount
        }

        var implicitDirectories = Set<String>()
        for entry in entries {
            guard let components = componentsByPath[entry.path], components.count > 1 else {
                continue
            }
            for parentDepth in 1..<components.count {
                let parent = components.prefix(parentDepth).joined(separator: "/")
                let destination = destinationKey(parent)

                if let explicit = explicitEntriesByDestination[destination] {
                    guard explicit.path == parent else {
                        throw ExtractionInventoryError.destinationCollision(
                            first: explicit.path,
                            second: parent
                        )
                    }
                    switch explicit.kind {
                    case .directory:
                        continue
                    case .symbolicLink:
                        throw ExtractionInventoryError.symlinkParent(parent)
                    default:
                        throw ExtractionInventoryError.nonDirectoryParent(parent)
                    }
                }

                if let existing = destinationPaths[destination], existing != parent {
                    throw ExtractionInventoryError.destinationCollision(
                        first: existing,
                        second: parent
                    )
                }
                destinationPaths[destination] = parent
                implicitDirectories.insert(parent)
            }
        }

        return ExtractionInventory(
            entries: entries,
            implicitDirectories: implicitDirectories,
            advertisedOutputByteCount: advertisedOutputByteCount,
            advertisedDictionaryByteCount: advertisedDictionaryByteCount
        )
    }

    private static func validatedComponents(of path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ExtractionInventoryError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw ExtractionInventoryError.invalidPath(path)
        }
        do {
            return try components.map { component in
                try ArchiveComponentValidator.validate(String(component))
            }
        } catch {
            throw ExtractionInventoryError.invalidPath(path)
        }
    }

    private static func destinationKey(_ path: String) -> String {
        FileSystemNameCanonicalization.key(path: path)
    }
}
