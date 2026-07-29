import Foundation
import XZIPCore

/// Pure, state-free logic backing the Places folder browser (mockup 2a).
///
/// Design: mirrors `ArchiveBrowsing` — deterministic, dependency-free functions
/// that read the filesystem and classify entries, kept out of `AppModel` so they
/// are trivially unit-testable. The app is NOT sandboxed, so plain `FileManager`
/// access works without security-scoped bookmarks.
enum FolderBrowsing {

    /// How to order items in the folder browser. Folders always sort before
    /// files (Finder behavior), then the chosen key is applied within each group.
    enum SortKey: Sendable {
        case name, size, kind, modified
    }

    /// A broad file-type bucket used by the folder browser's "File Type"
    /// filter. `all` shows everything; other cases narrow the listing.
    /// Classification is by filename extension (archives reuse the formats
    /// XZip can open), so it needs no disk access and stays testable.
    enum FileTypeFilter: String, CaseIterable, Sendable {
        case all, folders, archives, images, documents, media, other

        /// Menu label for the filter.
        var label: String {
            switch self {
            case .all: String(localized: "All Files")
            case .folders: String(localized: "Folders")
            case .archives: String(localized: "Archives")
            case .images: String(localized: "Images")
            case .documents: String(localized: "Documents")
            case .media: String(localized: "Audio & Video")
            case .other: String(localized: "Other")
            }
        }

        /// Whether `item` belongs to this filter's bucket.
        func matches(_ item: FileItem) -> Bool {
            switch self {
            case .all:
                return true
            case .folders:
                return item.isDirectory
            case .archives:
                return FolderBrowsing.isArchive(item)
            case .images:
                return !item.isDirectory && Self.imageExts.contains(item.ext)
            case .documents:
                return !item.isDirectory && Self.documentExts.contains(item.ext)
            case .media:
                return !item.isDirectory && Self.mediaExts.contains(item.ext)
            case .other:
                return !item.isDirectory
                    && !FolderBrowsing.isArchive(item)
                    && !Self.imageExts.contains(item.ext)
                    && !Self.documentExts.contains(item.ext)
                    && !Self.mediaExts.contains(item.ext)
            }
        }

        private static let imageExts: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp",
            "webp", "svg", "psd", "ico", "avif", "raw", "cr2", "nef", "arw", "dng"
        ]
        private static let documentExts: Set<String> = [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md",
            "rtf", "rtfd", "pages", "numbers", "key", "csv", "tsv", "json",
            "xml", "yaml", "yml", "html", "htm", "epub"
        ]
        private static let mediaExts: Set<String> = [
            "mp3", "aac", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif",
            "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "3gp"
        ]
    }

    /// List the direct contents of `folder`, skipping hidden (dot) files.
    /// Returns folders and files as `FileItem`s, throwing when the folder cannot
    /// be read so the UI can distinguish "empty" from "permission/I/O error".
    static func contentsResult(of folder: URL) throws -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
        ]
        let urls = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Resolve a symlink's target so a link to a folder is browsable as a
            // folder rather than shown (and stuck) as a file.
            let isDirectory: Bool
            if values?.isSymbolicLink == true {
                isDirectory = (try? url.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            } else {
                isDirectory = values?.isDirectory ?? false
            }
            return FileItem(
                url: url,
                isDirectory: isDirectory,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Compatibility/pure-logic wrapper: callers that intentionally treat an
    /// unreadable folder as empty (tests, non-UI probes) can keep the old shape.
    /// The app UI uses `contentsResult` and surfaces the real error.
    static func contents(of folder: URL) -> [FileItem] {
        (try? contentsResult(of: folder)) ?? []
    }

    /// Sort `items` with folders first, then by `key` (ascending). A stable,
    /// case-insensitive name comparison breaks ties.
    static func sort(_ items: [FileItem], by key: SortKey, ascending: Bool = true, foldersFirst: Bool = true) -> [FileItem] {
        items.sorted { lhs, rhs in
            // Folders stay on top regardless of direction (Finder behavior).
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            // Descending flips the comparison by swapping operands, which
            // preserves strict-weak ordering (negating would break it on ties).
            let a = ascending ? lhs : rhs
            let b = ascending ? rhs : lhs
            switch key {
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size:
                return a.sizeBytes != b.sizeBytes
                    ? a.sizeBytes < b.sizeBytes
                    : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .kind:
                return a.ext != b.ext
                    ? a.ext < b.ext
                    : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .modified:
                return a.modifiedAt != b.modifiedAt
                    ? a.modifiedAt < b.modifiedAt
                    : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Whether the item is an archive XZip can open (drives the "open" affordance).
    static func isArchive(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        return ArchiveFormat.infer(fromFilename: item.name) != nil
    }

    /// Return a name based on `desired` that doesn't collide with `existing`.
    /// If it collides, appends " 2", " 3", … before any file extension:
    /// "untitled folder" → "untitled folder 2"; "a.txt" → "a 2.txt".
    static func uniqueName(desired: String, existing: Set<String>) -> String {
        // Compare case-insensitively: APFS is case-insensitive by default, so a
        // case-sensitive Set check would hand back a name ("Photos") that still
        // collides with an existing "photos" and fail (or clobber) on disk.
        let existingLower = Set(existing.map { $0.lowercased() })
        guard existingLower.contains(desired.lowercased()) else { return desired }
        let ns = desired as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? desired : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !existingLower.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}
