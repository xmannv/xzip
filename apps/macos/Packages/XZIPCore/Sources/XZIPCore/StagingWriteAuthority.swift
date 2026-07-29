import Foundation
import XZIPDomain

/// Core-owned, Runtime-independent staging write authority.
///
/// This value reproduces the exact normalized path/kind authority that
/// `ExtractionTransaction` derives via `makeManifest` and enforces via
/// `validateStaging`, but without depending on `XZIPRuntime`. A concrete
/// staging extractor (e.g. `SevenZipEngine`) consults it to write ONLY the
/// authorized nodes into an empty private staging directory: every written
/// node must match an authorized `(relativePath, kind)` pair, and every
/// parent directory it creates must be an authorized directory. Anything the
/// archive attempts to write outside this set (an extra file, a traversal
/// path, a kind swap) is unauthorized and must be refused before the write.
///
/// Paths are NFC-normalized per component (matching the transaction's
/// `precomposedStringWithCanonicalMapping`) so the authority compares equal
/// regardless of the caller's Unicode normalization form.
public struct StagingWriteAuthority: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// NFC-normalized relative path (no leading slash, no empty/`.`/`..`).
        public let relativePath: String
        public let kind: ExtractionNodeKind

        public init(relativePath: String, kind: ExtractionNodeKind) {
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    /// Authorized entries sorted by relative path (same ordering the durable
    /// cleanup manifest uses).
    public let entries: [Entry]
    private let kindByPath: [String: ExtractionNodeKind]

    private init(entries: [Entry]) {
        self.entries = entries
        self.kindByPath = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.relativePath, $0.kind) }
        )
    }

    /// Every authorized relative path (explicit entries + implicit parents).
    public var authorizedPaths: Set<String> {
        Set(kindByPath.keys)
    }

    /// Derives the write authority from a validated extraction inventory. The
    /// authorized set is the union of the inventory's implicit parent
    /// directories (as directories) and every explicit entry's own kind, with
    /// explicit entries overriding an implicit directory of the same path.
    ///
    /// Throws if any path is absolute or contains an empty, `.`, `..`, or
    /// otherwise invalid component.
    public static func fromInventory(
        _ inventory: ExtractionInventory
    ) throws -> StagingWriteAuthority {
        var kinds: [String: ExtractionNodeKind] = [:]
        for path in inventory.implicitDirectories {
            kinds[try normalize(path)] = .directory
        }
        for entry in inventory.entries {
            kinds[try normalize(entry.path)] = entry.kind
        }
        let entries = kinds
            .map { Entry(relativePath: $0.key, kind: $0.value) }
            .sorted { $0.relativePath < $1.relativePath }
        return StagingWriteAuthority(entries: entries)
    }

    /// Derives the write authority from an already-authorized entry set, such
    /// as the durable `StagingCleanupManifest` the transaction persists. Unlike
    /// `fromInventory`, no implicit-directory union is performed: the manifest
    /// is already the complete authorized set (it was itself built from a
    /// unioned inventory). Each entry's path is NFC-normalized and validated
    /// (rejecting absolute, empty, `.`, or `..` components).
    ///
    /// The input is expected to be unique by normalized path (the transaction's
    /// `StagingCleanupManifest` is keyed by path, so it always is). Exact
    /// duplicates (same path AND kind) collapse silently; a conflicting kind for
    /// the same normalized path is rejected rather than resolved by array order,
    /// so the resulting authority never depends on caller ordering.
    ///
    /// This is the Runtime-independent bridge a live `ArchiveExtractionBackend`
    /// adapter uses to turn the transaction's `StagingCleanupManifest` into the
    /// authority the Core staging extractor enforces.
    public static func fromAuthorizedEntries(
        _ entries: [Entry]
    ) throws -> StagingWriteAuthority {
        var kinds: [String: ExtractionNodeKind] = [:]
        for entry in entries {
            let path = try normalize(entry.relativePath)
            if let existing = kinds[path], existing != entry.kind {
                throw ArchiveNameValidationError.unsafeRelativePath(entry.relativePath)
            }
            kinds[path] = entry.kind
        }
        let normalized = kinds
            .map { Entry(relativePath: $0.key, kind: $0.value) }
            .sorted { $0.relativePath < $1.relativePath }
        return StagingWriteAuthority(entries: normalized)
    }

    /// Whether writing a node of exactly `kind` at `relativePath` is
    /// authorized. The query path is NFC-normalized before comparison; an
    /// invalid path (absolute, traversal, empty component) is never authorized.
    public func isAuthorized(relativePath: String, kind: ExtractionNodeKind) -> Bool {
        guard let normalized = try? Self.normalize(relativePath) else { return false }
        return kindByPath[normalized] == kind
    }

    /// Whether `relativePath` is an authorized directory into which children
    /// may be created. The empty path denotes the staging root, which is always
    /// writable.
    public func authorizedDirectory(_ relativePath: String) -> Bool {
        if relativePath.isEmpty { return true }
        guard let normalized = try? Self.normalize(relativePath) else { return false }
        return kindByPath[normalized] == .directory
    }

    private static func normalize(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ArchiveNameValidationError.unsafeRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw ArchiveNameValidationError.unsafeRelativePath(path)
        }
        return try components
            .map { component in
                try ArchiveComponentValidator.validate(String(component))
                    .precomposedStringWithCanonicalMapping
            }
            .joined(separator: "/")
    }
}
