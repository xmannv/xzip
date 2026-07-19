import Foundation
import XZIPCore

/// Live state of an add-files repack on a compressed tarball (tar.gz, …),
/// presented as a step-by-step progress sheet via `.sheet(item:)`.
struct RepackState: Identifiable {
    let id = UUID()
    let archiveName: String
    let fileCount: Int
    var step: RepackStep = .decompress
    var isCancelling = false
}

enum CompressionFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case zip = "ZIP"
    case sevenZip = "7Z"
    case tar = "TAR"
    case tarGzip = "TAR.GZ"
    case tarBzip2 = "TAR.BZ2"
    case tarXz = "TAR.XZ"
    case tarZstd = "TAR.ZST"
    case dmg = "DMG"

    var id: String { rawValue }

    /// The on-disk file extension for this format (e.g. `tar.gz`).
    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZstd: "tar.zst"
        case .dmg: "dmg"
        }
    }

    var supportsEncryption: Bool {
        switch self {
        case .zip, .sevenZip: true
        default: false
        }
    }

    var supportsSplitting: Bool {
        switch self {
        case .zip, .sevenZip: true
        default: false
        }
    }

    /// Common formats shown before the user expands the picker.
    static let primaryChoices: [CompressionFormat] = [.zip, .sevenZip, .tar, .dmg]

    /// TAR archives wrapped in less-common compression codecs.
    static let advancedChoices: [CompressionFormat] = [.tarGzip, .tarBzip2, .tarXz, .tarZstd]

    /// Every format offered for archive creation and persisted defaults.
    static var compressChoices: [CompressionFormat] { primaryChoices + advancedChoices }
}

enum CompressionLevel: Int, CaseIterable, Identifiable, Codable, Sendable {
    case store = 0
    case fast = 3
    case balanced = 6
    case maximum = 9

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .store: "Store"
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        }
    }
}

enum ConflictPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask = "Ask Every Time"
    case replace = "Replace"
    case keepBoth = "Keep Both"
    case skip = "Skip"
    var id: String { rawValue }
}

struct InputItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let estimatedSize: Int64

    init(id: UUID = UUID(), url: URL, estimatedSize: Int64 = 0) {
        self.id = id
        self.url = url
        self.estimatedSize = estimatedSize
    }

    var displayName: String { url.lastPathComponent }
}

enum ArchiveEntryKind: String, Codable, Sendable {
    case folder
    case file
    case image
    case source
    case document

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .file: "doc"
        case .image: "photo"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        }
    }
}

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    /// Stable identity = the in-archive path. Deriving the id from the path
    /// (instead of a fresh UUID on every listing) lets SwiftUI's Table diff
    /// across refreshes, so only changed rows update and the selection survives
    /// a re-list.
    var id: String { path }
    var name: String
    var path: String
    var kind: ArchiveEntryKind
    var originalSize: Int64
    var compressedSize: Int64
    var modifiedAt: Date

    init(
        name: String,
        path: String,
        kind: ArchiveEntryKind,
        originalSize: Int64,
        compressedSize: Int64,
        modifiedAt: Date
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.modifiedAt = modifiedAt
    }

    var ratio: Double {
        guard originalSize > 0 else { return 0 }
        return 1 - Double(compressedSize) / Double(originalSize)
    }
}

struct ArchivePreset: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var summary: String
    var format: CompressionFormat
    var level: CompressionLevel
    var encryptionEnabled: Bool
    var splitSizeMB: Int?
    var includePatterns: String
    var excludePatterns: String

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        format: CompressionFormat,
        level: CompressionLevel,
        encryptionEnabled: Bool = false,
        splitSizeMB: Int? = nil,
        includePatterns: String = "",
        excludePatterns: String = ""
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.format = format
        self.level = level
        self.encryptionEnabled = encryptionEnabled
        self.splitSizeMB = splitSizeMB
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
    }
}

enum OperationKind: String, Codable, Sendable {
    case compress
    case extract
    case test
}

/// Identifiable wrapper so a target archive URL can drive a `.popover(item:)`
/// (URL isn't Identifiable by default). Used by the comment popover (4a).
struct CommentTarget: Identifiable, Hashable, Sendable {
    let id: URL
    var url: URL { id }
    init(url: URL) { self.id = url }
}

