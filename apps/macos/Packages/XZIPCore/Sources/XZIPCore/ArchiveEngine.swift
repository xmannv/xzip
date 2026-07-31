import Darwin
import Foundation
import XZIPDomain

/// Progress emitted during a long-running archive operation.
///
/// Design: Observer pattern payload. Engines publish these via an
/// `AsyncStream`; UI observes without knowing which engine produced them.
public struct ArchiveProgress: Sendable, Equatable {
    /// Fraction complete in 0...1, or nil when indeterminate.
    public let fraction: Double?
    /// Name of the entry currently being processed, if known.
    public let currentEntry: String?

    public init(fraction: Double?, currentEntry: String? = nil) {
        self.fraction = fraction
        self.currentEntry = currentEntry
    }

    public static let indeterminate = ArchiveProgress(fraction: nil)
}

/// A single entry listed inside an archive.
public struct ArchiveEntry: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let modificationDate: Date?
    public let isDirectory: Bool
    public let isEncrypted: Bool

    public init(
        path: String,
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        modificationDate: Date?,
        isDirectory: Bool,
        isEncrypted: Bool
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }
}


public struct ArchiveListingResult: Sendable, Equatable {
    public let entries: [ArchiveEntry]
    public let truncated: Bool

    public init(entries: [ArchiveEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// Options controlling a compression operation.
///
/// Design: a parameter object (avoids telescoping initializers) that also acts
/// as the serializable core of a Preset later on.
public struct CompressionOptions: Sendable, Equatable, Codable {
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String?
    public var encryptFileNames: Bool
    /// Split volume size in bytes; nil = single file.
    public var volumeSize: UInt64?
    /// Glob patterns to exclude (e.g. ".DS_Store", "__MACOSX").
    public var exclusionPatterns: [String]
    /// Store file modification timestamps in the archive. Defaults to true;
    /// only 7z honours turning this off (`-mtm=off`), zip always stores mtime.
    public var preserveTimestamps: Bool
    /// Defines how a concrete engine handles an existing output path.
    public var existingFilePolicy: ExistingFilePolicy
    /// Runtime-resolved identity that staged publication must remain bound to.
    public var destinationParentIdentity: FileSystemIdentity?

    public init(
        format: ArchiveFormat,
        level: CompressionLevel = .normal,
        password: String? = nil,
        encryptFileNames: Bool = true,
        volumeSize: UInt64? = nil,
        exclusionPatterns: [String] = [],
        preserveTimestamps: Bool = true,
        existingFilePolicy: ExistingFilePolicy = .replace,
        destinationParentIdentity: FileSystemIdentity? = nil
    ) {
        self.format = format
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.volumeSize = volumeSize
        self.exclusionPatterns = exclusionPatterns
        self.preserveTimestamps = preserveTimestamps
        self.existingFilePolicy = existingFilePolicy
        self.destinationParentIdentity = destinationParentIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case level
        case password
        case encryptFileNames
        case volumeSize
        case exclusionPatterns
        case preserveTimestamps
        case existingFilePolicy
        case destinationParentIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ArchiveFormat.self, forKey: .format)
        level = try container.decode(CompressionLevel.self, forKey: .level)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        encryptFileNames = try container.decode(Bool.self, forKey: .encryptFileNames)
        volumeSize = try container.decodeIfPresent(UInt64.self, forKey: .volumeSize)
        exclusionPatterns = try container.decode([String].self, forKey: .exclusionPatterns)
        preserveTimestamps = try container.decode(Bool.self, forKey: .preserveTimestamps)
        existingFilePolicy = try container.decodeIfPresent(
            ExistingFilePolicy.self,
            forKey: .existingFilePolicy
        ) ?? .replace
        destinationParentIdentity = try container.decodeIfPresent(
            FileSystemIdentity.self,
            forKey: .destinationParentIdentity
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(level, forKey: .level)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encode(encryptFileNames, forKey: .encryptFileNames)
        try container.encodeIfPresent(volumeSize, forKey: .volumeSize)
        try container.encode(exclusionPatterns, forKey: .exclusionPatterns)
        try container.encode(preserveTimestamps, forKey: .preserveTimestamps)
        try container.encode(existingFilePolicy, forKey: .existingFilePolicy)
        try container.encodeIfPresent(
            destinationParentIdentity,
            forKey: .destinationParentIdentity
        )
    }
}

/// Options controlling an extraction operation.
public enum ExistingFilePolicy: String, Sendable, Equatable, Codable {
    case replace
    case keepBoth
    case skip
    case fail
}


enum AtomicDestinationInstaller {
    final class DestinationParentHandle: @unchecked Sendable {
        fileprivate let descriptor: Int32
        fileprivate let directory: URL
        fileprivate let identity: FileSystemIdentity

        fileprivate init(
            descriptor: Int32,
            directory: URL,
            identity: FileSystemIdentity
        ) {
            self.descriptor = descriptor
            self.directory = directory
            self.identity = identity
        }

        deinit {
            close(descriptor)
        }
    }

    final class DestinationRootHandle: @unchecked Sendable {
        fileprivate let descriptor: Int32
        fileprivate let destination: URL
        fileprivate let name: String
        fileprivate let identity: FileSystemIdentity

        fileprivate init(
            descriptor: Int32,
            destination: URL,
            name: String,
            identity: FileSystemIdentity
        ) {
            self.descriptor = descriptor
            self.destination = destination
            self.name = name
            self.identity = identity
        }

        deinit {
            close(descriptor)
        }
    }

    private static var supportedRenameFlags: UInt32 {
        if #available(macOS 26.0, *) {
            return renameFlags(resolveBeneathAvailable: true)
        }
        return renameFlags(resolveBeneathAvailable: false)
    }

    static func renameFlags(resolveBeneathAvailable: Bool) -> UInt32 {
        // The resolve-beneath flag is 0x20, but its SDK declaration only exists
        // starting with macOS 26. Single-component validation preserves the
        // confinement invariant on older systems.
        UInt32(RENAME_EXCL) | (resolveBeneathAvailable ? 0x20 : 0)
    }

    static func prepareDestinationParent(
        for destination: URL,
        expectedIdentity: FileSystemIdentity?
    ) throws -> DestinationParentHandle {
        let directory = destination.standardizedFileURL.deletingLastPathComponent()
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Open destination parent",
                path: directory.path,
                code: code
            )
        }

        do {
            let identity = try verifiedDirectoryIdentity(
                descriptor: descriptor,
                path: directory.path,
                namespaceFailure: .archiveChanged
            )
            if let expectedIdentity, identity != expectedIdentity {
                throw ArchiveFailure.archiveChanged
            }
            return DestinationParentHandle(
                descriptor: descriptor,
                directory: directory,
                identity: identity
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func prepareDestinationRoot(
        for destination: URL,
        expectedIdentity: FileSystemIdentity?,
        destinationParent: DestinationParentHandle
    ) throws -> DestinationRootHandle? {
        guard let expectedIdentity else { return nil }
        let standardizedDestination = destination.standardizedFileURL
        try validateDestinationParent(
            of: standardizedDestination,
            matches: destinationParent
        )
        let name = standardizedDestination.lastPathComponent
        guard isValidName(name) else {
            throw ArchiveEngineError.engineFailure(
                "Invalid destination root name."
            )
        }

        var pathInfo = stat()
        guard fstatat(
            destinationParent.descriptor,
            name,
            &pathInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Inspect destination root",
                path: standardizedDestination.path,
                code: code
            )
        }
        guard isDirectory(pathInfo),
              try identity(from: pathInfo, path: standardizedDestination.path)
                == expectedIdentity else {
            throw ArchiveFailure.archiveChanged
        }

        let descriptor = openat(
            destinationParent.descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Open destination root",
                path: standardizedDestination.path,
                code: code
            )
        }

        do {
            let openedIdentity = try verifiedDirectoryIdentity(
                descriptor: descriptor,
                path: standardizedDestination.path,
                namespaceFailure: .archiveChanged
            )
            guard openedIdentity == expectedIdentity else {
                throw ArchiveFailure.archiveChanged
            }
            return DestinationRootHandle(
                descriptor: descriptor,
                destination: standardizedDestination,
                name: name,
                identity: expectedIdentity
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func installItem(
        at source: URL,
        to destination: URL,
        destinationParent: DestinationParentHandle
    ) throws {
        try validateDestinationParentNamespace(destinationParent)
        let standardizedDestination = destination.standardizedFileURL
        try validateDestinationParent(
            of: standardizedDestination,
            matches: destinationParent
        )

        let sourceParent = source.deletingLastPathComponent()
        let sourceParentFD = try openSourceDirectory(sourceParent)
        defer { close(sourceParentFD) }

        try installEntry(
            sourceParentFD: sourceParentFD,
            sourceName: source.lastPathComponent,
            sourceURL: source,
            destinationParentFD: destinationParent.descriptor,
            destinationName: standardizedDestination.lastPathComponent,
            destinationURL: standardizedDestination,
            allowsDirectoryMerge: false
        )
    }

    static func installDirectoryTree(
        at source: URL,
        to destination: URL,
        destinationParent: DestinationParentHandle,
        destinationRoot: DestinationRootHandle?
    ) throws {
        try validateDestinationParentNamespace(destinationParent)
        let standardizedDestination = destination.standardizedFileURL
        try validateDestinationParent(
            of: standardizedDestination,
            matches: destinationParent
        )

        guard let destinationRoot else {
            let sourceParent = source.deletingLastPathComponent()
            let sourceParentFD = try openSourceDirectory(sourceParent)
            defer { close(sourceParentFD) }
            try installEntry(
                sourceParentFD: sourceParentFD,
                sourceName: source.lastPathComponent,
                sourceURL: source,
                destinationParentFD: destinationParent.descriptor,
                destinationName: standardizedDestination.lastPathComponent,
                destinationURL: standardizedDestination,
                allowsDirectoryMerge: false
            )
            return
        }

        guard destinationRoot.destination == standardizedDestination else {
            throw ArchiveEngineError.engineFailure(
                "Destination root does not match the prepared publication handle."
            )
        }
        try validateDestinationRootNamespace(
            destinationRoot,
            destinationParent: destinationParent
        )

        let sourceParent = source.deletingLastPathComponent()
        let sourceParentFD = try openSourceDirectory(sourceParent)
        defer { close(sourceParentFD) }
        let sourceName = source.lastPathComponent
        guard isValidName(sourceName) else {
            throw ArchiveEngineError.engineFailure("Invalid staged item name.")
        }

        var sourceInfo = stat()
        guard fstatat(
            sourceParentFD,
            sourceName,
            &sourceInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixFailure(
                operation: "Inspect staged directory",
                path: source.path,
                code: errno
            )
        }
        guard isDirectory(sourceInfo) else {
            throw ArchiveEngineError.engineFailure(
                "Staged extraction root is not a directory."
            )
        }
        let sourceIdentity = try identity(from: sourceInfo, path: source.path)
        let sourceRootFD = openat(
            sourceParentFD,
            sourceName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceRootFD >= 0 else {
            throw posixFailure(
                operation: "Open staged extraction root",
                path: source.path,
                code: errno
            )
        }
        defer { close(sourceRootFD) }
        let openedSourceIdentity = try verifiedDirectoryIdentity(
            descriptor: sourceRootFD,
            path: source.path,
            namespaceFailure: nil
        )
        guard openedSourceIdentity == sourceIdentity else {
            throw ArchiveEngineError.engineFailure(
                "Staged extraction root changed before publication."
            )
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            try installEntry(
                sourceParentFD: sourceRootFD,
                sourceName: child.lastPathComponent,
                sourceURL: child,
                destinationParentFD: destinationRoot.descriptor,
                destinationName: child.lastPathComponent,
                destinationURL: standardizedDestination.appendingPathComponent(
                    child.lastPathComponent
                ),
                allowsDirectoryMerge: true
            )
        }

        if unlinkat(sourceParentFD, sourceName, AT_REMOVEDIR) != 0 {
            throw posixFailure(
                operation: "Remove empty staged extraction root",
                path: source.path,
                code: errno
            )
        }
    }

    private static func validateDestinationParentNamespace(
        _ handle: DestinationParentHandle
    ) throws {
        let descriptor = open(
            handle.directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Reopen destination parent",
                path: handle.directory.path,
                code: code
            )
        }
        defer { close(descriptor) }

        let currentIdentity = try verifiedDirectoryIdentity(
            descriptor: descriptor,
            path: handle.directory.path,
            namespaceFailure: .archiveChanged
        )
        guard currentIdentity == handle.identity else {
            throw ArchiveFailure.archiveChanged
        }
    }

    private static func validateDestinationRootNamespace(
        _ handle: DestinationRootHandle,
        destinationParent: DestinationParentHandle
    ) throws {
        var pathInfo = stat()
        guard fstatat(
            destinationParent.descriptor,
            handle.name,
            &pathInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Reinspect destination root",
                path: handle.destination.path,
                code: code
            )
        }
        guard isDirectory(pathInfo),
              try identity(from: pathInfo, path: handle.destination.path)
                == handle.identity else {
            throw ArchiveFailure.archiveChanged
        }

        let descriptor = openat(
            destinationParent.descriptor,
            handle.name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.archiveChanged
            }
            throw posixFailure(
                operation: "Reopen destination root",
                path: handle.destination.path,
                code: code
            )
        }
        defer { close(descriptor) }
        let currentIdentity = try verifiedDirectoryIdentity(
            descriptor: descriptor,
            path: handle.destination.path,
            namespaceFailure: .archiveChanged
        )
        guard currentIdentity == handle.identity else {
            throw ArchiveFailure.archiveChanged
        }
        let retainedIdentity = try verifiedDirectoryIdentity(
            descriptor: handle.descriptor,
            path: handle.destination.path,
            namespaceFailure: .archiveChanged
        )
        guard retainedIdentity == handle.identity else {
            throw ArchiveFailure.archiveChanged
        }
    }

    private static func validateDestinationParent(
        of destination: URL,
        matches handle: DestinationParentHandle
    ) throws {
        guard destination.deletingLastPathComponent() == handle.directory else {
            throw ArchiveEngineError.engineFailure(
                "Destination parent does not match the prepared publication handle."
            )
        }
    }

    private static func openSourceDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw posixFailure(
                operation: "Open staged parent",
                path: directory.path,
                code: errno
            )
        }
        do {
            _ = try verifiedDirectoryIdentity(
                descriptor: descriptor,
                path: directory.path,
                namespaceFailure: nil
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func installEntry(
        sourceParentFD: Int32,
        sourceName: String,
        sourceURL: URL,
        destinationParentFD: Int32,
        destinationName: String,
        destinationURL: URL,
        allowsDirectoryMerge: Bool
    ) throws {
        try Task.checkCancellation()
        guard isValidName(sourceName), isValidName(destinationName) else {
            throw ArchiveEngineError.engineFailure("Invalid staged item name.")
        }

        if renameatx_np(
            sourceParentFD,
            sourceName,
            destinationParentFD,
            destinationName,
            supportedRenameFlags
        ) == 0 {
            return
        }

        let renameError = errno
        guard renameError == EEXIST || renameError == ENOTEMPTY else {
            throw posixFailure(
                operation: "Atomic destination install",
                path: destinationURL.path,
                code: renameError
            )
        }
        guard allowsDirectoryMerge else {
            throw ArchiveFailure.destinationConflict(path: destinationURL.path)
        }

        var sourceInfo = stat()
        guard fstatat(
            sourceParentFD,
            sourceName,
            &sourceInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixFailure(
                operation: "Inspect staged item",
                path: sourceURL.path,
                code: errno
            )
        }
        guard isDirectory(sourceInfo) else {
            throw ArchiveFailure.destinationConflict(path: destinationURL.path)
        }
        let sourceIdentity = try identity(
            from: sourceInfo,
            path: sourceURL.path
        )

        var destinationInfo = stat()
        guard fstatat(
            destinationParentFD,
            destinationName,
            &destinationInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.destinationConflict(path: destinationURL.path)
            }
            throw posixFailure(
                operation: "Inspect destination directory",
                path: destinationURL.path,
                code: code
            )
        }
        guard isDirectory(destinationInfo) else {
            throw ArchiveFailure.destinationConflict(path: destinationURL.path)
        }
        let destinationIdentity = try identity(
            from: destinationInfo,
            path: destinationURL.path
        )

        let sourceDirectoryFD = openat(
            sourceParentFD,
            sourceName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDirectoryFD >= 0 else {
            throw posixFailure(
                operation: "Open staged directory",
                path: sourceURL.path,
                code: errno
            )
        }
        defer { close(sourceDirectoryFD) }
        let openedSourceIdentity = try verifiedDirectoryIdentity(
            descriptor: sourceDirectoryFD,
            path: sourceURL.path,
            namespaceFailure: nil
        )
        guard openedSourceIdentity == sourceIdentity else {
            throw ArchiveEngineError.engineFailure(
                "Staged directory changed before publication: \(sourceURL.path)"
            )
        }

        let destinationDirectoryFD = openat(
            destinationParentFD,
            destinationName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard destinationDirectoryFD >= 0 else {
            let code = errno
            if isNamespaceChange(code) {
                throw ArchiveFailure.destinationConflict(path: destinationURL.path)
            }
            throw posixFailure(
                operation: "Open destination directory",
                path: destinationURL.path,
                code: code
            )
        }
        defer { close(destinationDirectoryFD) }
        let openedDestinationIdentity = try verifiedDirectoryIdentity(
            descriptor: destinationDirectoryFD,
            path: destinationURL.path,
            namespaceFailure: .destinationConflict(path: destinationURL.path)
        )
        guard openedDestinationIdentity == destinationIdentity else {
            throw ArchiveFailure.destinationConflict(path: destinationURL.path)
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let name = child.lastPathComponent
            try installEntry(
                sourceParentFD: sourceDirectoryFD,
                sourceName: name,
                sourceURL: child,
                destinationParentFD: destinationDirectoryFD,
                destinationName: name,
                destinationURL: destinationURL.appendingPathComponent(name),
                allowsDirectoryMerge: true
            )
        }

        if unlinkat(sourceParentFD, sourceName, AT_REMOVEDIR) != 0 {
            throw posixFailure(
                operation: "Remove empty staged directory",
                path: sourceURL.path,
                code: errno
            )
        }
    }

    private static func verifiedDirectoryIdentity(
        descriptor: Int32,
        path: String,
        namespaceFailure: ArchiveFailure?
    ) throws -> FileSystemIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw posixFailure(
                operation: "Inspect opened directory",
                path: path,
                code: errno
            )
        }
        guard isDirectory(info) else {
            if let namespaceFailure {
                throw namespaceFailure
            }
            throw ArchiveEngineError.engineFailure(
                "Opened path is not a directory: \(path)"
            )
        }
        return try identity(from: info, path: path)
    }

    private static func identity(
        from info: stat,
        path: String
    ) throws -> FileSystemIdentity {
        guard let identity = DarwinFileSystemIdentityReader().stableIdentity(from: info) else {
            throw ArchiveEngineError.engineFailure(
                "Could not derive a stable directory identity: \(path)"
            )
        }
        return identity
    }

    private static func isNamespaceChange(_ code: Int32) -> Bool {
        code == ENOENT || code == ENOTDIR || code == ELOOP
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func posixFailure(
        operation: String,
        path: String,
        code: Int32
    ) -> ArchiveEngineError {
        ArchiveEngineError.engineFailure(
            "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        )
    }
}

public struct ExtractionOptions: Sendable, Equatable {
    public var password: String?
    /// When non-empty, only these entry paths are extracted.
    public var selectedEntries: [String]
    /// Defines how existing files at the destination are handled.
    public var existingFilePolicy: ExistingFilePolicy
    /// Runtime-resolved identity that staged publication must remain bound to.
    public var destinationParentIdentity: FileSystemIdentity?
    /// Runtime-snapshotted identity of an existing extraction destination root.
    public var destinationRootIdentity: FileSystemIdentity?
    /// A listing the caller already has for this exact archive revision. When
    /// set, the engine reuses it for the zip-slip guard instead of re-listing
    /// the whole archive — every selective extract (Quick Look, drag-out) would
    /// otherwise spawn a fresh full `7zz l` first. Must correspond to the
    /// current file (callers key it by modification date).
    public var precomputedEntries: [ArchiveEntry]?

    /// Backward-compatible view of the legacy two-state option.
    public var overwrite: Bool {
        get { existingFilePolicy == .replace }
        set { existingFilePolicy = newValue ? .replace : .keepBoth }
    }

    public init(
        password: String? = nil,
        selectedEntries: [String] = [],
        overwrite: Bool = false,
        precomputedEntries: [ArchiveEntry]? = nil,
        destinationParentIdentity: FileSystemIdentity? = nil,
        destinationRootIdentity: FileSystemIdentity? = nil
    ) {
        self.password = password
        self.selectedEntries = selectedEntries
        self.existingFilePolicy = overwrite ? .replace : .keepBoth
        self.destinationParentIdentity = destinationParentIdentity
        self.destinationRootIdentity = destinationRootIdentity
        self.precomputedEntries = precomputedEntries
    }

    public init(
        password: String? = nil,
        selectedEntries: [String] = [],
        existingFilePolicy: ExistingFilePolicy,
        precomputedEntries: [ArchiveEntry]? = nil,
        destinationParentIdentity: FileSystemIdentity? = nil,
        destinationRootIdentity: FileSystemIdentity? = nil
    ) {
        self.password = password
        self.selectedEntries = selectedEntries
        self.existingFilePolicy = existingFilePolicy
        self.destinationParentIdentity = destinationParentIdentity
        self.destinationRootIdentity = destinationRootIdentity
        self.precomputedEntries = precomputedEntries
    }
}

/// Errors surfaced by archive engines.
public enum ArchiveEngineError: Error, LocalizedError, Sendable {
    case unsupportedFormat(ArchiveFormat)
    case unsupportedArchive(filename: String)
    case passwordRequired
    case wrongPassword
    case corruptedArchive(String)
    case pathTraversalDetected(String)
    case unsupportedEntryName(entry: String, reason: String)
    case engineFailure(String)
    /// Entries were named explicitly for extraction but are not present in the
    /// archive or on its mounted volume.
    case missingSelectedEntries(entries: [String])

    public var errorDescription: String? {
        switch self {
        // Localized via the host app's string catalog (Bundle.main). XZIPCore
        // ships no resource bundle so app-extensions can link it cleanly; hosts
        // without the keys (e.g. QuickLook) fall back to the English source.
        case .unsupportedFormat(let f):
            return String(localized: "Unsupported format: \(f.displayName)", bundle: .main)
        case .unsupportedArchive(let filename):
            return String(localized: "Unsupported archive: \(filename)", bundle: .main)
        case .passwordRequired:
            return String(localized: "This archive is password protected.", bundle: .main)
        case .wrongPassword:
            return String(localized: "Incorrect password.", bundle: .main)
        case .corruptedArchive(let d):
            return String(localized: "Archive appears to be corrupted: \(d)", bundle: .main)
        case .pathTraversalDetected(let p):
            return String(localized: "Unsafe entry path blocked: \(p)", bundle: .main)
        case .unsupportedEntryName(let entry, let reason):
            return String(localized: "Unsupported entry name: \(entry). \(reason)", bundle: .main)
        case .engineFailure(let d):
            return d
        case .missingSelectedEntries(let entries):
            return String(
                localized: "These items are no longer in the archive: \(entries.joined(separator: ", "))",
                bundle: .main
            )
        }
    }
}

/// Strategy interface implemented by each compression backend.
///
/// Design: the Strategy pattern. `ArchiveEngineFactory` selects a concrete
/// engine per format, so callers (ViewModels, extensions) program to this
/// protocol and remain decoupled from 7-Zip, libarchive, etc.
public protocol ArchiveStagingExtracting: Sendable {
    func freshExtractionInventory(
        archive: URL,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory

    func extractToEmptyStagingDirectory(
        archive: URL,
        destination: URL,
        selectedEntries: [String],
        authority: StagingWriteAuthority,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error>
}

public protocol ArchiveEngine: Sendable {
    /// Formats this engine can handle.
    var supportedFormats: Set<ArchiveFormat> { get }

    /// Compress `sources` into `destination` using `options`, streaming progress.
    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error>

    /// Extract `archive` into `destination`, streaming progress.
    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error>

    /// List entries without extracting. `password` may be required for
    /// header-encrypted archives.
    func list(archive: URL, password: String?) async throws -> [ArchiveEntry]

    /// List at most `limit` entries and report whether more entries exist.
    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult

    /// Test integrity without extracting. Returns true if the archive is intact.
    func test(archive: URL, password: String?) async throws -> Bool

    /// Prove `password` can actually decrypt `archive`, throwing
    /// `.wrongPassword` / `.passwordRequired` when it cannot.
    ///
    /// A successful listing is NOT proof: for the common case of encrypted data
    /// behind a plaintext header (`7z a -p`, ZIP, RAR without `-hp`), `list`
    /// succeeds without any password at all. Treating that as a verdict let a
    /// wrong password be accepted and saved to the Keychain.
    func verifyPassword(archive: URL, password: String?) async throws

    /// The archive-level comment, or "" if the format has none. Read-only for
    /// most engines; a requirement (not just an extension) so the concrete
    /// engine's override is dynamically dispatched through `any ArchiveEngine`.
    func readComment(archive: URL, password: String?) async throws -> String
}

public extension ArchiveEngine {
    /// Default: no comment support (e.g. DMG).
    func readComment(archive: URL, password: String?) async throws -> String { "" }

    /// Default: fall back to a full integrity test, which also exercises
    /// decryption. Engines able to check a single entry should override this —
    /// testing a multi-gigabyte archive to validate a password is wasteful.
    func verifyPassword(archive: URL, password: String?) async throws {
        _ = try await test(archive: archive, password: password)
    }
}
