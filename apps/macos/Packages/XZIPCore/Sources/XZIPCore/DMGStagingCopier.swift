import Darwin
import Foundation
import XZIPDomain

protocol DirectoryNodeEnumerating: Sendable {
    func forEachNode(
        in directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws
}

private struct FileSystemDirectoryNodeEnumerator: DirectoryNodeEnumerating {
    let fileSystem: any FileSystemOperations

    func forEachNode(
        in directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws {
        try fileSystem.forEachNodeNoFollow(directory, body)
    }
}

struct DMGStagingCopier: Sendable {
    let fileSystem: any FileSystemOperations & FileTimestampOperations
    private let nodeEnumerator: any DirectoryNodeEnumerating

    init(fileSystem: any FileSystemOperations & FileTimestampOperations) {
        self.fileSystem = fileSystem
        nodeEnumerator = FileSystemDirectoryNodeEnumerator(fileSystem: fileSystem)
    }

    init(
        fileSystem: any FileSystemOperations & FileTimestampOperations,
        nodeEnumerator: any DirectoryNodeEnumerating
    ) {
        self.fileSystem = fileSystem
        self.nodeEnumerator = nodeEnumerator
    }

    private struct ResolvedNode: Sendable {
        let relativePath: String
        let components: [String]
        let node: FileNode
    }

    private struct Resolution: Sendable {
        let explicitNodes: [ResolvedNode]
        let copyNodes: [ResolvedNode]
    }

    func inventory(
        mountPoint: URL,
        selectedEntries: [String],
        policy: ArchiveResourcePolicy
    ) throws -> ExtractionInventory {
        let resolution = try resolve(
            mountPoint: mountPoint,
            selectedEntries: selectedEntries,
            policy: policy
        )
        let entries = try resolution.explicitNodes.map { resolved in
            switch resolved.node.identity.kind {
            case .regularFile:
                return ExtractionInventoryEntry(
                    path: resolved.relativePath,
                    kind: .regularFile,
                    size: resolved.node.byteCount,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            case .directory:
                return ExtractionInventoryEntry(
                    path: resolved.relativePath,
                    kind: .directory,
                    size: 0,
                    linkTarget: nil,
                    isExplicitDirectory: true
                )
            case .symbolicLink:
                return ExtractionInventoryEntry(
                    path: resolved.relativePath,
                    kind: .symbolicLink,
                    size: 0,
                    linkTarget: resolved.node.linkTarget,
                    isExplicitDirectory: false
                )
            case .hardLink, .fifo, .socket, .blockDevice, .characterDevice, .unknown:
                throw ExtractionInventoryError.unsupportedNode(
                    path: resolved.relativePath,
                    kind: resolved.node.identity.kind
                )
            }
        }
        return try ExtractionInventory.validated(
            entries: entries,
            advertisedDictionaryByteCount: 0,
            policy: policy
        )
    }

    func copy(
        mountPoint: URL,
        destination: URL,
        selectedEntries: [String],
        authority: StagingWriteAuthority,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy
    ) throws {
        let resolution = try resolve(
            mountPoint: mountPoint,
            selectedEntries: selectedEntries,
            policy: policy
        )
        let sourceRoot = try fileSystem.openDirectoryNoFollow(at: mountPoint)
        defer { sourceRoot.close() }
        let destinationRoot = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationRoot.close() }
        guard try fileSystem.listNoFollow(destinationRoot).isEmpty else {
            throw ArchiveEngineError.engineFailure("Staging directory is not empty.")
        }

        let sourceDirectoryIdentities = Dictionary(
            uniqueKeysWithValues: resolution.copyNodes.compactMap { resolved in
                resolved.node.identity.kind == .directory
                    ? (resolved.relativePath, resolved.node.identity)
                    : nil
            }
        )
        var destinationDirectoryIdentities: [String: FileNodeIdentity] = [:]
        var stagingBytes: UInt64 = 0
        var createdDirectories: [ResolvedNode] = []

        for resolved in resolution.copyNodes {
            try Task.checkCancellation()
            let kind = resolved.node.identity.kind
            guard Self.isSupported(kind) else {
                throw ExtractionInventoryError.unsupportedNode(
                    path: resolved.relativePath,
                    kind: kind
                )
            }
            guard authority.isAuthorized(
                relativePath: resolved.relativePath,
                kind: kind
            ) else {
                throw ArchiveEngineError.engineFailure(
                    "Staged entry is not authorized: \(resolved.relativePath)"
                )
            }
            let parentPath = resolved.components.dropLast().joined(separator: "/")
            guard authority.authorizedDirectory(parentPath) else {
                throw ArchiveEngineError.engineFailure(
                    "Staged parent is not authorized: \(parentPath)"
                )
            }

            stagingBytes = try StagingByteAccounting.adding(
                current: stagingBytes,
                logical: resolved.node.byteCount,
                allocated: resolved.node.allocatedByteCount,
                limit: policy.output.stagingByteCap
            )

            let sourceParent = try openVerifiedDirectory(
                root: sourceRoot,
                components: Array(resolved.components.dropLast()),
                identities: sourceDirectoryIdentities
            )
            defer { sourceParent.close() }
            let destinationParent = try openVerifiedDirectory(
                root: destinationRoot,
                components: Array(resolved.components.dropLast()),
                identities: destinationDirectoryIdentities
            )
            defer { destinationParent.close() }
            let name = resolved.components[resolved.components.count - 1]

            switch kind {
            case .directory:
                try requireSourceIdentity(resolved, parent: sourceParent)
                let identity = try fileSystem.createDirectoryExclusive(
                    parent: destinationParent,
                    name: name
                )
                destinationDirectoryIdentities[resolved.relativePath] = identity
                createdDirectories.append(resolved)
            case .regularFile:
                try copyRegularFile(
                    resolved,
                    sourceParent: sourceParent,
                    destinationParent: destinationParent,
                    preserveTimestamps: preserveTimestamps
                )
            case .symbolicLink:
                try copySymbolicLink(
                    resolved,
                    sourceParent: sourceParent,
                    destinationParent: destinationParent,
                    preserveTimestamps: preserveTimestamps
                )
            case .hardLink, .fifo, .socket, .blockDevice, .characterDevice, .unknown:
                preconditionFailure("Unsupported kind was checked above.")
            }
        }

        guard preserveTimestamps else { return }
        for resolved in createdDirectories.reversed() {
            try Task.checkCancellation()
            let sourceParent = try openVerifiedDirectory(
                root: sourceRoot,
                components: Array(resolved.components.dropLast()),
                identities: sourceDirectoryIdentities
            )
            defer { sourceParent.close() }
            try requireSourceIdentity(resolved, parent: sourceParent)

            let destinationParent = try openVerifiedDirectory(
                root: destinationRoot,
                components: Array(resolved.components.dropLast()),
                identities: destinationDirectoryIdentities
            )
            defer { destinationParent.close() }
            try applyTimestamps(
                resolved,
                destinationParent: destinationParent
            )
        }
    }

