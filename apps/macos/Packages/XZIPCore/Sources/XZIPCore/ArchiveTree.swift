import Foundation

/// A node in a hierarchical view of an archive's contents.
///
/// Design: transforms the flat `[ArchiveEntry]` returned by engines into a tree
/// the browser UI can render (folders containing files/subfolders). Kept as a
/// pure value type in Core so it is testable without any UI and reusable by the
/// Quick Look extension.
public struct ArchiveNode: Identifiable, Sendable, Equatable {
    public let id: String        // Full path within the archive.
    public let name: String      // Last path component.
    public let isDirectory: Bool
    public let entry: ArchiveEntry?  // nil for synthesized intermediate folders.
    public var children: [ArchiveNode]

    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        entry: ArchiveEntry?,
        children: [ArchiveNode] = []
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.entry = entry
        self.children = children
    }

    /// Total uncompressed size of this node and its descendants.
    public var totalSize: UInt64 {
        if isDirectory {
            return children.reduce(0) { $0 + $1.totalSize }
        }
        // A non-directory node should have no children; if a malformed archive
        // ever produces one (a file and a folder sharing a name), count them too
        // so a directory's size is never silently under-reported.
        let childrenSize = children.reduce(0) { $0 + $1.totalSize }
        return (entry?.uncompressedSize ?? 0) + childrenSize
    }
}

/// Builds an `ArchiveNode` tree from flat archive entries.
///
/// Design: a stateless builder (pure function). Intermediate directories that
/// aren't explicitly listed are synthesized so the tree is always complete.
public enum ArchiveTreeBuilder {
    public static func build(from entries: [ArchiveEntry]) -> [ArchiveNode] {
        // Mutable tree represented with reference nodes during construction,
        // then frozen into value types.
        final class MutableNode {
            let id: String
            let name: String
            var isDirectory: Bool
            var entry: ArchiveEntry?
            var children: [String: MutableNode] = [:]
            init(id: String, name: String, isDirectory: Bool, entry: ArchiveEntry?) {
                self.id = id
                self.name = name
                self.isDirectory = isDirectory
                self.entry = entry
            }
        }

        let root = MutableNode(id: "", name: "", isDirectory: true, entry: nil)

        for entry in entries {
            let components = entry.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }

            var current = root
            var accumulatedPath = ""
            for (index, component) in components.enumerated() {
                accumulatedPath = accumulatedPath.isEmpty
                    ? component
                    : accumulatedPath + "/" + component
                let isLeaf = index == components.count - 1

                if let existing = current.children[component] {
                    if isLeaf && !entry.isDirectory {
                        // A leaf file entry clarifies this is a file — but only
                        // adopt it if no children have attached yet. If a folder
                        // of the same name already has contents (e.g. "foo/bar"
                        // arrived first), keep it a directory; demoting it to a
                        // file would orphan its children from totalSize.
                        if existing.children.isEmpty {
                            existing.entry = entry
                            existing.isDirectory = entry.isDirectory
                        }
                    } else if !isLeaf && !existing.isDirectory {
                        // A path like "foo/bar" arriving after a file entry "foo"
                        // proves "foo" is really a directory; promote it so its
                        // children aren't attached to a file node.
                        existing.isDirectory = true
                        existing.entry = nil
                    }
                    current = existing
                } else {
                    let node = MutableNode(
                        id: accumulatedPath,
                        name: component,
                        isDirectory: isLeaf ? entry.isDirectory : true,
                        entry: isLeaf ? entry : nil
                    )
                    current.children[component] = node
                    current = node
                }
            }
        }

        func freeze(_ node: MutableNode) -> ArchiveNode {
            let kids = node.children.values
                .map(freeze)
                .sorted { lhs, rhs in
                    // Directories first, then case-insensitive name order.
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return ArchiveNode(
                id: node.id, name: node.name,
                isDirectory: node.isDirectory, entry: node.entry, children: kids
            )
        }

        return root.children.values
            .map(freeze)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
