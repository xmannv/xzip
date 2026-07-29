import Foundation

/// Represents an archive container format supported by XZip.
///
/// Design: a value-type enum acting as the domain model shared across engines,
/// UI, and extensions. Keeping format knowledge here (extensions, capabilities)
/// avoids scattering `switch` statements throughout the codebase.
public enum ArchiveFormat: String, CaseIterable, Sendable, Codable {
    case zip
    case sevenZip = "7z"
    case tar
    case gzip = "gz"
    case bzip2 = "bz2"
    case xz
    case zstd = "zst"
    case rar
    case dmg
    // Extract-only containers, routed through the bundled 7zz like RAR.
    case iso
    case cab
    case deb
    case rpm
    case cpio
    case lzh
    case wim
    case chm
    case arj
    case xip
    case unixCompress = "z"
    case lzma
    case udf
    case squashfs

    /// File extensions that map to this format (lowercased, no leading dot).
    public var fileExtensions: [String] {
        switch self {
        case .zip: return ["zip", "jar", "epub", "cbz"]
        case .sevenZip: return ["7z"]
        case .tar: return ["tar", "pax"]
        case .gzip: return ["gz", "gzip", "tgz"]
        case .bzip2: return ["bz2", "bzip2", "tbz", "tbz2"]
        case .xz: return ["xz", "txz"]
        case .zstd: return ["zst", "zstd", "tzst"]
        case .rar: return ["rar"]
        case .dmg: return ["dmg"]
        case .iso: return ["iso"]
        case .cab: return ["cab"]
        case .deb: return ["deb"]
        case .rpm: return ["rpm"]
        case .cpio: return ["cpio"]
        case .lzh: return ["lzh", "lha"]
        case .wim: return ["wim"]
        case .chm: return ["chm"]
        case .arj: return ["arj"]
        case .xip: return ["xip", "xar"]
        case .unixCompress: return ["z"]
        case .lzma: return ["lzma"]
        case .udf: return ["udf"]
        case .squashfs: return ["squashfs", "sqfs"]
        }
    }

    /// Human-facing display name.
    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7-Zip"
        case .tar: return "TAR"
        case .gzip: return "Gzip"
        case .bzip2: return "Bzip2"
        case .xz: return "XZ"
        case .zstd: return "Zstandard"
        case .rar: return "RAR"
        case .dmg: return "Disk Image"
        case .iso: return "ISO Image"
        case .cab: return "Cabinet"
        case .deb: return "Debian Package"
        case .rpm: return "RPM Package"
        case .cpio: return "CPIO"
        case .lzh: return "LZH"
        case .wim: return "Windows Image"
        case .chm: return "Compiled HTML Help"
        case .arj: return "ARJ"
        case .xip: return "XIP"
        case .unixCompress: return "Unix Compress"
        case .lzma: return "LZMA"
        case .udf: return "UDF Image"
        case .squashfs: return "SquashFS"
        }
    }

    /// Whether XZip can create archives in this format.
    /// RAR is extract-only due to the unRAR license; the other read-only
    /// containers are extracted through 7zz, which cannot write them.
    public var canCompress: Bool {
        switch self {
        case .zip, .sevenZip, .tar, .gzip, .bzip2, .xz, .zstd, .dmg: return true
        default: return false
        }
    }

    /// Whether `7zz a` can add files into an *existing* archive of this format
    /// in place. RAR and DMG are read-only for 7zz, and the single-stream
    /// formats (gz/bz2/xz/zst — including `.tar.gz` etc.) hold exactly one
    /// compressed payload, so 7zz reports E_NOTIMPL when asked to update them.
    public var supportsAppending: Bool {
        switch self {
        case .zip, .sevenZip, .tar: true
        default: false
        }
    }

    /// The `-t` type switch 7zz needs to (re)create an archive of this format,
    /// or nil for formats 7zz cannot write (RAR, DMG, extract-only containers).
    public var sevenZipTypeFlag: String? {
        switch self {
        case .zip: "-tzip"
        case .sevenZip: "-t7z"
        case .tar: "-ttar"
        case .gzip: "-tgzip"
        case .bzip2: "-tbzip2"
        case .xz: "-txz"
        case .zstd: "-tzstd"
        default: nil
        }
    }

    /// The single-stream codec wrapping a tar payload, when the filename names
    /// a compressed tarball (`.tar.gz`, `.tgz`, `.tar.zst`, …). Nil for plain
    /// single-file compression (`notes.txt.gz`) and for every other format.
    /// These archives can't be updated in place but can be repacked
    /// (decompress → update the tar → recompress).
    public static func tarWrapper(fromFilename filename: String) -> ArchiveFormat? {
        let lower = filename.lowercased()
        for ext in ["tgz", "tbz", "tbz2", "txz", "tzst"] where lower.hasSuffix("." + ext) {
            return infer(fromFilename: lower)
        }
        guard let format = infer(fromFilename: lower),
              format.requiresTarWrapper else { return nil }
        // `.tar.<codec-ext>` — the payload before the codec extension is a tar.
        let withoutCodecExt = (lower as NSString).deletingPathExtension
        return withoutCodecExt.hasSuffix(".tar") ? format : nil
    }

    /// Whether this format is a macOS disk image handled by `hdiutil`.
    public var isDiskImage: Bool { self == .dmg }

    /// Stream codecs require a TAR container when archiving multiple paths.
    var requiresTarWrapper: Bool {
        switch self {
        case .gzip, .bzip2, .xz, .zstd: true
        default: false
        }
    }

    /// Whether the format natively supports password-based encryption.
    public var supportsEncryption: Bool {
        switch self {
        case .zip, .sevenZip: return true
        default: return false
        }
    }

    /// Whether the format supports multi-volume splitting.
    public var supportsSplitting: Bool {
        switch self {
        case .sevenZip, .zip: return true
        default: return false
        }
    }

    /// Resolve a format from a filename, matching the longest known extension.
    public static func infer(fromFilename filename: String) -> ArchiveFormat? {
        let lower = filename.lowercased()
        // Prefer compound extensions (e.g. `.tar.gz`) by checking specific first.
        for format in ArchiveFormat.allCases {
            for ext in format.fileExtensions where lower.hasSuffix("." + ext) {
                return format
            }
        }
        return nil
    }
}

/// Compression effort level, mapped by each engine to its own scale.
///
/// Design: an engine-agnostic abstraction (Strategy inputs). Concrete engines
/// translate these into tool-specific flags, so UI never deals with raw numbers.
public enum CompressionLevel: Int, CaseIterable, Sendable, Codable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9

    public var displayName: String {
        switch self {
        case .store: return "Store (no compression)"
        case .fastest: return "Fastest"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .maximum: return "Maximum"
        case .ultra: return "Ultra"
        }
    }
}
