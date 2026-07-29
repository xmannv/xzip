import Darwin
import Foundation

public struct FileNodeIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let generation: UInt64?
    public let kind: ExtractionNodeKind

    public init(
        device: UInt64,
        inode: UInt64,
        generation: UInt64?,
        kind: ExtractionNodeKind
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.kind = kind
    }
}

public struct MoveObservation: Equatable, Sendable {
    public let sourceIdentity: FileNodeIdentity?
    public let destinationIdentity: FileNodeIdentity?
}

public struct SwapObservation: Equatable, Sendable {
    public let leftIdentity: FileNodeIdentity?
    public let rightIdentity: FileNodeIdentity?
}

public enum FileSystemMutationOperation: String, Equatable, Sendable {
    case exclusiveMove
    case swap
}

public enum FileSystemMutationPathRole: String, Equatable, Sendable {
    case source
    case destination
    case left
    case right
}

public struct FileTimestamp: Codable, Hashable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int32

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

public struct FileTimestamps: Codable, Hashable, Sendable {
    public let access: FileTimestamp
    public let modification: FileTimestamp

    public init(access: FileTimestamp, modification: FileTimestamp) {
        self.access = access
        self.modification = modification
    }
}

public struct FileNode: Hashable, Sendable {
    public let name: String
    public let identity: FileNodeIdentity
    public let byteCount: UInt64
    public let linkTarget: String?
    public let allocatedByteCount: UInt64
    public let timestamps: FileTimestamps?
    public let statusChangeTimestamp: FileTimestamp?

    public init(
        name: String,
        identity: FileNodeIdentity,
        byteCount: UInt64,
        linkTarget: String?,
        allocatedByteCount: UInt64? = nil,
        timestamps: FileTimestamps? = nil,
        statusChangeTimestamp: FileTimestamp? = nil
    ) {
        self.name = name
        self.identity = identity
        self.byteCount = byteCount
        self.linkTarget = linkTarget
        self.allocatedByteCount = allocatedByteCount ?? byteCount
        self.timestamps = timestamps
        self.statusChangeTimestamp = statusChangeTimestamp
    }
}

public enum FileSystemOperationError: Error, Equatable, Sendable {
    case closedDirectoryHandle
    case invalidComponent(String)
    case invalidAbsoluteDirectoryURL(URL)
    case symlinkEncountered(String)
    case notDirectory(String)
    case unsupportedNode(ExtractionNodeKind)
    case alreadyExists(String)
    case identityMismatch(expected: FileNodeIdentity, actual: FileNodeIdentity?)
    case restoreFailed(name: String)
    case unsupportedExclusiveRename
    case unsupportedTransactionalSwap
    case postEffectObservationFailed(
        operation: FileSystemMutationOperation,
        pathRole: FileSystemMutationPathRole,
        function: String,
        code: Int32
    )
    case posix(function: String, code: Int32)
}

/// Same reason as the sibling error types: these travel up to the app, which
/// renders `error.localizedDescription`, so without this they read as
/// "(XZIPCore.FileSystemOperationError error 10.)".
///
/// `.posix` reports `strerror` rather than the raw number — "No space left on
/// device" is actionable, "code 28" is not — and keeps the syscall name, which is
/// what makes a bug report useful.
extension FileSystemOperationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closedDirectoryHandle:
            return "That folder was already closed."
        case let .invalidComponent(name):
            return "This name cannot be used on disk: \(name)"
        case let .invalidAbsoluteDirectoryURL(url):
            return "This is not a usable folder path: \(url.path)"
        case let .symlinkEncountered(name):
            return "\(name) is a symbolic link, which is not allowed here."
        case let .notDirectory(name):
            return "\(name) is not a folder."
        case let .unsupportedNode(kind):
            return "This kind of file is not supported: \(kind)"
        case let .alreadyExists(name):
            return "\(name) already exists."
        case .identityMismatch:
            return "A file changed on disk while it was being worked on. Try again."
        case let .restoreFailed(name):
            return "\(name) could not be put back."
        case .unsupportedExclusiveRename:
            return "This disk does not support the safe rename this operation needs."
        case .unsupportedTransactionalSwap:
            return "This disk does not support the transactional swap this operation needs."
        case let .postEffectObservationFailed(_, _, function, code):
            return "Post-effect observation via \(function) failed: \(String(cString: strerror(code)))"
        case let .posix(function, code):
            return "\(function) failed: \(String(cString: strerror(code)))"
        }
    }
}

public enum DirectoryHandleScope: Equatable, Sendable {
    case external

    /// Capability for an exclusive namespace mutated only by its owning transaction.
    case transactionOwned
}

public enum DurableFileAccess: Sendable {
    case readOnly
    case readWrite
}

public final class DurableFileHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    public func read(upToCount count: Int) throws -> Data {
        guard count >= 0 else {
            throw FileSystemOperationError.posix(function: "read.count", code: EINVAL)
        }
        return try withFileDescriptor { descriptor in
            var data = Data(count: count)
            let result = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            guard result >= 0 else { throw Self.posixError("read") }
            data.count = result
            return data
        }
    }

    public func write(_ data: Data) throws {
        try withFileDescriptor { descriptor in
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard result >= 0 else { throw Self.posixError("write") }
                    guard result > 0 else {
                        throw FileSystemOperationError.posix(function: "write", code: EIO)
                    }
                    offset += result
                }
            }
        }
    }

    public func seek(toOffset offset: UInt64) throws {
        guard offset <= UInt64(off_t.max) else {
            throw FileSystemOperationError.posix(function: "lseek", code: EOVERFLOW)
        }
        try withFileDescriptor { descriptor in
            guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
                throw Self.posixError("lseek")
            }
        }
    }

    @discardableResult
    public func seekToEnd() throws -> UInt64 {
        try withFileDescriptor { descriptor in
            let result = lseek(descriptor, 0, SEEK_END)
            guard result >= 0 else { throw Self.posixError("lseek") }
            return UInt64(result)
        }
    }

    public func fsync() throws {
        try withFileDescriptor { descriptor in
            guard Darwin.fsync(descriptor) == 0 else { throw Self.posixError("fsync") }
        }
    }

    public func close() {
        lock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptor >= 0 else {
            throw FileSystemOperationError.closedDirectoryHandle
        }
        return try body(fileDescriptor)
    }

    private static func posixError(_ function: String) -> FileSystemOperationError {
        .posix(function: function, code: errno)
    }
}