    private func resolve(
        mountPoint: URL,
        selectedEntries: [String],
        policy: ArchiveResourcePolicy
    ) throws -> Resolution {
        let selections = try selectedEntries.map(Self.validatedComponents)
        let root = try fileSystem.openDirectoryNoFollow(at: mountPoint)
        defer { root.close() }
        var explicitByPath: [String: ResolvedNode] = [:]
        var copyByPath: [String: ResolvedNode] = [:]
        var explicitEntryCount = 0
        var totalPathByteCount = 0

        func accountExplicitPath(
            _ path: String,
            components: [String]
        ) throws {
            guard explicitByPath[path] == nil else { return }
            guard explicitEntryCount < policy.listing.listingHardCap else {
                throw ExtractionInventoryError.entryCountExceeded(
                    limit: policy.listing.listingHardCap
                )
            }
            guard components.count <= policy.listing.maximumPathDepth else {
                throw ExtractionInventoryError.pathDepthExceeded(
                    path: path,
                    limit: policy.listing.maximumPathDepth
                )
            }
            let pathByteCount = path.utf8.count
            guard pathByteCount <= policy.listing.maximumPathByteCount else {
                throw ExtractionInventoryError.pathByteCountExceeded(
                    path: path,
                    limit: policy.listing.maximumPathByteCount
                )
            }
            let (nextTotalPathByteCount, overflow) = totalPathByteCount
                .addingReportingOverflow(pathByteCount)
            guard !overflow,
                  nextTotalPathByteCount <= policy.listing.totalPathByteCap
            else {
                throw ExtractionInventoryError.totalPathByteCountExceeded(
                    limit: policy.listing.totalPathByteCap
                )
            }
            explicitEntryCount += 1
            totalPathByteCount = nextTotalPathByteCount
        }

        func add(
            path: String,
            components: [String],
            node: FileNode,
            explicit: Bool
        ) throws {
            if explicit {
                try accountExplicitPath(path, components: components)
            }
            let resolved = ResolvedNode(
                relativePath: path,
                components: components,
                node: node
            )
            copyByPath[path] = resolved
            if explicit { explicitByPath[path] = resolved }
        }

        func walk(
            directory: DirectoryHandle,
            parentComponents: [String]
        ) throws {
            try nodeEnumerator.forEachNode(in: directory) { child in
                try Task.checkCancellation()
                let components = parentComponents + [child.name]
                let path = components.joined(separator: "/")
                try add(
                    path: path,
                    components: components,
                    node: child,
                    explicit: true
                )
                guard child.identity.kind == .directory else { return }
                let childDirectory = try fileSystem.openDirectoryNoFollow(
                    parent: directory,
                    name: child.name,
                    expected: child.identity
                )
                defer { childDirectory.close() }
                try walk(directory: childDirectory, parentComponents: components)
            }
        }

        if selections.isEmpty {
            try walk(directory: root, parentComponents: [])
        } else {
            var missing: [String] = []
            for components in selections {
                try Task.checkCancellation()
                let selectedPath = components.joined(separator: "/")
                var current = try fileSystem.openRelativeDirectoryNoFollow(
                    root: root,
                    components: [],
                    expected: nil
                )
                var selectionMissing = false
                defer { current.close() }

                for depth in 0..<max(0, components.count - 1) {
                    let component = components[depth]
                    guard let ancestor = try fileSystem.statNoFollow(
                        parent: current,
                        name: component
                    ) else {
                        selectionMissing = true
                        break
                    }
                    let ancestorComponents = Array(components.prefix(depth + 1))
                    let ancestorPath = ancestorComponents.joined(separator: "/")
                    switch ancestor.identity.kind {
                    case .directory:
                        try add(
                            path: ancestorPath,
                            components: ancestorComponents,
                            node: ancestor,
                            explicit: false
                        )
                    case .symbolicLink:
                        throw ExtractionInventoryError.symlinkParent(ancestorPath)
                    default:
                        throw ExtractionInventoryError.nonDirectoryParent(ancestorPath)
                    }
                    let next = try fileSystem.openDirectoryNoFollow(
                        parent: current,
                        name: component,
                        expected: ancestor.identity
                    )
                    current.close()
                    current = next
                }

                if selectionMissing {
                    missing.append(selectedPath)
                    continue
                }
                let name = components[components.count - 1]
                guard let selected = try fileSystem.statNoFollow(parent: current, name: name) else {
                    missing.append(selectedPath)
                    continue
                }
                try add(
                    path: selectedPath,
                    components: components,
                    node: selected,
                    explicit: true
                )
                if selected.identity.kind == .directory {
                    let selectedDirectory = try fileSystem.openDirectoryNoFollow(
                        parent: current,
                        name: name,
                        expected: selected.identity
                    )
                    defer { selectedDirectory.close() }
                    try walk(directory: selectedDirectory, parentComponents: components)
                }
            }
            guard missing.isEmpty else {
                throw ArchiveEngineError.missingSelectedEntries(entries: missing)
            }
        }

        let explicitNodes = explicitByPath.values.sorted { $0.relativePath < $1.relativePath }
        let copyNodes = copyByPath.values.sorted {
            if $0.components.count != $1.components.count {
                return $0.components.count < $1.components.count
            }
            return $0.relativePath < $1.relativePath
        }
        return Resolution(explicitNodes: explicitNodes, copyNodes: copyNodes)
    }