/// Payload for the post-compress Share card (mockup 4c).
struct ShareArchiveInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let sizeBytes: Int64
    let savedPercent: Int?
    let isEncrypted: Bool

    init(id: UUID = UUID(), url: URL, sizeBytes: Int64, savedPercent: Int? = nil, isEncrypted: Bool = false) {
        self.id = id
        self.url = url
        self.sizeBytes = sizeBytes
        self.savedPercent = savedPercent
        self.isEncrypted = isEncrypted
    }
}

/// A pending file-name conflict discovered by pre-scanning an extraction
/// (mockup 3b). Resolved once, then a chosen policy applies to the whole batch.
struct ConflictPrompt: Identifiable, Sendable {
    let id: UUID
    /// The first conflicting file name (shown in the dialog title).
    let firstConflict: String
    /// Total number of conflicting files found by the pre-scan.
    let totalConflicts: Int
    /// Size + modified date of the on-disk (existing) file, if known.
    let existingSize: Int64?
    let existingModified: Date?
    /// Callback invoked with the chosen policy + whether it applies to all.
    let resolve: @Sendable (ConflictPolicy, Bool) -> Void

    init(
        id: UUID = UUID(),
        firstConflict: String,
        totalConflicts: Int,
        existingSize: Int64? = nil,
        existingModified: Date? = nil,
        resolve: @escaping @Sendable (ConflictPolicy, Bool) -> Void
    ) {
        self.id = id
        self.firstConflict = firstConflict
        self.totalConflicts = totalConflicts
        self.existingSize = existingSize
        self.existingModified = existingModified
        self.resolve = resolve
    }
}

enum OperationState: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct ArchiveOperation: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var kind: OperationKind
    var state: OperationState
    var progress: Double
    var currentItem: String
    var detail: String
    /// Result location (archive created / extraction folder) for “Reveal”.
    var outputURL: URL?

    init(
        id: UUID = UUID(),
        title: String,
        kind: OperationKind,
        state: OperationState,
        progress: Double,
        currentItem: String,
        detail: String,
        outputURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.state = state
        self.progress = progress
        self.currentItem = currentItem
        self.detail = detail
        self.outputURL = outputURL
    }
}

extension Int64 {
    var xzipFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}


enum ByteCountMath {
    static func adding(_ value: Int64, to total: Int64) -> Int64 {
        guard value > 0 else { return total }
        let (sum, overflow) = total.addingReportingOverflow(value)
        return overflow ? .max : sum
    }

    static func sum<S: Sequence>(_ values: S) -> Int64
    where S.Element == Int64 {
        values.reduce(0) { adding($1, to: $0) }
    }
}

extension ArchiveEntry {
    /// Extension used to pick a `FileTypeIcon` (empty for folders).
    var ext: String {
        kind == .folder ? "" : (name as NSString).pathExtension
    }
}

// MARK: - Sidebar models (mockup 2a)

/// A favorite destination shown in the Places sidebar section. Extraction
/// targets are resolved from a security-scoped bookmark (see `PlacesStore`).
struct Place: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    /// SF Symbol shown next to the place.
    var symbol: String

    init(id: UUID = UUID(), name: String, url: URL, symbol: String = "folder") {
        self.id = id
        self.name = name
        self.url = url
        self.symbol = symbol
    }
}

/// An archive currently open in the app, shown in the Open Archives section.
struct OpenArchive: Identifiable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var itemCount: Int
    var isEncrypted: Bool

    init(id: UUID = UUID(), url: URL, itemCount: Int = 0, isEncrypted: Bool = false) {
        self.id = id
        self.url = url
        self.itemCount = itemCount
        self.isEncrypted = isEncrypted
    }

    var name: String { url.lastPathComponent }
}

/// Drives the "New Folder / New File" name-entry sheet. `Identifiable` so it can
/// be presented via `.sheet(item:)`.
struct NewItemRequest: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case folder, file }
    let id = UUID()
    let kind: Kind

    /// Default name pre-filled in the sheet's text field.
    var defaultName: String {
        switch kind {
        case .folder: String(localized: "untitled folder")
        case .file: String(localized: "untitled file")
        }
    }

    var title: String {
        switch kind {
        case .folder: String(localized: "New Folder")
        case .file: String(localized: "New File")
        }
    }
}

/// A file or folder on disk shown in the Places folder browser (mockup 2a).
///
/// Distinct from `ArchiveEntry`, which represents an item *inside* an archive.
/// `FileItem` represents a real item in the user's filesystem while browsing a
/// favorite folder (BetterZip-style Finder view).
struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedAt: Date

    var name: String { url.lastPathComponent }

    /// Lowercased path extension ("" for folders / extensionless files).
    var ext: String { url.pathExtension.lowercased() }
}