public final class DirectoryHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32
    let scope: DirectoryHandleScope

    init(fileDescriptor: Int32, scope: DirectoryHandleScope) {
        self.fileDescriptor = fileDescriptor
        self.scope = scope
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    func withFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptor >= 0 else {
            throw FileSystemOperationError.closedDirectoryHandle
        }
        return try body(fileDescriptor)
    }
}

private func postEffectObservationError(
    _ error: Error,
    operation: FileSystemMutationOperation,
    pathRole: FileSystemMutationPathRole
) -> FileSystemOperationError {
    if let fileSystemError = error as? FileSystemOperationError {
        switch fileSystemError {
        case let .posix(function, code):
            return .postEffectObservationFailed(
                operation: operation,
                pathRole: pathRole,
                function: function,
                code: code
            )
        case .closedDirectoryHandle:
            return .postEffectObservationFailed(
                operation: operation,
                pathRole: pathRole,
                function: "fstatat",
                code: EBADF
            )
        default:
            break
        }
    }
    return .postEffectObservationFailed(
        operation: operation,
        pathRole: pathRole,
        function: "statNoFollow",
        code: EIO
    )
}

public protocol FileSystemOperations: Sendable {
    func openDirectoryNoFollow(at url: URL) throws -> DirectoryHandle
    func openDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle
    func openRelativeDirectoryNoFollow(
        root: DirectoryHandle,
        components: [String],
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle
    func openTransactionOwnedDirectoryNoFollow(
        at url: URL,
        expected: FileNodeIdentity
    ) throws -> DirectoryHandle
    func openTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle

    /// Adopts a directory that the transaction owns but did not create itself,
    /// repairing its mode to exact `0700` before returning owned authority.
    ///
    /// Staged content is written by an external extractor, which recreates
    /// archive directories with the mode recorded in the archive (commonly
    /// `0755`). Such a directory is still transaction-private — it lives inside
    /// an exclusively created `0700` staging tree — but it does not satisfy the
    /// exact-`0700` requirement that owned operations enforce. Adoption closes
    /// that gap by tightening the mode instead of relaxing the requirement, so
    /// the invariant holds no matter how the extractor terminated (success,
    /// failure, cancellation, or process death).
    ///
    /// The node is opened no-follow and verified as a directory with the
    /// expected identity *before* the mode is changed, and the change is applied
    /// to that verified descriptor, so a swapped-in symlink can never redirect
    /// it. Use this only for staged content; directories the transaction created
    /// itself must keep using `openTransactionOwnedDirectoryNoFollow`, which
    /// treats a wrong mode as tampering.
    func adoptTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle
    /// Sets the permission bits of a transaction-owned directory.
    ///
    /// This is the inverse of adoption and exists for exactly one purpose:
    /// handing a staged directory to the user with the mode its archive
    /// recorded, immediately before it is published. Only the low 9 bits are
    /// honoured; set-user/group-ID and sticky bits are masked off so an archive
    /// can never request privileged bits.
    ///
    /// The directory must already be transaction-owned, so authority is proven
    /// before the mode is relaxed. Afterwards the directory no longer satisfies
    /// the exact-`0700` rule, so it must not be used as an owned parent again;
    /// call this only on a subtree that is about to leave the transaction.
    func setTransactionOwnedDirectoryMode(
        _ directory: DirectoryHandle,
        mode: UInt16
    ) throws
    func identity(of directory: DirectoryHandle) throws -> FileNodeIdentity
    func statNoFollow(parent: DirectoryHandle, name: String) throws -> FileNode?
    func listNoFollow(_ directory: DirectoryHandle) throws -> [FileNode]
    func forEachNodeNoFollow(
        _ directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws
    func createDirectoryExclusive(parent: DirectoryHandle, name: String) throws -> FileNodeIdentity

    /// Creates an exact-0700 transaction root and returns its exclusive namespace capability.
    ///
    /// - Precondition: `parent` remains a private/exclusive creation namespace from `mkdirat`
    ///   through retained-handle verification. An arbitrary writable public destination parent
    ///   does not satisfy this precondition.
    func createTransactionDirectoryExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DirectoryHandle
    func createRegularFileExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DurableFileHandle
    func openRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?,
        access: DurableFileAccess
    ) throws -> DurableFileHandle
    func replaceRegularFileAtomically(
        parent: DirectoryHandle,
        temporaryName: String,
        destinationName: String,
        expectedTemporary: FileNodeIdentity
    ) throws
    func fsyncRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity
    ) throws
    func renameExclusive(
        fromParent: DirectoryHandle, fromName: String,
        toParent: DirectoryHandle, toName: String
    ) throws
    func moveExclusiveObserved(
        fromParent: DirectoryHandle,
        fromName: String,
        toParent: DirectoryHandle,
        toName: String,
        expectedSource: FileNodeIdentity
    ) throws -> MoveObservation
    func swapObserved(
        leftParent: DirectoryHandle,
        leftName: String,
        expectedLeft: FileNodeIdentity,
        rightParent: DirectoryHandle,
        rightName: String,
        expectedRight: FileNodeIdentity
    ) throws -> SwapObservation
    /// Removes a node from an exact-0700 transaction-owned namespace without following links.
    ///
    /// - Precondition: `parent` carries `.transactionOwned`, and only its owning transaction
    ///   mutates that namespace for the lifetime of the operation.
    func removeOwnedNoFollow(
        parent: DirectoryHandle, name: String,
        expected: FileNodeIdentity
    ) throws
    func setExtendedAttributeNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws
    func setExtendedAttribute(
        on directory: DirectoryHandle,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws
    func fsync(_ directory: DirectoryHandle) throws
}

public extension FileSystemOperations {
    func moveExclusiveObserved(
        fromParent: DirectoryHandle,
        fromName: String,
        toParent: DirectoryHandle,
        toName: String,
        expectedSource: FileNodeIdentity
    ) throws -> MoveObservation {
        let initial = try statNoFollow(parent: fromParent, name: fromName)?.identity
        guard initial == expectedSource else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedSource,
                actual: initial
            )
        }
        try renameExclusive(
            fromParent: fromParent,
            fromName: fromName,
            toParent: toParent,
            toName: toName
        )

