import Foundation

/// Canonicalizes path components the way the local filesystem compares them, so
/// that two names macOS treats as the same file produce the same key.
///
/// APFS and HFS+ are case-insensitive by default, and their folding is wider
/// than lowercasing: verified on APFS, `straße.txt` and `strasse.txt` resolve to
/// a single inode, as do `ﬁle.txt` and `file.txt`. Any code that decides
/// "are these two paths the same destination?" has to fold at least as
/// aggressively as the filesystem does, or it will treat one file as two.
///
/// `folding(options: .caseInsensitive)` performs full Unicode case folding,
/// which covers those expansions; `lowercased()` does not. NFC normalization is
/// applied after folding so that decomposed and precomposed spellings of the
/// same characters agree.
///
/// Note this is deliberately *not* used for the staging write authority, which
/// compares archive-declared paths and must stay case-sensitive: an archive
/// containing both `A.txt` and `a.txt` describes two distinct entries, and
/// collapsing them there would hide a real conflict rather than model the
/// filesystem.
public enum FileSystemNameCanonicalization {
    /// Canonical key for a single path component.
    public static func key(component: String) -> String {
        component
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    /// Canonical key for a slash-separated relative path.
    ///
    /// Empty components are preserved so the result keeps the same shape as the
    /// input; callers validate path structure separately.
    public static func key(path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { key(component: String($0)) }
            .joined(separator: "/")
    }
}
