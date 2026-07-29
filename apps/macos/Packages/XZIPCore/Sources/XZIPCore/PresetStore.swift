import Foundation

/// A saved, reusable set of compression settings (BetterZip-style presets).
///
/// Design: a `Codable` value object. Combined with `CompressionOptions` it lets
/// users trigger one-click "compress as ..." actions from the app, Finder
/// extension, and Services menu.
public struct Preset: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var options: CompressionOptions
    /// Optional fixed destination directory; nil = alongside the source.
    public var destinationDirectory: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        options: CompressionOptions,
        destinationDirectory: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.options = options
        self.destinationDirectory = destinationDirectory
    }
}

/// Persists presets to disk as JSON in Application Support.
///
/// Design: the Repository pattern over a simple JSON file. Kept synchronous and
/// small; if needs grow this can be swapped for another backend without
/// touching call sites.
public final class PresetStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("XZip", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("presets.json")
        }
    }

    public func load() -> [Preset] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            // No file yet (first launch): start from the defaults.
            return Self.defaultPresets
        }
        if let presets = try? JSONDecoder().decode([Preset].self, from: data) {
            return presets
        }
        // The file exists but did not decode (corruption, or a schema change).
        // Preserve it as a `.bak` before falling back to defaults so the next
        // `save()` cannot silently overwrite and permanently destroy the user's
        // presets — they can be recovered from the backup.
        let backupURL = fileURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        return Self.defaultPresets
    }

    public func save(_ presets: [Preset]) throws {
        lock.lock(); defer { lock.unlock() }
        // Never persist a real password to disk — it belongs in the Keychain
        // (see PasswordStore), not in this JSON file. But preserve the empty-string
        // ENCRYPTION MARKER: a nil password stays nil, while any non-nil value
        // (the "" marker, or defensively a real password) is written as "" so the
        // preset's "encrypt" intent survives a reload without storing a secret.
        let sanitized = presets.map { preset -> Preset in
            var copy = preset
            copy.options.password = preset.options.password == nil ? nil : ""
            return copy
        }
        let data = try JSONEncoder().encode(sanitized)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Sensible starter presets shown on first launch.
    ///
    /// Levels here must be round-trip-stable through the UI's 4-level scale
    /// (`ModelMapping`): the UI's "Maximum" maps to core `.ultra`, so this preset
    /// stores `.ultra` (not `.maximum`, which the UI cannot represent and would
    /// silently rewrite to `.ultra` on the next load-then-save).
    public static let defaultPresets: [Preset] = [
        Preset(name: "ZIP (Normal)", options: CompressionOptions(format: .zip, level: .normal)),
        Preset(name: "7z (Maximum)", options: CompressionOptions(format: .sevenZip, level: .ultra)),
        // password: "" is the ENCRYPTION MARKER (matches ModelMapping.corePreset)
        // — it flags "encrypt" without storing a secret; the real password comes
        // from the Keychain at compress time. Without it, this preset loads with
        // encryption OFF and silently produces an UNENCRYPTED archive.
        Preset(name: "7z Encrypted", options: CompressionOptions(format: .sevenZip, level: .normal, password: "", encryptFileNames: true))
    ]
}