        let sourceIdentity: FileNodeIdentity?
        do {
            sourceIdentity = try statNoFollow(parent: fromParent, name: fromName)?.identity
        } catch {
            throw postEffectObservationError(
                error,
                operation: .exclusiveMove,
                pathRole: .source
            )
        }
        let destinationIdentity: FileNodeIdentity?
        do {
            destinationIdentity = try statNoFollow(parent: toParent, name: toName)?.identity
        } catch {
            throw postEffectObservationError(
                error,
                operation: .exclusiveMove,
                pathRole: .destination
            )
        }
        return MoveObservation(
            sourceIdentity: sourceIdentity,
            destinationIdentity: destinationIdentity
        )
    }

    func swapObserved(
        leftParent: DirectoryHandle,
        leftName: String,
        expectedLeft: FileNodeIdentity,
        rightParent: DirectoryHandle,
        rightName: String,
        expectedRight: FileNodeIdentity
    ) throws -> SwapObservation {
        throw FileSystemOperationError.unsupportedTransactionalSwap
    }
}

protocol FileTimestampOperations: Sendable {
    func setTimestampsNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity,
        timestamps: FileTimestamps
    ) throws
}

protocol DirectoryTraversalObserving: Sendable {
    func didFstat(component: String, identity: FileNodeIdentity)
    func didRetain(component: String) throws
}


enum FileSystemOperationBoundary: Equatable, Sendable {
    case afterSymlinkLookup
    case beforeMoveVerification
    case beforeOwnedDirectRemoval
    case afterOwnedFinalVerification
    case afterOwnedDirectRemoval
    case afterOwnedParentSync
    case beforeTransactionModeEstablishment
    case beforeExtendedAttributeOpen
}

protocol FileSystemOperationObserving: Sendable {
    func didReach(_ boundary: FileSystemOperationBoundary, component: String) throws
}

public struct DarwinFileSystemOperations: FileSystemOperations, FileTimestampOperations, Sendable {
    typealias ExclusiveRename = @Sendable (
        Int32, String, Int32, String
    ) -> Int32
    typealias ExchangeRename = @Sendable (
        Int32, String, Int32, String
    ) -> Int32
    typealias SetMode = @Sendable (Int32, mode_t) -> Int32
    typealias OpenRegularFile = @Sendable (Int32, String, Int32) -> Int32

    private let traversalObserver: (any DirectoryTraversalObserving)?
    private let operationObserver: (any FileSystemOperationObserving)?
    private let exclusiveRename: ExclusiveRename
    private let exchangeRename: ExchangeRename
    private let setMode: SetMode
    private let openRegularFile: OpenRegularFile

    private init(
        traversalObserver: (any DirectoryTraversalObserving)?,
        operationObserver: (any FileSystemOperationObserving)?,
        exclusiveRename: @escaping ExclusiveRename,
        exchangeRename: @escaping ExchangeRename,
        setMode: @escaping SetMode,
        openRegularFile: @escaping OpenRegularFile = Self.systemOpenRegularFile
    ) {
        self.traversalObserver = traversalObserver
        self.operationObserver = operationObserver
        self.exclusiveRename = exclusiveRename
        self.exchangeRename = exchangeRename
        self.setMode = setMode
        self.openRegularFile = openRegularFile
    }

    public init() {
        self.init(
            traversalObserver: nil,
            operationObserver: nil,
            exclusiveRename: Self.systemRenameExclusive,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode
        )
    }

    init(traversalObserver: any DirectoryTraversalObserving) {
        self.init(
            traversalObserver: traversalObserver,
            operationObserver: nil,
            exclusiveRename: Self.systemRenameExclusive,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode
        )
    }

    init(operationObserver: any FileSystemOperationObserving) {
        self.init(
            traversalObserver: nil,
            operationObserver: operationObserver,
            exclusiveRename: Self.systemRenameExclusive,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode
        )
    }

    init(
        operationObserver: any FileSystemOperationObserving,
        exclusiveRename: @escaping ExclusiveRename
    ) {
        self.init(
            traversalObserver: nil,
            operationObserver: operationObserver,
            exclusiveRename: exclusiveRename,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode
        )
    }

    init(
        operationObserver: any FileSystemOperationObserving,
        setMode: @escaping SetMode
    ) {
        self.init(
            traversalObserver: nil,
            operationObserver: operationObserver,
            exclusiveRename: Self.systemRenameExclusive,
            exchangeRename: Self.systemRenameSwap,
            setMode: setMode
        )
    }

    init(exclusiveRename: @escaping ExclusiveRename) {
        self.init(
            traversalObserver: nil,
            operationObserver: nil,
            exclusiveRename: exclusiveRename,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode
        )
    }

    init(
        exclusiveRename: @escaping ExclusiveRename,
        exchangeRename: @escaping ExchangeRename
    ) {
        self.init(
            traversalObserver: nil,
            operationObserver: nil,
            exclusiveRename: exclusiveRename,
            exchangeRename: exchangeRename,
            setMode: Self.systemSetMode
        )
    }

    init(openRegularFile: @escaping OpenRegularFile) {
        self.init(
            traversalObserver: nil,
            operationObserver: nil,
            exclusiveRename: Self.systemRenameExclusive,
            exchangeRename: Self.systemRenameSwap,
            setMode: Self.systemSetMode,
            openRegularFile: openRegularFile
        )
    }


