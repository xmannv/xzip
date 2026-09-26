import Foundation
import XZIPCore

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

    /// Whether the entry is a nested archive XZip can open (drives double-click
    /// opening it in the archive browser instead of Quick Look, mirroring
    /// `FolderBrowsing.isArchive` for on-disk files).
    static func isArchive(_ entry: ArchiveEntry) -> Bool {
        guard entry.kind != .folder else { return false }
        return ArchiveFormat.infer(fromFilename: entry.name) != nil
    }

    // MARK: - Rows shown in the archive table

    /// Which column the archive table is sorted by.
    ///
    /// A plain `Sendable` enum rather than the table's `KeyPathComparator`, so the
    /// sort can run off the main actor — same reason `FolderBrowsing.SortKey`
    /// exists. "Kind" is absent because that column is not sortable.
    enum SortKey: Sendable {
        case name, size, modified
    }

    /// The rows to display: filtered, then sorted, then optionally partitioned so
    /// folders sit above files.
    ///
    /// Pure and `Sendable` in and out, so a caller can hand it to `Task.detached`.
    /// On a 100k-entry listing this is a localized comparison per pair, which is
    /// far too slow to sit on the main actor.
    ///
    /// While `search` is non-empty it matches across the whole archive, ignoring
    /// `currentFolderPath` — searching is expected to look past the current folder.
    static func rows(
        _ entries: [ArchiveEntry],
        search: String,
        currentFolderPath: String,
        key: SortKey,
        ascending: Bool,
        foldersFirst: Bool
    ) -> [ArchiveEntry] {
        let base = search.isEmpty
            ? visibleEntries(entries, currentFolderPath: currentFolderPath)
            : entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return sort(base, by: key, ascending: ascending, foldersFirst: foldersFirst)
    }

    /// Sort `entries` by `key`, with folders hoisted when `foldersFirst`.
    static func sort(
        _ entries: [ArchiveEntry],
        by key: SortKey,
        ascending: Bool,
        foldersFirst: Bool
    ) -> [ArchiveEntry] {
        entries.sorted { lhs, rhs in
            // Folders stay on top whichever way the column points (Finder
            // behaviour), matching `FolderBrowsing.sort`.
            if foldersFirst, (lhs.kind == .folder) != (rhs.kind == .folder) {
                return lhs.kind == .folder
            }
            // Descending swaps the operands rather than negating the result. With
            // the total order below the two are equivalent; swapping is kept
            // because it stays correct if a future key does allow ties.
            let a = ascending ? lhs : rhs
            let b = ascending ? rhs : lhs
            switch key {
            case .name:
                return before(a, b) { _, _ in nil }
            case .size:
                return before(a, b) { l, r in
                    l.originalSize == r.originalSize ? nil : l.originalSize < r.originalSize
                }
            case .modified:
                return before(a, b) { l, r in
                    l.modifiedAt == r.modifiedAt ? nil : l.modifiedAt < r.modifiedAt
                }
            }
        }
    }

    /// Whether `a` sorts before `b`, given a primary comparison that returns nil
    /// when the two are equal on that key.
    ///
    /// Ties fall through to name, then to `path`. Because `path` is unique within
    /// an archive, the resulting order is total: no two distinct entries ever
    /// compare equal. That matters for what the user sees — `sorted(by:)` promises
    /// nothing about the arrangement of elements it considers equal, so without a
    /// final unique key the row order of same-named files would be at the mercy of
    /// the standard library's implementation and could change between runs.
    private static func before(
        _ a: ArchiveEntry,
        _ b: ArchiveEntry,
        by primary: (ArchiveEntry, ArchiveEntry) -> Bool?
    ) -> Bool {
        if let decided = primary(a, b) { return decided }
        switch a.name.localizedCaseInsensitiveCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.path < b.path
        }
    }
}
