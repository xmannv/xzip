import Foundation

/// Progress emitted during a long-running archive operation.
///
/// Design: Observer pattern payload. Engines publish these via an
/// `AsyncStream`; UI observes without knowing which engine produced them.
public struct ArchiveProgress: Sendable, Equatable {
    /// Fraction complete in 0...1, or nil when indeterminate.
    public let fraction: Double?
    /// Name of the entry currently being processed, if known.
    public let currentEntry: String?

    public init(fraction: Double?, currentEntry: String? = nil) {
        self.fraction = fraction
        self.currentEntry = currentEntry
    }

    public static let indeterminate = ArchiveProgress(fraction: nil)
}

/// A single entry listed inside an archive.
public struct ArchiveEntry: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let modificationDate: Date?
    public let isDirectory: Bool
    public let isEncrypted: Bool

    public init(
        path: String,
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        modificationDate: Date?,
        isDirectory: Bool,
        isEncrypted: Bool
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }
}


public struct ArchiveListingResult: Sendable, Equatable {
    public let entries: [ArchiveEntry]
    public let truncated: Bool

    public init(entries: [ArchiveEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// Options controlling a compression operation.
///
/// Design: a parameter object (avoids telescoping initializers) that also acts
/// as the serializable core of a Preset later on.
public struct CompressionOptions: Sendable, Equatable, Codable {
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String?
    public var encryptFileNames: Bool
    /// Split volume size in bytes; nil = single file.
    public var volumeSize: UInt64?
    /// Glob patterns to exclude (e.g. ".DS_Store", "__MACOSX").
    public var exclusionPatterns: [String]
    /// Store file modification timestamps in the archive. Defaults to true;
    /// only 7z honours turning this off (`-mtm=off`), zip always stores mtime.
    public var preserveTimestamps: Bool

    public init(
        format: ArchiveFormat,
        level: CompressionLevel = .normal,
        password: String? = nil,
        encryptFileNames: Bool = true,
        volumeSize: UInt64? = nil,
        exclusionPatterns: [String] = [],
        preserveTimestamps: Bool = true
    ) {
        self.format = format
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.volumeSize = volumeSize
        self.exclusionPatterns = exclusionPatterns
        self.preserveTimestamps = preserveTimestamps
    }
}

/// Options controlling an extraction operation.
public enum ExistingFilePolicy: Sendable, Equatable {
    case replace
    case keepBoth
    case skip
}

public struct ExtractionOptions: Sendable, Equatable {
    public var password: String?
    /// When non-empty, only these entry paths are extracted.
    public var selectedEntries: [String]
    /// Defines how existing files at the destination are handled.
    public var existingFilePolicy: ExistingFilePolicy
    /// A listing the caller already has for this exact archive revision. When
    /// set, the engine reuses it for the zip-slip guard instead of re-listing
    /// the whole archive — every selective extract (Quick Look, drag-out) would
    /// otherwise spawn a fresh full `7zz l` first. Must correspond to the
    /// current file (callers key it by modification date).
    public var precomputedEntries: [ArchiveEntry]?

    /// Backward-compatible view of the legacy two-state option.
    public var overwrite: Bool {
        get { existingFilePolicy == .replace }
        set { existingFilePolicy = newValue ? .replace : .keepBoth }
    }

    public init(
        password: String? = nil,
        selectedEntries: [String] = [],
        overwrite: Bool = false,
        precomputedEntries: [ArchiveEntry]? = nil
    ) {
        self.password = password
        self.selectedEntries = selectedEntries
        self.existingFilePolicy = overwrite ? .replace : .keepBoth
        self.precomputedEntries = precomputedEntries
    }

    public init(
        password: String? = nil,
        selectedEntries: [String] = [],
        existingFilePolicy: ExistingFilePolicy,
        precomputedEntries: [ArchiveEntry]? = nil
    ) {
        self.password = password
        self.selectedEntries = selectedEntries
        self.existingFilePolicy = existingFilePolicy
        self.precomputedEntries = precomputedEntries
    }
}

/// Errors surfaced by archive engines.
public enum ArchiveEngineError: Error, LocalizedError, Sendable {
    case unsupportedFormat(ArchiveFormat)
    case passwordRequired
    case wrongPassword
    case corruptedArchive(String)
    case pathTraversalDetected(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        // Localized via the host app's string catalog (Bundle.main). XZIPCore
        // ships no resource bundle so app-extensions can link it cleanly; hosts
        // without the keys (e.g. QuickLook) fall back to the English source.
        case .unsupportedFormat(let f):
            return String(localized: "Unsupported format: \(f.displayName)", bundle: .main)
        case .passwordRequired:
            return String(localized: "This archive is password protected.", bundle: .main)
        case .wrongPassword:
            return String(localized: "Incorrect password.", bundle: .main)
        case .corruptedArchive(let d):
            return String(localized: "Archive appears to be corrupted: \(d)", bundle: .main)
        case .pathTraversalDetected(let p):
            return String(localized: "Unsafe entry path blocked: \(p)", bundle: .main)
        case .engineFailure(let d):
            return d
        }
    }
}

/// Strategy interface implemented by each compression backend.
///
/// Design: the Strategy pattern. `ArchiveEngineFactory` selects a concrete
/// engine per format, so callers (ViewModels, extensions) program to this
/// protocol and remain decoupled from 7-Zip, libarchive, etc.
public protocol ArchiveEngine: Sendable {
    /// Formats this engine can handle.
    var supportedFormats: Set<ArchiveFormat> { get }

    /// Compress `sources` into `destination` using `options`, streaming progress.
    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error>

    /// Extract `archive` into `destination`, streaming progress.
    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error>

    /// List entries without extracting. `password` may be required for
    /// header-encrypted archives.
    func list(archive: URL, password: String?) async throws -> [ArchiveEntry]

    /// List at most `limit` entries and report whether more entries exist.
    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult

    /// Test integrity without extracting. Returns true if the archive is intact.
    func test(archive: URL, password: String?) async throws -> Bool

    /// The archive-level comment, or "" if the format has none. Read-only for
    /// most engines; a requirement (not just an extension) so the concrete
    /// engine's override is dynamically dispatched through `any ArchiveEngine`.
    func readComment(archive: URL, password: String?) async throws -> String
}

public extension ArchiveEngine {
    /// Default: no comment support (e.g. DMG).
    func readComment(archive: URL, password: String?) async throws -> String { "" }
}
