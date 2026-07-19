import Foundation

/// Pure, state-free logic backing the archive browser + queue (round-2 features).
///
/// Design: `AppModel` is `@MainActor`, depends on `ArchiveService` (Keychain,
/// process runner), and can't be cheaply instantiated in a unit test. Extracting
/// the deterministic logic here — folder scoping, breadcrumbs, ETA, saved-ratio —
/// makes each piece trivially testable in isolation while `AppModel` stays a thin
/// coordinator that delegates to these functions.
enum ArchiveBrowsing {

    /// Direct children of `currentFolderPath` within `entries` (mockup 1b).
    ///
    /// Paths may be absolute ("/a/b") or relative ("a/b"); a leading slash is
    /// normalized away. A "direct child" has no further path separator after the
    /// current prefix (a trailing slash on a folder entry is tolerated). If the
    /// archive has no directory structure and we're at the root, the flat list is
    /// returned unchanged.
    static func visibleEntries(
        _ entries: [ArchiveEntry],
        currentFolderPath: String
    ) -> [ArchiveEntry] {
        let prefix = currentFolderPath.isEmpty ? "" : currentFolderPath + "/"
        let scoped = entries.filter { entry in
            let p = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
            guard p.hasPrefix(prefix) else { return false }
            let remainder = String(p.dropFirst(prefix.count))
            return !remainder.isEmpty && !remainder.dropLast().contains("/")
        }
        return scoped.isEmpty && currentFolderPath.isEmpty ? entries : scoped
    }

    /// Breadcrumb trail from the archive root to `currentFolderPath` (mockup 1b).
    /// The first crumb is the archive itself (empty path = root).
    static func breadcrumbs(
        archiveName: String,
        currentFolderPath: String
    ) -> [(name: String, path: String)] {
        var crumbs: [(name: String, path: String)] = [(archiveName, "")]
        guard !currentFolderPath.isEmpty else { return crumbs }
        var accumulated = ""
        for part in currentFolderPath.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(part) : "\(accumulated)/\(part)"
            crumbs.append((String(part), accumulated))
        }
        return crumbs
    }

    /// Human-readable "time left" from elapsed time and fraction done (mockup 3e).
    /// Returns nil when too early (<2%), already complete, or under ~1s remaining.
    static func estimateRemaining(fraction: Double, elapsed: TimeInterval) -> String? {
        guard fraction > 0.02, fraction < 1, elapsed > 0 else { return nil }
        let total = elapsed / fraction
        let remaining = max(0, total - elapsed)
        guard remaining > 1 else { return nil }
        if remaining < 60 { return String(localized: "\(Int(remaining)) s left") }
        return String(localized: "\(Int(remaining / 60)) min left")
    }

    /// Percentage saved by compression (mockup 4c). Nil when unknown; never
    /// negative (a larger output clamps to 0).
    static func savedPercent(inputBytes: Int64, outputBytes: Int64) -> Int? {
        guard inputBytes > 0, outputBytes > 0 else { return nil }
        return max(0, Int((1 - Double(outputBytes) / Double(inputBytes)) * 100))
    }

    /// Relative path of an archive entry with any leading slash removed.
    static func relativePath(_ entry: ArchiveEntry) -> String {
        entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
    }
}
