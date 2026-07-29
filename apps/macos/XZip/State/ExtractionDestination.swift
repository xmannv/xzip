import Foundation

/// Where an archive's contents go when the user names a destination *folder*
/// rather than a destination for the contents themselves.
///
/// Pure path arithmetic, kept in one place because it was previously inlined at
/// six call sites and had already drifted: extracting from Finder or via
/// "Extract All" created a folder named after the archive, while extracting to a
/// Place, to a Downloads/Desktop chip, or to a folder picked from the panel
/// unpacked straight into the target. A hundred-entry archive dropped on Desktop
/// that way scatters a hundred loose items into it, and undoing that by hand is
/// miserable.
///
/// Wrapping always is also what Finder does with its own Archive Utility, so it
/// is the behaviour users already expect.
enum ExtractionDestination {

    /// The folder to extract `archive` into, inside `parent`.
    ///
    /// Named after the archive with its extension removed. Multi-part extensions
    /// only lose the last component (`.tar.gz` → `foo.tar`), matching how the rest
    /// of the app derives display names; it keeps `foo.tar` recognisable rather
    /// than inventing a rule that disagrees elsewhere.
    static func folder(for archive: URL, in parent: URL) -> URL {
        parent.appendingPathComponent(baseName(of: archive), isDirectory: true)
    }

    /// The folder to extract `archive` into, alongside the archive itself.
    static func folderBesideArchive(_ archive: URL) -> URL {
        folder(for: archive, in: archive.deletingLastPathComponent())
    }

    /// The archive's name without its extension, never empty.
    ///
    /// A dotfile-style name like `.hidden.zip` reduces to `.hidden`, and a bare
    /// `.zip` would reduce to the empty string — which would make
    /// `appendingPathComponent` return the parent itself and extract loose into
    /// it, the exact failure this type exists to prevent. Such names fall back to
    /// the full file name.
    static func baseName(of archive: URL) -> String {
        let stripped = archive.deletingPathExtension().lastPathComponent
        return stripped.isEmpty ? archive.lastPathComponent : stripped
    }
}
