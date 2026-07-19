import Foundation

/// Locates bundled command-line binaries (7zz, zstd, ...).
///
/// Design: Strategy via protocol so tests can inject a locator pointing at a
/// dev checkout's `Resources/bin`, while the app uses the one inside the
/// application bundle. Keeps engines free of path-resolution concerns.
public protocol BinaryLocating: Sendable {
    /// Absolute path to the named binary, or nil if it cannot be found.
    func path(for binary: BundledBinary) -> String?
}

/// Known bundled binaries.
public enum BundledBinary: String, Sendable, CaseIterable {
    case sevenZip = "7zz"
    case zstd
    case brotli
    case xz
}

/// Errors related to binary resolution.
public enum BinaryLocatorError: Error, LocalizedError, Sendable {
    case notFound(BundledBinary)

    public var errorDescription: String? {
        switch self {
        case .notFound(let bin):
            return "Required binary '\(bin.rawValue)' was not found."
        }
    }
}

/// Default locator that searches a list of candidate directories in order.
///
/// The app injects its bundle's `Resources/bin`; tests inject the repo's
/// `Resources/bin`. Falls back to `$PATH` lookup as a last resort.
public struct BinaryLocator: BinaryLocating {
    private let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories
    }

    public func path(for binary: BundledBinary) -> String? {
        // `FileManager.default` is not held as stored state because it is not
        // `Sendable`; it is safe to use transiently for read-only queries.
        let fileManager = FileManager.default
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(binary.rawValue)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