    private func openVerifiedDirectory(
        root: DirectoryHandle,
        components: [String],
        identities: [String: FileNodeIdentity]
    ) throws -> DirectoryHandle {
        var current = try fileSystem.openRelativeDirectoryNoFollow(
            root: root,
            components: [],
            expected: nil
        )
        do {
            var pathComponents: [String] = []
            for component in components {
                pathComponents.append(component)
                let path = pathComponents.joined(separator: "/")
                guard let expected = identities[path] else {
                    throw ArchiveEngineError.engineFailure(
                        "Missing directory identity: \(path)"
                    )
                }
                let next = try fileSystem.openDirectoryNoFollow(
                    parent: current,
                    name: component,
                    expected: expected
                )
                current.close()
                current = next
            }
            return current
        } catch {
            current.close()
            throw error
        }
    }

    private func requireSourceIdentity(
        _ resolved: ResolvedNode,
        parent: DirectoryHandle
    ) throws {
        let name = resolved.components[resolved.components.count - 1]
        let actual = try fileSystem.statNoFollow(parent: parent, name: name)?.identity
        guard actual == resolved.node.identity else {
            throw FileSystemOperationError.identityMismatch(
                expected: resolved.node.identity,
                actual: actual
            )
        }
    }

    private func copyRegularFile(
        _ resolved: ResolvedNode,
        sourceParent: DirectoryHandle,
        destinationParent: DirectoryHandle,
        preserveTimestamps: Bool
    ) throws {
        let name = resolved.components[resolved.components.count - 1]
        let source = try fileSystem.openRegularFileNoFollow(
            parent: sourceParent,
            name: name,
            expected: resolved.node.identity,
            access: .readOnly
        )
        defer { source.close() }
        let destination = try createRegularFileExclusive(
            parent: destinationParent,
            name: name
        )
        defer { destination.close() }

        while true {
            try Task.checkCancellation()
            let bytes = try source.read(upToCount: 64 * 1_024)
            if bytes.isEmpty { break }
            try destination.write(bytes)
        }
        try destination.fsync()
        destination.close()
        if preserveTimestamps {
            try applyTimestamps(resolved, destinationParent: destinationParent)
        }
    }