    public func openDirectoryNoFollow(at url: URL) throws -> DirectoryHandle {
        let components = try validatedAbsoluteComponents(of: url)
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("open") }

        do {
            var rootMetadata = stat()
            guard fstat(descriptor, &rootMetadata) == 0 else {
                throw posixError("fstat")
            }
            guard nodeKind(rootMetadata) == .directory else {
                throw FileSystemOperationError.notDirectory("/")
            }
            traversalObserver?.didFstat(component: "/", identity: identity(rootMetadata))

            for component in components {
                let next = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    let openError = errno
                    var metadata = stat()
                    if fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                       nodeKind(metadata) == .symbolicLink {
                        throw FileSystemOperationError.symlinkEncountered(component)
                    }
                    if openError == ENOTDIR {
                        throw FileSystemOperationError.notDirectory(component)
                    }
                    errno = openError
                    throw posixError("openat")
                }

                var metadata = stat()
                guard fstat(next, &metadata) == 0 else {
                    let error = posixError("fstat")
                    _ = Darwin.close(next)
                    throw error
                }
                guard nodeKind(metadata) == .directory else {
                    _ = Darwin.close(next)
                    throw FileSystemOperationError.notDirectory(component)
                }
                traversalObserver?.didFstat(component: component, identity: identity(metadata))
                _ = Darwin.close(descriptor)
                descriptor = next
                try traversalObserver?.didRetain(component: component)
            }

            return DirectoryHandle(fileDescriptor: descriptor, scope: .external)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    public func createDirectoryPathNoFollow(at url: URL) throws {
        let components = try validatedAbsoluteComponents(of: url)
        var current = try openDirectoryNoFollow(
            at: URL(fileURLWithPath: "/", isDirectory: true)
        )
        defer { current.close() }

        for component in components {
            if try statNoFollow(parent: current, name: component) == nil {
                try current.withFileDescriptor { descriptor in
                    guard mkdirat(descriptor, component, mode_t(0o777)) == 0 else {
                        if errno == EEXIST { return }
                        throw posixError("mkdirat")
                    }
                }
            }
            guard let node = try statNoFollow(parent: current, name: component) else {
                throw FileSystemOperationError.posix(
                    function: "fstatat",
                    code: ENOENT
                )
            }
            let next = try openDirectoryNoFollow(
                parent: current,
                name: component,
                expected: node.identity
            )
            current.close()
            current = next
        }
    }

    public func openDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        let component = try validatedComponent(name)
        return try parent.withFileDescriptor { parentFD in
            let descriptor = Darwin.openat(
                parentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                let openError = errno
                var metadata = stat()
                if fstatat(parentFD, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                   nodeKind(metadata) == .symbolicLink {
                    throw FileSystemOperationError.symlinkEncountered(component)
                }
                if openError == ENOTDIR {
                    throw FileSystemOperationError.notDirectory(component)
                }
                errno = openError
                throw posixError("openat")
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                let error = posixError("fstat")
                _ = Darwin.close(descriptor)
                throw error
            }
            let actual = identity(metadata)
            guard actual.kind == .directory else {
                _ = Darwin.close(descriptor)
                throw FileSystemOperationError.notDirectory(component)
            }
            if let expected, expected != actual {
                _ = Darwin.close(descriptor)
                throw FileSystemOperationError.identityMismatch(expected: expected, actual: actual)
            }
            return DirectoryHandle(fileDescriptor: descriptor, scope: parent.scope)
        }
    }

    public func openRelativeDirectoryNoFollow(
        root: DirectoryHandle,
        components: [String],
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        guard !components.isEmpty else {
            if let expected {
                let actual = try identity(of: root)
                guard actual == expected else {
                    throw FileSystemOperationError.identityMismatch(expected: expected, actual: actual)
                }
            }
            return try root.withFileDescriptor { descriptor in
                let duplicate = try duplicateCloseOnExec(descriptor)
                return DirectoryHandle(fileDescriptor: duplicate, scope: root.scope)
            }
        }
        var current = root
        for (index, component) in components.enumerated() {
            current = try openDirectoryNoFollow(
                parent: current,
                name: component,
                expected: index == components.count - 1 ? expected : nil
            )
        }
        return current
    }


    public func openTransactionOwnedDirectoryNoFollow(
        at url: URL,
        expected: FileNodeIdentity
    ) throws -> DirectoryHandle {
        let opened = try openDirectoryNoFollow(at: url)
        do {
            return try mintTransactionOwnedDirectory(opened, expected: expected, name: url.lastPathComponent)
        } catch {
            opened.close()
            throw error
        }
    }

