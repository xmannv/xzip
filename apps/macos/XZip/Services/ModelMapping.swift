import Foundation
import XZIPCore

/// Pure conversions between the kit's UI models and `XZIPCore` domain models.
///
/// Design: an Anti-Corruption Layer. The design-kit UI and the backend evolved
/// independently and even share type *names* (`ArchiveEntry`, `CompressionLevel`).
/// Centralizing every translation here keeps the UI code untouched and the
/// backend pristine — if either side changes, only this file needs updating.
/// All functions are pure and therefore unit-testable without any engine.
enum ModelMapping {

    // MARK: - Format (UI -> Core)

    static func coreFormat(from format: CompressionFormat) -> XZIPCore.ArchiveFormat {
        switch format {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tarGzip: return .gzip
        case .tarBzip2: return .bzip2
        case .tarXz: return .xz
        case .tarZstd: return .zstd
        case .dmg: return .dmg
        }
    }

    // MARK: - Level (UI -> Core)

    static func coreLevel(from level: CompressionLevel) -> XZIPCore.CompressionLevel {
        switch level {
        case .store: return .store
        case .fast: return .fast
        case .balanced: return .normal
        case .maximum: return .ultra
        }
    }

    // MARK: - Compression options (UI -> Core)

    /// Build `CompressionOptions` from the app model's current draft settings.
    static func compressionOptions(
        format: CompressionFormat,
        level: CompressionLevel,
        password: String?,
        splitSizeMB: Int?,
        excludeMacNoise: Bool,
        preserveTimestamps: Bool = true
    ) -> CompressionOptions {
        CompressionOptions(
            format: coreFormat(from: format),
            level: coreLevel(from: level),
            password: format.supportsEncryption && password?.isEmpty == false ? password : nil,
            encryptFileNames: format.supportsEncryption,
            volumeSize: format.supportsSplitting
                ? splitSizeMB.map { UInt64($0) * 1_000_000 }
                : nil,
            // hdiutil has no exclusion switch; the Compress sheet disables this
            // option for DMG, and the mapping enforces the same invariant for
            // non-UI callers so a visible/default-ON setting is never silently
            // claimed to work.
            exclusionPatterns: excludeMacNoise && format != .dmg
                ? FilterEngine.macOSDefaults : [],
            preserveTimestamps: preserveTimestamps
        )
    }

    // MARK: - Entry (Core -> UI)

    static func uiEntry(from entry: XZIPCore.ArchiveEntry) -> ArchiveEntry {
        ArchiveEntry(
            name: (entry.path as NSString).lastPathComponent,
            path: entry.path,
            kind: entryKind(for: entry),
            originalSize: Int64(clamping: entry.uncompressedSize),
            compressedSize: Int64(clamping: entry.compressedSize),
            modifiedAt: entry.modificationDate ?? Date()
        )
    }

    static func uiEntries(from entries: [XZIPCore.ArchiveEntry]) -> [ArchiveEntry] {
        let mapped = entries.map(uiEntry(from:))
        // Synthesize any intermediate folders that have no explicit entry, so the
        // browser can navigate into them. Many archives store only file entries
        // (no directory records), which would otherwise leave nested files
        // unreachable (a file "a/b/c.txt" is not a direct child of the root).
        var known = Set(mapped.map { relativePath($0.path) })
        var synthesized: [ArchiveEntry] = []
        // Synthesize ancestors for EVERY entry (not just files): an archive that
        // records an empty nested folder ("a/b/") without its parent ("a/") would
        // otherwise leave "a" un-synthesized, hiding the whole branch from the
        // browser.
        for entry in mapped {
            let parts = relativePath(entry.path).split(separator: "/").dropLast()
            var accumulated = ""
            for part in parts {
                accumulated = accumulated.isEmpty ? String(part) : "\(accumulated)/\(part)"
                if known.insert(accumulated).inserted {
                    synthesized.append(ArchiveEntry(
                        name: String(part), path: accumulated, kind: .folder,
                        originalSize: 0, compressedSize: 0, modifiedAt: Date()))
                }
            }
        }
        return mapped + synthesized
    }

    /// In-archive path with any leading slash removed.
    private static func relativePath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// Classify an entry for its SF Symbol, based on directory flag/extension.
    static func entryKind(for entry: XZIPCore.ArchiveEntry) -> ArchiveEntryKind {
        if entry.isDirectory { return .folder }
        let ext = (entry.path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp":
            return .image
        case "swift", "js", "ts", "py", "c", "cpp", "h", "java", "rb", "go", "rs", "json", "xml", "yml", "yaml":
            return .source
        case "txt", "md", "rtf", "pdf", "doc", "docx", "pages":
            return .document
        default:
            return .file
        }
    }

    // MARK: - Preset (Core <-> UI)

    static func uiPreset(from preset: Preset) -> ArchivePreset {
        let format = uiFormat(from: preset.options.format)
        return ArchivePreset(
            id: preset.id,
            name: preset.name,
            summary: presetSummary(for: preset.options),
            format: format,
            level: uiLevel(from: preset.options.level),
            encryptionEnabled: format.supportsEncryption && preset.options.password != nil,
            splitSizeMB: format.supportsSplitting
                ? preset.options.volumeSize.map { Int($0 / 1_000_000) }
                : nil,
            excludePatterns: preset.options.exclusionPatterns.joined(separator: ", ")
        )
    }

    /// Split a comma/newline-separated pattern string into trimmed globs.
    private static func parsePatterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Convert a UI preset back into a persistable Core `Preset`.
    ///
    /// Note: the encryption flag is preserved as a non-empty placeholder marker;
    /// the real password is never stored in the preset file (it lives in the
    /// Keychain). `SevenZipEngine` only encrypts when a password is supplied at
    /// compression time, so an empty-string marker here is intentional.
    static func corePreset(from preset: ArchivePreset) -> Preset {
        Preset(
            id: preset.id,
            name: preset.name,
            options: CompressionOptions(
                format: coreFormat(from: preset.format),
                level: coreLevel(from: preset.level),
                password: preset.format.supportsEncryption && preset.encryptionEnabled ? "" : nil,
                encryptFileNames: preset.format.supportsEncryption,
                volumeSize: preset.format.supportsSplitting
                    ? preset.splitSizeMB.map { UInt64($0) * 1_000_000 }
                    : nil,
                exclusionPatterns: parsePatterns(preset.excludePatterns)
            )
        )
    }

    /// Best-effort UI format for a core format (UI has fewer cases).
    static func uiFormat(from format: XZIPCore.ArchiveFormat) -> CompressionFormat {
        switch format {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .gzip: return .tarGzip
        case .bzip2: return .tarBzip2
        case .xz: return .tarXz
        case .zstd: return .tarZstd
        case .dmg: return .dmg
        // RAR and the extract-only 7zz containers have no UI compress case.
        default: return .zip
        }
    }

    static func uiLevel(from level: XZIPCore.CompressionLevel) -> CompressionLevel {
        switch level {
        case .store: return .store
        case .fastest, .fast: return .fast
        case .normal: return .balanced
        case .maximum, .ultra: return .maximum
        }
    }

    private static func presetSummary(for options: CompressionOptions) -> String {
        var parts = [options.format.displayName, options.level.displayName]
        if options.password != nil { parts.append(String(localized: "Encrypted")) }
        if options.volumeSize != nil { parts.append(String(localized: "Split")) }
        return parts.joined(separator: " · ")
    }
}
