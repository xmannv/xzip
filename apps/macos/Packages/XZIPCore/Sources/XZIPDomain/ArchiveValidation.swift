import Foundation

public enum ArchiveNameValidationError: Error, LocalizedError, Equatable, Sendable {
    case emptyComponent
    case reservedComponent(String)
    case containsPathSeparator(String)
    case containsNUL(String)
    case containsLineBreak(String)
    case unsafeRelativePath(String)
    case escapesParent(parent: URL, candidate: URL)

    public var errorDescription: String? {
        switch self {
        case .emptyComponent:
            return "The name cannot be empty."
        case .reservedComponent(let component):
            return "The name \(component) is reserved."
        case .containsPathSeparator(let component):
            return "The name contains a path separator: \(component)"
        case .containsNUL(let value):
            return "The name contains NUL: \(value)"
        case .containsLineBreak(let value):
            return "The name contains a line break: \(value)"
        case .unsafeRelativePath(let path):
            return "The relative path is unsafe: \(path)"
        case .escapesParent(let parent, let candidate):
            return "The path \(candidate.path) escapes \(parent.path)."
        }
    }
}

public enum ArchiveComponentValidator {
    @discardableResult
    public static func validate(_ component: String) throws -> String {
        if component.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw ArchiveNameValidationError.containsNUL(component)
        }
        if component.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) {
            throw ArchiveNameValidationError.containsLineBreak(component)
        }
        if component.contains("/") {
            throw ArchiveNameValidationError.containsPathSeparator(component)
        }
        if component.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ArchiveNameValidationError.emptyComponent
        }
        if component == "." || component == ".." {
            throw ArchiveNameValidationError.reservedComponent(component)
        }
        return component
    }
}

public enum ArchiveListFileValidator {
    public static func validate(entries: [String]) throws {
        for entry in entries {
            if entry.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw ArchiveNameValidationError.containsNUL(entry)
            }
            if entry.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) {
                throw ArchiveNameValidationError.containsLineBreak(entry)
            }
        }
    }
}

public enum ArchivePathContainment {
    public static func childURL(parent: URL, component: String) throws -> URL {
        let validated = try ArchiveComponentValidator.validate(component)
        let standardizedParent = parent.standardizedFileURL
        let candidate = standardizedParent
            .appendingPathComponent(validated)
            .standardizedFileURL

        guard candidate.deletingLastPathComponent().standardizedFileURL == standardizedParent else {
            throw ArchiveNameValidationError.escapesParent(
                parent: standardizedParent,
                candidate: candidate
            )
        }
        return candidate
    }

    public static func descendantDirectoryURL(
        root: URL,
        relativePath: String
    ) throws -> URL {
        var directory = root.standardizedFileURL
        guard !relativePath.isEmpty else { return directory }

        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for component in components {
            guard !component.isEmpty else {
                throw ArchiveNameValidationError.unsafeRelativePath(relativePath)
            }
            do {
                let child = try childURL(
                    parent: directory,
                    component: String(component)
                )
                directory = URL(
                    fileURLWithPath: child.path,
                    isDirectory: true
                ).standardizedFileURL
            } catch {
                throw ArchiveNameValidationError.unsafeRelativePath(relativePath)
            }
        }
        return directory
    }
}
