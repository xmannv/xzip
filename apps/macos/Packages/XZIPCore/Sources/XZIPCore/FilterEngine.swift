import Foundation

/// Decides which files to exclude when compressing (BetterZip-style filtering).
///
/// Design: a small Strategy object over a list of glob patterns. It maps to
/// 7-Zip's `-xr!` switches (handled in `SevenZipEngine`) but also offers direct
/// matching so other engines or previews can reuse the same rules.
public struct FilterEngine: Sendable {
    public let patterns: [String]

    public init(patterns: [String] = FilterEngine.macOSDefaults) {
        self.patterns = patterns
    }

    /// Common macOS/dev noise users usually don't want inside archives.
    public static let macOSDefaults = [
        ".DS_Store",
        "__MACOSX",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        "Thumbs.db"
    ]

    /// Returns true if `filename` matches any exclusion pattern.
    public func shouldExclude(_ filename: String) -> Bool {
        let name = (filename as NSString).lastPathComponent
        for pattern in patterns {
            if Self.matches(name: name, pattern: pattern) { return true }
        }
        return false
    }

    /// Minimal glob matcher supporting `*` and `?` wildcards.
    static func matches(name: String, pattern: String) -> Bool {
        if !pattern.contains("*") && !pattern.contains("?") {
            return name == pattern
        }
        // Translate the glob into a regex anchored to the whole string.
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        return name.range(of: regex, options: .regularExpression) != nil
    }
}
