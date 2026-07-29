import Foundation
import XZIPCore
import XZIPDomain

/// Live `PublicationQuarantining` that applies the macOS `com.apple.quarantine`
/// extended attribute to every staged manifest node before publication, so
/// files extracted by XZIP carry the same Gatekeeper provenance the system
/// applies to downloaded content.
///
/// The attribute is written no-follow and identity-checked against the staged
/// node's `FileNodeIdentity`: a symlink receives the attribute on the link
/// itself (`O_SYMLINK`), never on its target, and a directory receives it on
/// the opened directory. Any identity mismatch, unexpected symlink, or wrong
/// node kind surfaces as a `FileSystemOperationError`, which the transaction
/// remaps to an unsafe-staging rollback.
///
/// The value follows the documented `com.apple.quarantine` layout:
/// `flags;hexTimestamp;agentName;UUID`. Time and UUID are injectable so the
/// value is deterministic under test.
public struct LivePublicationQuarantine: PublicationQuarantining {
    /// The macOS Gatekeeper quarantine attribute key.
    public static let attributeKey = "com.apple.quarantine"

    /// Quarantine flags: `0081` marks the item as downloaded and not yet
    /// user-approved, matching how archive utilities tag extracted content.
    public static let defaultFlags = "0081"

    private let agentName: String
    private let flags: String
    private let now: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID

    public init(
        agentName: String = "XZIP",
        flags: String = LivePublicationQuarantine.defaultFlags,
        now: @escaping @Sendable () -> Date = { Date() },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.agentName = agentName
        self.flags = flags
        self.now = now
        self.uuidProvider = uuidProvider
    }

    /// Builds the `com.apple.quarantine` attribute value:
    /// `flags;hexTimestamp;agentName;UUID` (seconds since 1970 in lowercase hex).
    public static func quarantineValue(
        flags: String,
        timestamp: Date,
        agentName: String,
        uuid: UUID
    ) -> Data {
        let seconds = UInt64(max(0, timestamp.timeIntervalSince1970))
        let hexTime = String(seconds, radix: 16)
        return Data("\(flags);\(hexTime);\(agentName);\(uuid.uuidString)".utf8)
    }

    public func apply(
        to entries: [QuarantineManifestEntry],
        stagingRoot: URL,
        stagingRootIdentity: FileNodeIdentity,
        fileSystem: any FileSystemOperations
    ) throws {
        let value = Self.quarantineValue(
            flags: flags,
            timestamp: now(),
            agentName: agentName,
            uuid: uuidProvider()
        )

        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: stagingRoot,
            expected: stagingRootIdentity
        )
        defer { root.close() }

        for entry in entries {
            let components = entry.relativePath
                .split(separator: "/")
                .map(String.init)
            guard let name = components.last else { continue }
            let parent = try fileSystem.openRelativeDirectoryNoFollow(
                root: root,
                components: Array(components.dropLast()),
                expected: nil
            )
            defer { parent.close() }

            if entry.kind == .directory {
                // Open the directory no-follow and set the attribute on the
                // directory fd itself (isDirectory-following open is avoided).
                let directory = try fileSystem.openDirectoryNoFollow(
                    parent: parent,
                    name: name,
                    expected: entry.identity
                )
                defer { directory.close() }
                try fileSystem.setExtendedAttribute(
                    on: directory,
                    expected: entry.identity,
                    key: Self.attributeKey,
                    value: value
                )
            } else {
                // Regular files and symlinks: no-follow set on the node itself;
                // for a symlink this uses O_SYMLINK and never touches the target.
                try fileSystem.setExtendedAttributeNoFollow(
                    parent: parent,
                    name: name,
                    expected: entry.identity,
                    key: Self.attributeKey,
                    value: value
                )
            }
        }
    }
}