    public func openTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try validateTransactionOwned(parent)
        let opened = try openDirectoryNoFollow(parent: parent, name: name, expected: expected)
        do {
            return try mintTransactionOwnedDirectory(opened, expected: expected, name: name)
        } catch {
            opened.close()
            throw error
        }
    }

    public func adoptTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try validateTransactionOwned(parent)
        let opened = try openDirectoryNoFollow(parent: parent, name: name, expected: expected)
        do {
            try repairOwnedDirectoryMode(opened, name: name)
            return try mintTransactionOwnedDirectory(opened, expected: expected, name: name)
        } catch {
            opened.close()
            throw error
        }
    }

    /// Tightens an already-verified directory descriptor to exact `0700`.
    ///
    /// `fchmod` acts on the open descriptor, so the node verified by the caller
    /// is the node modified. A directory already at `0700` is left untouched.
    private func repairOwnedDirectoryMode(
        _ directory: DirectoryHandle,
        name: String
    ) throws {
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            guard nodeKind(metadata) == .directory else {
                throw FileSystemOperationError.notDirectory(name)
            }
            guard metadata.st_mode & mode_t(0o7777) != mode_t(0o700) else { return }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw posixError("adoptTransactionOwnedDirectoryNoFollow.fchmod")
            }
        }
    }

    public func setTransactionOwnedDirectoryMode(
        _ directory: DirectoryHandle,
        mode: UInt16
    ) throws {
        try validateTransactionOwned(directory)
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            guard nodeKind(metadata) == .directory else {
                throw FileSystemOperationError.notDirectory("setTransactionOwnedDirectoryMode")
            }
            guard setMode(descriptor, mode_t(mode & 0o777)) == 0 else {
                throw posixError("setTransactionOwnedDirectoryMode.fchmod")
            }
        }
    }

    public func identity(of directory: DirectoryHandle) throws -> FileNodeIdentity {
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            return identity(metadata)
        }
    }

    public func statNoFollow(parent: DirectoryHandle, name: String) throws -> FileNode? {
        let component = try validatedComponent(name)
        return try parent.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw posixError("fstatat")
            }

            guard nodeKind(metadata) == .symbolicLink else {
                let nodeMetadata = fileNodeMetadata(metadata)
                return FileNode(
                    name: component,
                    identity: identity(metadata),
                    byteCount: nodeMetadata.logicalBytes,
                    linkTarget: nil,
                    allocatedByteCount: nodeMetadata.allocatedBytes,
                    timestamps: nodeMetadata.timestamps,
                    statusChangeTimestamp: nodeMetadata.statusChangeTimestamp
                )
            }

            try operationObserver?.didReach(.afterSymlinkLookup, component: component)
            let symlinkDescriptor = Darwin.openat(
                descriptor,
                component,
                O_SYMLINK | O_CLOEXEC
            )
            guard symlinkDescriptor >= 0 else { throw posixError("openat") }
            defer { _ = Darwin.close(symlinkDescriptor) }

            var symlinkMetadata = stat()
            guard fstat(symlinkDescriptor, &symlinkMetadata) == 0 else {
                throw posixError("fstat")
            }
            let actualIdentity = identity(symlinkMetadata)
            guard actualIdentity.kind == .symbolicLink else {
                throw FileSystemOperationError.identityMismatch(
                    expected: identity(metadata),
                    actual: actualIdentity
                )
            }
            let initialCapacity: Int
            if symlinkMetadata.st_size >= 0,
               UInt64(symlinkMetadata.st_size) < UInt64(Int.max) {
                initialCapacity = max(1, Int(symlinkMetadata.st_size) + 1)
            } else {
                initialCapacity = 256
            }
            let linkTarget = try Self.readLinkTarget(
                fileDescriptor: symlinkDescriptor,
                initialCapacity: initialCapacity,
                readLink: freadlink
            )
            let nodeMetadata = fileNodeMetadata(symlinkMetadata)
            return FileNode(
                name: component,
                identity: actualIdentity,
                byteCount: nodeMetadata.logicalBytes,
                linkTarget: linkTarget,
                allocatedByteCount: nodeMetadata.allocatedBytes,
                timestamps: nodeMetadata.timestamps,
                statusChangeTimestamp: nodeMetadata.statusChangeTimestamp
            )
        }
    }

    func setTimestampsNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity,
        timestamps: FileTimestamps
    ) throws {
        let component = try validatedComponent(name)
        guard (0..<1_000_000_000).contains(timestamps.access.nanoseconds),
              (0..<1_000_000_000).contains(timestamps.modification.nanoseconds)
        else {
            throw FileSystemOperationError.posix(function: "utimensat.nanoseconds", code: EINVAL)
        }

        try parent.withFileDescriptor { descriptor in
            var before = stat()
            guard fstatat(descriptor, component, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError("fstatat")
            }
            let beforeIdentity = identity(before)
            guard beforeIdentity == expected else {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: beforeIdentity
                )
            }

            let values = [
                timespec(
                    tv_sec: Int(timestamps.access.seconds),
                    tv_nsec: Int(timestamps.access.nanoseconds)
                ),
                timespec(
                    tv_sec: Int(timestamps.modification.seconds),
                    tv_nsec: Int(timestamps.modification.nanoseconds)
                ),
            ]
            let result = values.withUnsafeBufferPointer { buffer in
                utimensat(
                    descriptor,
                    component,
                    buffer.baseAddress,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result == 0 else { throw posixError("utimensat") }

            var after = stat()
            guard fstatat(descriptor, component, &after, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError("fstatat")
            }
            let afterIdentity = identity(after)
            guard afterIdentity == expected else {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: afterIdentity
                )
            }
        }
    }

    public func listNoFollow(_ directory: DirectoryHandle) throws -> [FileNode] {
        let duplicate = try directory.withFileDescriptor { descriptor in
            try duplicateCloseOnExec(descriptor)
        }
        guard let stream = fdopendir(duplicate) else {
            let openError = errno
            _ = Darwin.close(duplicate)
            errno = openError
            throw posixError("fdopendir")
        }
        defer { closedir(stream) }

        let names = try Self.readDirectoryNames(
            stream: stream,
            readEntry: { readdir($0) }
        )
        var nodes: [FileNode] = []
        for name in names {
            if let node = try statNoFollow(parent: directory, name: name) {
                nodes.append(node)
            }
        }
        return nodes
    }

    public func forEachNodeNoFollow(
        _ directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws {
        let duplicate = try directory.withFileDescriptor { descriptor in
            try duplicateCloseOnExec(descriptor)
        }
        guard let stream = fdopendir(duplicate) else {
            let openError = errno
            _ = Darwin.close(duplicate)
            errno = openError
            throw posixError("fdopendir")
        }
        defer { closedir(stream) }

        try Self.visitDirectoryNames(
            stream: stream,
            readEntry: { readdir($0) },
            visit: { name in
                try Task.checkCancellation()
                if let node = try statNoFollow(parent: directory, name: name) {
                    try body(node)
                }
            }
        )
    }

    public func createDirectoryExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> FileNodeIdentity {
        let component = try validatedComponent(name)
        try parent.withFileDescriptor { descriptor in
            guard mkdirat(descriptor, component, 0o700) == 0 else {
                if errno == EEXIST { throw FileSystemOperationError.alreadyExists(component) }
                throw posixError("mkdirat")
            }
        }
        guard let node = try statNoFollow(parent: parent, name: component) else {
            throw FileSystemOperationError.posix(function: "fstatat", code: ENOENT)
        }
        return node.identity
    }

    public func createTransactionDirectoryExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DirectoryHandle {
        let component = try validatedComponent(name)
        let expected = try createDirectoryExclusive(parent: parent, name: component)

        do {
            let opened = try openDirectoryNoFollow(
                parent: parent,
                name: component,
                expected: expected
            )
            do {
                try opened.withFileDescriptor { descriptor in
                    try operationObserver?.didReach(
                        .beforeTransactionModeEstablishment,
                        component: component
                    )
                    let result = setMode(descriptor, mode_t(0o700))
                    let modeError = errno
                    guard result == 0 else {
                        throw FileSystemOperationError.posix(
                            function: "fchmod",
                            code: modeError
                        )
                    }
                }
                let owned = try mintTransactionOwnedDirectory(
                    opened,
                    expected: expected,
                    name: component,
                    modeFunction: "createTransactionDirectoryExclusive.mode"
                )
                opened.close()
                return owned
            } catch {
                opened.close()
                throw error
            }
        } catch {
            let creationError = error
            do {
                try removeVerifiedDirect(
                    parent: parent,
                    component: component,
                    expected: expected
                )
            } catch {
                throw FileSystemOperationError.restoreFailed(name: component)
            }
            throw creationError
        }
    }


    public func createRegularFileExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DurableFileHandle {
        try validateTransactionOwned(parent)
        let component = try validatedComponent(name)
        return try parent.withFileDescriptor { parentDescriptor in
            let descriptor = Darwin.openat(
                parentDescriptor,
                component,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                if errno == EEXIST { throw FileSystemOperationError.alreadyExists(component) }
                throw posixError("openat")
            }
            do {
                guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw posixError("fchmod")
                }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
                guard nodeKind(metadata) == .regularFile,
                      metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
                else {
                    throw FileSystemOperationError.unsupportedNode(nodeKind(metadata))
                }
                return DurableFileHandle(fileDescriptor: descriptor)
            } catch {
                _ = Darwin.close(descriptor)
                _ = unlinkat(parentDescriptor, component, 0)
                _ = Darwin.fsync(parentDescriptor)
                throw error
            }
        }
    }

    public func openRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?,
        access: DurableFileAccess
    ) throws -> DurableFileHandle {
        if case .readWrite = access {
            try validateTransactionOwned(parent)
        }
        let component = try validatedComponent(name)
        return try parent.withFileDescriptor { parentDescriptor in
            let flags: Int32
            switch access {
            case .readOnly:
                flags = O_RDONLY | O_NONBLOCK
            case .readWrite:
                flags = O_RDWR
            }
            let descriptor = openRegularFile(
                parentDescriptor,
                component,
                flags | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw posixError("openat") }
            do {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
                let actual = identity(metadata)
                guard actual.kind == .regularFile else {
                    throw FileSystemOperationError.unsupportedNode(actual.kind)
                }
                if parent.scope == .transactionOwned {
                    guard metadata.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                        throw FileSystemOperationError.posix(
                            function: "openRegularFileNoFollow.mode",
                            code: EPERM
                        )
                    }
                }
                if let expected, expected != actual {
                    throw FileSystemOperationError.identityMismatch(
                        expected: expected,
                        actual: actual
                    )
                }
                return DurableFileHandle(fileDescriptor: descriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
    }

    public func replaceRegularFileAtomically(
        parent: DirectoryHandle,
        temporaryName: String,
        destinationName: String,
        expectedTemporary: FileNodeIdentity
    ) throws {
        try validateTransactionOwned(parent)
        let temporary = try validatedComponent(temporaryName)
        let destination = try validatedComponent(destinationName)
        guard expectedTemporary.kind == .regularFile else {
            throw FileSystemOperationError.unsupportedNode(expectedTemporary.kind)
        }
        let actual = try statNoFollow(parent: parent, name: temporary)?.identity
        guard actual == expectedTemporary else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedTemporary,
                actual: actual
            )
        }
        try parent.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstatat(descriptor, temporary, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError("fstatat")
            }
            let reverified = identity(metadata)
            guard reverified == expectedTemporary else {
                throw FileSystemOperationError.identityMismatch(
                    expected: expectedTemporary,
                    actual: reverified
                )
            }
            guard renameat(descriptor, temporary, descriptor, destination) == 0 else {
                throw posixError("renameat")
            }
        }
    }

    public func fsyncRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity
    ) throws {
        let component = try validatedComponent(name)
        let handle = try parent.withFileDescriptor { parentDescriptor in
            let descriptor = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw posixError("openat") }
            do {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
                let actual = identity(metadata)
                guard actual.kind == .regularFile else {
                    throw FileSystemOperationError.unsupportedNode(actual.kind)
                }
                guard actual == expected else {
                    throw FileSystemOperationError.identityMismatch(
                        expected: expected,
                        actual: actual
                    )
                }
                return DurableFileHandle(fileDescriptor: descriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        defer { handle.close() }
        try handle.fsync()
    }

    public func renameExclusive(
        fromParent: DirectoryHandle,
        fromName: String,
        toParent: DirectoryHandle,
        toName: String
    ) throws {
        let source = try validatedComponent(fromName)
        let destination = try validatedComponent(toName)
        let sourceFD = try fromParent.withFileDescriptor { descriptor in
            let duplicate = try duplicateCloseOnExec(descriptor)
            return duplicate
        }
        defer { _ = Darwin.close(sourceFD) }
        let destinationFD = try toParent.withFileDescriptor { descriptor in
            let duplicate = try duplicateCloseOnExec(descriptor)
            return duplicate
        }
        defer { _ = Darwin.close(destinationFD) }

        let result = exclusiveRename(sourceFD, source, destinationFD, destination)
        let renameError = errno
        guard result == 0 else {
            if renameError == EEXIST {
                throw FileSystemOperationError.alreadyExists(destination)
            }
            if renameError == ENOTSUP || renameError == EINVAL {
                throw FileSystemOperationError.unsupportedExclusiveRename
            }
            errno = renameError
            throw posixError("renameatx_np")
        }
    }

    public func swapObserved(
        leftParent: DirectoryHandle,
        leftName: String,
        expectedLeft: FileNodeIdentity,
        rightParent: DirectoryHandle,
        rightName: String,
        expectedRight: FileNodeIdentity
    ) throws -> SwapObservation {
        let initialLeft = try statNoFollow(parent: leftParent, name: leftName)?.identity
        guard initialLeft == expectedLeft else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedLeft,
                actual: initialLeft
            )
        }
        let initialRight = try statNoFollow(parent: rightParent, name: rightName)?.identity
        guard initialRight == expectedRight else {
            throw FileSystemOperationError.identityMismatch(
                expected: expectedRight,
                actual: initialRight
            )
        }

        let left = try validatedComponent(leftName)
        let right = try validatedComponent(rightName)
        let leftFD = try leftParent.withFileDescriptor { descriptor in
            try duplicateCloseOnExec(descriptor)
        }
        defer { _ = Darwin.close(leftFD) }
        let rightFD = try rightParent.withFileDescriptor { descriptor in
            try duplicateCloseOnExec(descriptor)
        }
        defer { _ = Darwin.close(rightFD) }

        let result = exchangeRename(leftFD, left, rightFD, right)
        let renameError = errno
        guard result == 0 else {
            if renameError == ENOTSUP || renameError == EINVAL || renameError == EXDEV {
                throw FileSystemOperationError.unsupportedTransactionalSwap
            }
            errno = renameError
            throw posixError("renameatx_np")
        }

        let leftIdentity: FileNodeIdentity?
        do {
            leftIdentity = try statNoFollow(parent: leftParent, name: leftName)?.identity
        } catch {
            throw postEffectObservationError(
                error,
                operation: .swap,
                pathRole: .left
            )
        }
        let rightIdentity: FileNodeIdentity?
        do {
            rightIdentity = try statNoFollow(parent: rightParent, name: rightName)?.identity
        } catch {
            throw postEffectObservationError(
                error,
                operation: .swap,
                pathRole: .right
            )
        }
        return SwapObservation(
            leftIdentity: leftIdentity,
            rightIdentity: rightIdentity
        )
    }

    public func removeOwnedNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity
    ) throws {
        try validateTransactionOwned(
            parent,
            modeFunction: "removeOwnedNoFollow.mode"
        )
        let component = try validatedComponent(name)
        try removeVerifiedDirect(
            parent: parent,
            component: component,
            expected: expected
        )
    }


    private func removeVerifiedDirect(
        parent: DirectoryHandle,
        component: String,
        expected: FileNodeIdentity
    ) throws {
        guard let initial = try statNoFollow(parent: parent, name: component)?.identity else {
            try fsync(parent)
            try operationObserver?.didReach(.afterOwnedParentSync, component: component)
            return
        }
        guard initial == expected else {
            throw FileSystemOperationError.identityMismatch(expected: expected, actual: initial)
        }

        try operationObserver?.didReach(.beforeOwnedDirectRemoval, component: component)
        try parent.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT {
                    guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync") }
                    return
                }
                throw posixError("fstatat")
            }
            let actual = identity(metadata)
            guard actual == expected else {
                throw FileSystemOperationError.identityMismatch(expected: expected, actual: actual)
            }
            try operationObserver?.didReach(
                .afterOwnedFinalVerification,
                component: component
            )
            let flags = expected.kind == .directory ? AT_REMOVEDIR : 0
            guard unlinkat(descriptor, component, flags) == 0 else {
                throw posixError("unlinkat")
            }
        }
        try operationObserver?.didReach(.afterOwnedDirectRemoval, component: component)
        try fsync(parent)
        try operationObserver?.didReach(.afterOwnedParentSync, component: component)
    }

    public func setExtendedAttributeNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws {
        let component = try validatedComponent(name)
        let flags: Int32
        switch expected.kind {
        case .regularFile:
            flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        case .directory:
            flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        case .symbolicLink:
            flags = O_SYMLINK | O_CLOEXEC
        default:
            throw FileSystemOperationError.unsupportedNode(expected.kind)
        }

        try parent.withFileDescriptor { parentFD in
            try operationObserver?.didReach(
                .beforeExtendedAttributeOpen,
                component: component
            )
            let descriptor = openat(parentFD, component, flags)
            guard descriptor >= 0 else {
                if errno == ELOOP { throw FileSystemOperationError.symlinkEncountered(component) }
                throw posixError("openat")
            }
            defer { _ = Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            let actual = identity(metadata)
            guard actual == expected else {
                throw FileSystemOperationError.identityMismatch(expected: expected, actual: actual)
            }
            try value.withUnsafeBytes { bytes in
                guard fsetxattr(descriptor, key, bytes.baseAddress, bytes.count, 0, 0) == 0 else {
                    throw posixError("fsetxattr")
                }
            }
        }
    }

    public func setExtendedAttribute(
        on directory: DirectoryHandle,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws {
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            let actual = identity(metadata)
            guard actual == expected else {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: actual
                )
            }
            try value.withUnsafeBytes { bytes in
                guard fsetxattr(
                    descriptor,
                    key,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                ) == 0 else {
                    throw posixError("fsetxattr")
                }
            }
        }
    }

    public func fsync(_ directory: DirectoryHandle) throws {
        try directory.withFileDescriptor { descriptor in
            guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync") }
        }
    }


    private func validateTransactionOwned(
        _ directory: DirectoryHandle,
        modeFunction: String = "transactionOwned.mode"
    ) throws {
        guard directory.scope == .transactionOwned else {
            throw FileSystemOperationError.posix(
                function: "transactionOwned.scope",
                code: EPERM
            )
        }
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            guard nodeKind(metadata) == .directory else {
                throw FileSystemOperationError.notDirectory("transactionOwned")
            }
            guard metadata.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                throw FileSystemOperationError.posix(
                    function: modeFunction,
                    code: EPERM
                )
            }
        }
    }

    private func mintTransactionOwnedDirectory(
        _ directory: DirectoryHandle,
        expected: FileNodeIdentity?,
        name: String,
        modeFunction: String = "openTransactionOwnedDirectoryNoFollow.mode"
    ) throws -> DirectoryHandle {
        try directory.withFileDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError("fstat") }
            let actual = identity(metadata)
            guard actual.kind == .directory else {
                throw FileSystemOperationError.notDirectory(name)
            }
            guard metadata.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                throw FileSystemOperationError.posix(
                    function: modeFunction,
                    code: EPERM
                )
            }
            if let expected, expected != actual {
                throw FileSystemOperationError.identityMismatch(
                    expected: expected,
                    actual: actual
                )
            }
            return DirectoryHandle(
                fileDescriptor: try duplicateCloseOnExec(descriptor),
                scope: .transactionOwned
            )
        }
    }

    static func readDirectoryNames(
        stream: UnsafeMutablePointer<DIR>,
        readEntry: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?
    ) throws -> [String] {
        var names: [String] = []
        try visitDirectoryNames(
            stream: stream,
            readEntry: readEntry,
            visit: { names.append($0) }
        )
        return names
    }

    static func visitDirectoryNames(
        stream: UnsafeMutablePointer<DIR>,
        readEntry: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?,
        visit: (String) throws -> Void
    ) throws {
        while true {
            errno = 0
            guard let entry = readEntry(stream) else {
                let readError = errno
                guard readError == 0 else {
                    throw FileSystemOperationError.posix(
                        function: "readdir",
                        code: readError
                    )
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            try visit(name)
        }
    }

    static func readLinkTarget(
        fileDescriptor: Int32,
        initialCapacity: Int,
        readLink: (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int
    ) throws -> String {
        var capacity = max(1, initialCapacity)
        while true {
            var bytes = [UInt8](repeating: 0, count: capacity)
            let count = bytes.withUnsafeMutableBytes { buffer in
                readLink(
                    fileDescriptor,
                    buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    buffer.count
                )
            }
            guard count >= 0 else {
                throw FileSystemOperationError.posix(function: "freadlink", code: errno)
            }
            guard count >= capacity else {
                return String(decoding: bytes.prefix(count), as: UTF8.self)
            }
            guard capacity <= Int.max / 2 else {
                throw FileSystemOperationError.posix(
                    function: "freadlink",
                    code: ENAMETOOLONG
                )
            }
            capacity *= 2
        }
    }

    private func duplicateCloseOnExec(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw posixError("fcntl(F_DUPFD_CLOEXEC)")
        }
        return duplicate
    }

    private static func systemOpenRegularFile(
        parent: Int32,
        name: String,
        flags: Int32
    ) -> Int32 {
        Darwin.openat(parent, name, flags)
    }

    private static func systemSetMode(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
        fchmod(descriptor, mode)
    }

    private static func systemRenameExclusive(
        sourceFD: Int32,
        source: String,
        destinationFD: Int32,
        destination: String
    ) -> Int32 {
        renameatx_np(
            sourceFD,
            source,
            destinationFD,
            destination,
            UInt32(RENAME_EXCL)
        )
    }

    private static func systemRenameSwap(
        leftFD: Int32,
        left: String,
        rightFD: Int32,
        right: String
    ) -> Int32 {
        renameatx_np(
            leftFD,
            left,
            rightFD,
            right,
            UInt32(RENAME_SWAP)
        )
    }

    private func validatedAbsoluteComponents(of url: URL) throws -> [String] {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw FileSystemOperationError.invalidAbsoluteDirectoryURL(url)
        }
        var components = try url.pathComponents.dropFirst().map(validatedComponent)
        // Darwin exposes these immutable root aliases as symlinks. Normalize them
        // lexically so traversal remains descriptor-relative and no-follow.
        if let first = components.first, first == "var" || first == "tmp" || first == "etc" {
            components.insert("private", at: 0)
        }
        return components
    }

    private func validatedComponent(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.utf8.contains(0)
        else { throw FileSystemOperationError.invalidComponent(name) }
        return name
    }

    private func nodeKind(_ metadata: stat) -> ExtractionNodeKind {
        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            return metadata.st_nlink > 1 ? .hardLink : .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        case S_IFIFO: return .fifo
        case S_IFSOCK: return .socket
        case S_IFBLK: return .blockDevice
        case S_IFCHR: return .characterDevice
        default: return .unknown
        }
    }

    private func fileNodeMetadata(
        _ metadata: stat
    ) -> (
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        timestamps: FileTimestamps,
        statusChangeTimestamp: FileTimestamp
    ) {
        let logicalBytes = metadata.st_size > 0
            ? UInt64(metadata.st_size)
            : 0
        let blocks = metadata.st_blocks > 0
            ? UInt64(metadata.st_blocks)
            : 0
        let allocation = blocks.multipliedReportingOverflow(by: 512)
        let allocatedBytes = allocation.overflow ? .max : allocation.partialValue
        let timestamps = FileTimestamps(
            access: FileTimestamp(
                seconds: Int64(metadata.st_atimespec.tv_sec),
                nanoseconds: Int32(metadata.st_atimespec.tv_nsec)
            ),
            modification: FileTimestamp(
                seconds: Int64(metadata.st_mtimespec.tv_sec),
                nanoseconds: Int32(metadata.st_mtimespec.tv_nsec)
            )
        )
        let statusChangeTimestamp = FileTimestamp(
            seconds: Int64(metadata.st_ctimespec.tv_sec),
            nanoseconds: Int32(metadata.st_ctimespec.tv_nsec)
        )
        return (
            logicalBytes,
            allocatedBytes,
            timestamps,
            statusChangeTimestamp
        )
    }

    private func identity(_ value: stat) -> FileNodeIdentity {
        FileNodeIdentity(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino),
            generation: value.st_gen == 0 ? nil : UInt64(value.st_gen),
            kind: nodeKind(value)
        )
    }

    private func posixError(_ function: String) -> FileSystemOperationError {
        .posix(function: function, code: errno)
    }
}