    private func copySymbolicLink(
        _ resolved: ResolvedNode,
        sourceParent: DirectoryHandle,
        destinationParent: DirectoryHandle,
        preserveTimestamps: Bool
    ) throws {
        try requireSourceIdentity(resolved, parent: sourceParent)
        let name = resolved.components[resolved.components.count - 1]
        guard let target = resolved.node.linkTarget else {
            throw ArchiveEngineError.engineFailure(
                "Symbolic link has no target: \(resolved.relativePath)"
            )
        }
        try destinationParent.withFileDescriptor { descriptor in
            guard symlinkat(target, descriptor, name) == 0 else {
                throw Self.posixError("symlinkat")
            }
        }
        if preserveTimestamps {
            try applyTimestamps(resolved, destinationParent: destinationParent)
        }
    }

    private func applyTimestamps(
        _ resolved: ResolvedNode,
        destinationParent: DirectoryHandle
    ) throws {
        guard let timestamps = resolved.node.timestamps else { return }
        let name = resolved.components[resolved.components.count - 1]
        guard let destination = try fileSystem.statNoFollow(
            parent: destinationParent,
            name: name
        ) else {
            throw FileSystemOperationError.identityMismatch(
                expected: resolved.node.identity,
                actual: nil
            )
        }
        try fileSystem.setTimestampsNoFollow(
            parent: destinationParent,
            name: name,
            expected: destination.identity,
            timestamps: timestamps
        )
    }

    private func createRegularFileExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DurableFileHandle {
        try parent.withFileDescriptor { descriptor in
            let fileDescriptor = Darwin.openat(
                descriptor,
                name,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard fileDescriptor >= 0 else {
                if errno == EEXIST {
                    throw FileSystemOperationError.alreadyExists(name)
                }
                throw Self.posixError("openat")
            }
            do {
                guard fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
                    throw Self.posixError("fchmod")
                }
                var metadata = stat()
                guard fstat(fileDescriptor, &metadata) == 0 else {
                    throw Self.posixError("fstat")
                }
                guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                    throw FileSystemOperationError.unsupportedNode(.unknown)
                }
                return DurableFileHandle(fileDescriptor: fileDescriptor)
            } catch {
                _ = Darwin.close(fileDescriptor)
                _ = unlinkat(descriptor, name, 0)
                throw error
            }
        }
    }

    private static func validatedComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ArchiveNameValidationError.unsafeRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw ArchiveNameValidationError.unsafeRelativePath(path)
        }
        do {
            return try components.map { component in
                try ArchiveComponentValidator.validate(String(component))
            }
        } catch {
            throw ArchiveNameValidationError.unsafeRelativePath(path)
        }
    }

    private static func isSupported(_ kind: ExtractionNodeKind) -> Bool {
        switch kind {
        case .regularFile, .directory, .symbolicLink:
            return true
        case .hardLink, .fifo, .socket, .blockDevice, .characterDevice, .unknown:
            return false
        }
    }

    private static func posixError(_ function: String) -> FileSystemOperationError {
        .posix(function: function, code: errno)
    }
}
