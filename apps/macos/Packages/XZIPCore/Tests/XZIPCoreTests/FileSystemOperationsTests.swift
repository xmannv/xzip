import Darwin
import Foundation
import XCTest
@testable import XZIPCore

private final class TraversalRecorder: DirectoryTraversalObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var fstatStorage: [(String, FileNodeIdentity)] = []
    private var retainedStorage: [String] = []

    func didFstat(component: String, identity: FileNodeIdentity) {
        lock.lock()
        fstatStorage.append((component, identity))
        lock.unlock()
    }

    func didRetain(component: String) throws {
        lock.lock()
        retainedStorage.append(component)
        lock.unlock()
    }

    var fstats: [(String, FileNodeIdentity)] {
        lock.lock()
        defer { lock.unlock() }
        return fstatStorage
    }

    var retained: [String] {
        lock.lock()
        defer { lock.unlock() }
        return retainedStorage
    }
}

private final class TraversalGateObserver: DirectoryTraversalObserving, @unchecked Sendable {
    private let gatedComponent: String
    private let recorder = TraversalRecorder()
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    init(gatedComponent: String) {
        self.gatedComponent = gatedComponent
    }

    func didFstat(component: String, identity: FileNodeIdentity) {
        recorder.didFstat(component: component, identity: identity)
    }

    func didRetain(component: String) throws {
        try recorder.didRetain(component: component)
        if component == gatedComponent {
            reached.signal()
            resume.wait()
        }
    }

    func waitUntilRetained(timeout: DispatchTime) -> DispatchTimeoutResult {
        reached.wait(timeout: timeout)
    }

    func release() {
        resume.signal()
    }

    var fstats: [(String, FileNodeIdentity)] { recorder.fstats }
}

private final class TraversalResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var succeededStorage = false
    private var errorStorage: Error?

    func storeSuccess() {
        lock.lock()
        succeededStorage = true
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        errorStorage = error
        lock.unlock()
    }

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeededStorage
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }
}


private final class OperationBoundaryObserver: FileSystemOperationObserving, @unchecked Sendable {
    private let action: (FileSystemOperationBoundary, String) throws -> Void

    init(action: @escaping (FileSystemOperationBoundary, String) throws -> Void) {
        self.action = action
    }

    func didReach(_ boundary: FileSystemOperationBoundary, component: String) throws {
        try action(boundary, component)
    }
}


private final class BooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func setTrue() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class OpenFlagsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flagsStorage: Int32?

    func call(parent: Int32, name: String, flags: Int32) -> Int32 {
        _ = parent
        _ = name
        lock.withLock { flagsStorage = flags }
        errno = EACCES
        return -1
    }

    var flags: Int32? {
        lock.withLock { flagsStorage }
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }

    var value: Int {
        lock.withLock { storage }
    }
}

private let systemExclusiveRename: @Sendable (
    Int32, String, Int32, String
) -> Int32 = { sourceFD, source, destinationFD, destination in
    renameatx_np(
        sourceFD,
        source,
        destinationFD,
        destination,
        UInt32(RENAME_EXCL)
    )
}

private let systemExchangeRename: @Sendable (
    Int32, String, Int32, String
) -> Int32 = { leftFD, left, rightFD, right in
    renameatx_np(
        leftFD,
        left,
        rightFD,
        right,
        UInt32(RENAME_SWAP)
    )
}

final class FileSystemOperationsTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemOperationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSetTimestampsNoFollowPreservesIdentityAndSetsExactValues() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("file.txt")
        try Data("bytes".utf8).write(to: file)
        let fileSystem = DarwinFileSystemOperations()
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        defer { rootHandle.close() }
        let before = try XCTUnwrap(
            fileSystem.statNoFollow(parent: rootHandle, name: "file.txt")
        )
        let expected = FileTimestamps(
            access: FileTimestamp(seconds: 1_700_000_000, nanoseconds: 123_456_789),
            modification: FileTimestamp(seconds: 1_700_000_100, nanoseconds: 987_654_321)
        )

        try fileSystem.setTimestampsNoFollow(
            parent: rootHandle,
            name: "file.txt",
            expected: before.identity,
            timestamps: expected
        )

        let after = try XCTUnwrap(
            fileSystem.statNoFollow(parent: rootHandle, name: "file.txt")
        )
        XCTAssertEqual(after.identity, before.identity)
        XCTAssertEqual(after.timestamps, expected)
    }

    func testExternalReadOnlyOpenUsesNonBlockingNoFollowFlags() throws {
        let root = try makeRoot()
        let recorder = OpenFlagsRecorder()
        let fileSystem = DarwinFileSystemOperations(
            openRegularFile: recorder.call
        )
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        defer { rootHandle.close() }

        XCTAssertThrowsError(try fileSystem.openRegularFileNoFollow(
            parent: rootHandle,
            name: "pipe",
            expected: nil,
            access: .readOnly
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .posix(function: "openat", code: EACCES)
            )
        }
        let flags = try XCTUnwrap(recorder.flags)
        XCTAssertNotEqual(flags & O_NONBLOCK, 0)
        XCTAssertNotEqual(flags & O_NOFOLLOW, 0)
        XCTAssertNotEqual(flags & O_CLOEXEC, 0)
        XCTAssertEqual(flags & O_ACCMODE, O_RDONLY)
    }

    func testStatNoFollowReportsSparseAllocationAndChangeTimestamp() throws {
        let root = try makeRoot()
        let sparse = root.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let descriptor = Darwin.open(sparse.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 1_048_576), 0)

        let fileSystem = DarwinFileSystemOperations()
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        defer { rootHandle.close() }
        let node = try XCTUnwrap(
            fileSystem.statNoFollow(parent: rootHandle, name: "sparse")
        )

        XCTAssertEqual(node.byteCount, 1_048_576)
        XCTAssertLessThan(node.allocatedByteCount, node.byteCount)
        XCTAssertNotNil(node.timestamps)
        XCTAssertNotNil(node.statusChangeTimestamp)
    }

    private func mismatchedIdentity(_ identity: FileNodeIdentity) -> FileNodeIdentity {
        FileNodeIdentity(
            device: identity.device,
            inode: identity.inode ^ 1,
            generation: identity.generation,
            kind: identity.kind
        )
    }

    private func extendedAttribute(
        at url: URL,
        key: String,
        options: Int32 = 0
    ) throws -> Data? {
        let size = getxattr(url.path, key, nil, 0, 0, options)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw FileSystemOperationError.posix(function: "getxattr", code: errno)
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let count = bytes.withUnsafeMutableBytes { buffer in
            getxattr(url.path, key, buffer.baseAddress, buffer.count, 0, options)
        }
        guard count >= 0 else {
            throw FileSystemOperationError.posix(function: "getxattr", code: errno)
        }
        return Data(bytes.prefix(count))
    }

    func testFinalSymlinkIsReportedWithoutFollowingTarget() throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        let node = try XCTUnwrap(fileSystem.statNoFollow(parent: handle, name: "link"))

        XCTAssertEqual(node.identity.kind, .symbolicLink)
        XCTAssertEqual(node.linkTarget, target.path)
    }


    func testSymlinkMetadataRemainsCoherentWhenEntryIsSwappedAfterLookup() throws {
        let root = try makeRoot()
        let link = root.appendingPathComponent("link")
        let replacement = root.appendingPathComponent("replacement")
        XCTAssertEqual(symlink("target-A", link.path), 0)
        XCTAssertEqual(symlink("target-B", replacement.path), 0)

        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let replacementIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "replacement")
        ).identity
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .afterSymlinkLookup, component == "link" else { return }
            try FileManager.default.removeItem(at: link)
            try FileManager.default.moveItem(at: replacement, to: link)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)

        let node = try XCTUnwrap(fileSystem.statNoFollow(parent: handle, name: "link"))

        XCTAssertEqual(node.identity, replacementIdentity)
        XCTAssertEqual(node.linkTarget, "target-B")
    }

    func testDescriptorBoundLinkReadGrowsBeyondInitialBuffer() throws {
        let target = String(repeating: "long-target/", count: 400)

        let actual = try DarwinFileSystemOperations.readLinkTarget(
            fileDescriptor: -1,
            initialCapacity: 8
        ) { _, buffer, capacity in
            let bytes = Array(target.utf8)
            let count = min(bytes.count, capacity)
            if let buffer, count > 0 {
                _ = bytes.withUnsafeBytes { source in
                    memcpy(buffer, source.baseAddress, count)
                }
            }
            return count
        }

        XCTAssertEqual(actual, target)
    }

    func testParentSymlinkCannotBeOpenedAsDirectory() throws {
        let root = try makeRoot()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.openRelativeDirectoryNoFollow(
            root: handle,
            components: ["link"],
            expected: nil
        )) { error in
            guard case FileSystemOperationError.symlinkEncountered("link") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAbsoluteRootTraversalRejectsIntermediateSymlink() throws {
        let root = try makeRoot()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        let leaf = real.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let fileSystem = DarwinFileSystemOperations()

        XCTAssertThrowsError(
            try fileSystem.openDirectoryNoFollow(at: link.appendingPathComponent("leaf"))
        ) { error in
            guard case FileSystemOperationError.symlinkEncountered("link") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAbsoluteRootTraversalRejectsSwappedIntermediateComponent() throws {
        let root = try makeRoot()
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let observer = TraversalGateObserver(gatedComponent: "parent")
        let fileSystem = DarwinFileSystemOperations(traversalObserver: observer)
        let result = TraversalResultBox()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try fileSystem.openDirectoryNoFollow(at: child)
                result.storeSuccess()
            } catch {
                result.store(error: error)
            }
            completed.signal()
        }

        let retained = observer.waitUntilRetained(timeout: .now() + 5)
        if retained != .success {
            observer.release()
            return XCTFail("Traversal did not retain the parent descriptor")
        }
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        observer.release()

        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(result.succeeded)
        guard let traversalError = result.error,
              case FileSystemOperationError.symlinkEncountered("child") = traversalError
        else {
            return XCTFail("Unexpected result: \(String(describing: result.error))")
        }
        XCTAssertFalse(observer.fstats.map(\.0).contains("child"))
    }

    func testAbsoluteRootTraversalFstatsEveryOpenedComponent() throws {
        let root = try makeRoot()
        let leaf = root
            .appendingPathComponent("one", isDirectory: true)
            .appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let observer = TraversalRecorder()
        let fileSystem = DarwinFileSystemOperations(traversalObserver: observer)

        _ = try fileSystem.openDirectoryNoFollow(at: leaf)

        var expectedComponents = Array(leaf.pathComponents.dropFirst())
        if let first = expectedComponents.first,
           first == "var" || first == "tmp" || first == "etc" {
            expectedComponents.insert("private", at: 0)
        }
        XCTAssertEqual(observer.fstats.map(\.0), ["/"] + expectedComponents)
        XCTAssertEqual(observer.retained, expectedComponents)
    }

    func testAbsoluteRootTraversalReturnsExpectedFinalIdentity() throws {
        let root = try makeRoot()
        let leaf = root.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let fileSystem = DarwinFileSystemOperations()
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        let expected = try XCTUnwrap(
            fileSystem.statNoFollow(parent: rootHandle, name: "leaf")
        ).identity

        let leafHandle = try fileSystem.openDirectoryNoFollow(at: leaf)

        XCTAssertEqual(try fileSystem.identity(of: leafHandle), expected)
    }

    func testOpenDirectoryRejectsExpectedIdentityMismatch() throws {
        let root = try makeRoot()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let fileSystem = DarwinFileSystemOperations()
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        let actual = try XCTUnwrap(
            fileSystem.statNoFollow(parent: rootHandle, name: "child")
        ).identity
        let expected = mismatchedIdentity(actual)

        XCTAssertThrowsError(try fileSystem.openDirectoryNoFollow(
            parent: rootHandle,
            name: "child",
            expected: expected
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: actual)
            )
        }
    }

    func testCreateDirectoryIsExclusiveAndUsesOwnerOnlyPermissions() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        let identity = try fileSystem.createDirectoryExclusive(parent: handle, name: "created")

        XCTAssertEqual(identity.kind, .directory)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("created").path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertThrowsError(
            try fileSystem.createDirectoryExclusive(parent: handle, name: "created")
        ) { error in
            XCTAssertEqual(error as? FileSystemOperationError, .alreadyExists("created"))
        }
    }


    func testTransactionDirectoryEstablishesExactModeBeforeOwnership() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let reachedBoundary = BooleanBox()
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .beforeTransactionModeEstablishment,
                  component == ".xzip-transaction"
            else { return }
            reachedBoundary.setTrue()
            XCTAssertEqual(chmod(transactionURL.path, 0o4700), 0)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)
        let external = try fileSystem.openDirectoryNoFollow(at: root)

        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )

        XCTAssertTrue(reachedBoundary.value)
        XCTAssertEqual(transaction.scope, .transactionOwned)
        let mode = try transaction.withFileDescriptor { descriptor -> mode_t in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw FileSystemOperationError.posix(function: "fstat", code: errno)
            }
            return metadata.st_mode
        }
        XCTAssertEqual(mode & mode_t(0o7777), mode_t(0o700))
    }

    func testTransactionDirectoryModeFailureCleansCreatedRoot() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .beforeTransactionModeEstablishment,
                  component == ".xzip-transaction"
            else { return }
            XCTAssertEqual(chmod(transactionURL.path, 0o500), 0)
        }
        let fileSystem = DarwinFileSystemOperations(
            operationObserver: observer,
            setMode: { _, _ in 0 }
        )
        let external = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .posix(function: "createTransactionDirectoryExclusive.mode", code: EPERM)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: transactionURL.path))
    }


    func testTransactionDirectoryModeFailureCleanupBoundariesResumeExactName() throws {
        for boundary in [
            FileSystemOperationBoundary.afterOwnedFinalVerification,
            .afterOwnedDirectRemoval,
            .afterOwnedParentSync,
        ] {
            let root = try makeRoot()
            XCTAssertEqual(chmod(root.path, 0o700), 0)
            let component = ".xzip-transaction"
            let transactionURL = root.appendingPathComponent(
                component,
                isDirectory: true
            )
            var didThrow = false
            let observer = OperationBoundaryObserver { reached, observedComponent in
                guard observedComponent == component else { return }
                if reached == .beforeTransactionModeEstablishment {
                    XCTAssertEqual(chmod(transactionURL.path, 0o500), 0)
                }
                guard reached == boundary, !didThrow else { return }
                didThrow = true
                throw CocoaError(.fileWriteUnknown)
            }
            let fileSystem = DarwinFileSystemOperations(
                operationObserver: observer,
                setMode: { _, _ in 0 }
            )
            let externalParent = try fileSystem.openDirectoryNoFollow(at: root)
            let parentIdentity = try fileSystem.identity(of: externalParent)
            externalParent.close()
            let parent = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                at: root,
                expected: parentIdentity
            )

            XCTAssertThrowsError(
                try fileSystem.createTransactionDirectoryExclusive(
                    parent: parent,
                    name: component
                )
            ) { error in
                XCTAssertEqual(
                    error as? FileSystemOperationError,
                    .restoreFailed(name: component)
                )
            }
            let observed = try fileSystem.statNoFollow(
                parent: parent,
                name: component
            )
            XCTAssertEqual(
                observed != nil,
                boundary == .afterOwnedFinalVerification
            )

            if let observed {
                try fileSystem.removeOwnedNoFollow(
                    parent: parent,
                    name: component,
                    expected: observed.identity
                )
            } else {
                try fileSystem.fsync(parent)
            }
            XCTAssertNil(
                try fileSystem.statNoFollow(
                    parent: parent,
                    name: component
                )
            )
            XCTAssertTrue(try fileSystem.listNoFollow(parent).isEmpty)
            parent.close()
        }
    }

    func testExclusiveRenameNeverClobbersExistingDestination() throws {
        let root = try makeRoot()
        try Data("source".utf8).write(to: root.appendingPathComponent("source"))
        try Data("external".utf8).write(to: root.appendingPathComponent("destination"))
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.renameExclusive(
            fromParent: handle,
            fromName: "source",
            toParent: handle,
            toName: "destination"
        )) { error in
            XCTAssertEqual(error as? FileSystemOperationError, .alreadyExists("destination"))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source"), encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("destination"), encoding: .utf8), "external")
    }

    func testExclusiveRenameRejectsUnsupportedVolumeWithoutFallback() throws {
        let root = try makeRoot()
        try Data("source".utf8).write(to: root.appendingPathComponent("source"))
        let fileSystem = DarwinFileSystemOperations(exclusiveRename: { _, _, _, _ in
            errno = ENOTSUP
            return -1
        })
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.renameExclusive(
            fromParent: handle,
            fromName: "source",
            toParent: handle,
            toName: "destination"
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .unsupportedExclusiveRename
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("source").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("destination").path
        ))
    }

    private func assertObservedSwapUnsupported(
        _ code: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try makeRoot()
        try Data("left".utf8).write(to: root.appendingPathComponent("left"))
        try Data("right".utf8).write(to: root.appendingPathComponent("right"))
        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "right")
        ).identity
        let exclusiveCalls = InvocationCounter()
        let exchangeCalls = InvocationCounter()
        let fileSystem = DarwinFileSystemOperations(
            exclusiveRename: { sourceFD, source, destinationFD, destination in
                _ = exclusiveCalls.increment()
                return systemExclusiveRename(sourceFD, source, destinationFD, destination)
            },
            exchangeRename: { _, _, _, _ in
                _ = exchangeCalls.increment()
                errno = code
                return -1
            }
        )

        XCTAssertThrowsError(try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        ), file: file, line: line) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .unsupportedTransactionalSwap,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(exchangeCalls.value, 1, file: file, line: line)
        XCTAssertEqual(exclusiveCalls.value, 0, file: file, line: line)
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "left")?.identity,
            leftIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "right")?.identity,
            rightIdentity,
            file: file,
            line: line
        )
    }

    func testObservedMoveReturnsUnexpectedCapturedIdentityWithoutCompensation() throws {
        let root = try makeRoot()
        try Data("expected".utf8).write(to: root.appendingPathComponent("source"))
        try Data("foreign".utf8).write(to: root.appendingPathComponent("foreign"))
        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let expectedIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "source")
        ).identity
        let foreignIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "foreign")
        ).identity
        let renameCalls = InvocationCounter()
        let fileSystem = DarwinFileSystemOperations(
            exclusiveRename: { sourceFD, source, destinationFD, destination in
                if renameCalls.increment() == 1 {
                    XCTAssertEqual(renameat(sourceFD, source, sourceFD, "expected-held"), 0)
                    XCTAssertEqual(renameat(sourceFD, "foreign", sourceFD, source), 0)
                }
                return systemExclusiveRename(sourceFD, source, destinationFD, destination)
            },
            exchangeRename: systemExchangeRename
        )

        let observation = try fileSystem.moveExclusiveObserved(
            fromParent: handle,
            fromName: "source",
            toParent: handle,
            toName: "destination",
            expectedSource: expectedIdentity
        )

        XCTAssertNil(observation.sourceIdentity)
        XCTAssertEqual(observation.destinationIdentity, foreignIdentity)
        XCTAssertEqual(renameCalls.value, 1)
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "expected-held")?.identity,
            expectedIdentity
        )
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "destination")?.identity,
            foreignIdentity
        )
    }

    func testObservedSwapExchangesRegularFiles() throws {
        let root = try makeRoot()
        let leftURL = root.appendingPathComponent("left")
        let rightURL = root.appendingPathComponent("right")
        try Data("left".utf8).write(to: leftURL)
        try Data("right".utf8).write(to: rightURL)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "right")
        ).identity

        let observation = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        )

        XCTAssertEqual(observation.leftIdentity, rightIdentity)
        XCTAssertEqual(observation.rightIdentity, leftIdentity)
        XCTAssertEqual(try String(contentsOf: leftURL, encoding: .utf8), "right")
        XCTAssertEqual(try String(contentsOf: rightURL, encoding: .utf8), "left")
    }

    func testObservedSwapReturnsBothPostStateIdentitiesWhenRightChangesInsideSyscall() throws {
        let root = try makeRoot()
        let stagedURL = root.appendingPathComponent("staged", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        try Data("staged".utf8).write(to: stagedURL.appendingPathComponent("item"))
        try Data("existing".utf8).write(to: destinationURL.appendingPathComponent("item"))
        try Data("foreign".utf8).write(to: destinationURL.appendingPathComponent("foreign"))
        let baseline = DarwinFileSystemOperations()
        let stagedParent = try baseline.openDirectoryNoFollow(at: stagedURL)
        let destinationParent = try baseline.openDirectoryNoFollow(at: destinationURL)
        let stagedIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: stagedParent, name: "item")
        ).identity
        let existingIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: destinationParent, name: "item")
        ).identity
        let foreignIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: destinationParent, name: "foreign")
        ).identity
        let swapCalls = InvocationCounter()
        let fileSystem = DarwinFileSystemOperations(
            exclusiveRename: systemExclusiveRename,
            exchangeRename: { leftFD, left, rightFD, right in
                _ = swapCalls.increment()
                XCTAssertEqual(unlinkat(rightFD, right, 0), 0)
                XCTAssertEqual(renameat(rightFD, "foreign", rightFD, right), 0)
                return systemExchangeRename(leftFD, left, rightFD, right)
            }
        )

        let observation = try fileSystem.swapObserved(
            leftParent: stagedParent,
            leftName: "item",
            expectedLeft: stagedIdentity,
            rightParent: destinationParent,
            rightName: "item",
            expectedRight: existingIdentity
        )

        XCTAssertEqual(observation.leftIdentity, foreignIdentity)
        XCTAssertEqual(observation.rightIdentity, stagedIdentity)
        XCTAssertEqual(swapCalls.value, 1)
        XCTAssertEqual(
            try baseline.statNoFollow(parent: stagedParent, name: "item")?.identity,
            foreignIdentity
        )
        XCTAssertEqual(
            try baseline.statNoFollow(parent: destinationParent, name: "item")?.identity,
            stagedIdentity
        )
    }

    func testObservedSwapReportsMutationAfterSyscallBeforeObservation() throws {
        let root = try makeRoot()
        try Data("left".utf8).write(to: root.appendingPathComponent("left"))
        try Data("right".utf8).write(to: root.appendingPathComponent("right"))
        try Data("foreign".utf8).write(to: root.appendingPathComponent("foreign"))
        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "right")
        ).identity
        let foreignIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "foreign")
        ).identity
        let swapCalls = InvocationCounter()
        let fileSystem = DarwinFileSystemOperations(
            exclusiveRename: systemExclusiveRename,
            exchangeRename: { leftFD, left, rightFD, right in
                _ = swapCalls.increment()
                let result = systemExchangeRename(leftFD, left, rightFD, right)
                guard result == 0 else { return result }
                XCTAssertEqual(unlinkat(leftFD, left, 0), 0)
                XCTAssertEqual(renameat(leftFD, "foreign", leftFD, left), 0)
                return 0
            }
        )

        let observation = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        )

        XCTAssertEqual(observation.leftIdentity, foreignIdentity)
        XCTAssertEqual(observation.rightIdentity, leftIdentity)
        XCTAssertEqual(swapCalls.value, 1)
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "left")?.identity,
            foreignIdentity
        )
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "right")?.identity,
            leftIdentity
        )
    }

    func testObservedSwapReverseRaceReturnsObservedOccupancyWithoutThirdMutation() throws {
        let root = try makeRoot()
        try Data("left".utf8).write(to: root.appendingPathComponent("left"))
        try Data("right".utf8).write(to: root.appendingPathComponent("right"))
        try Data("foreign".utf8).write(to: root.appendingPathComponent("foreign"))
        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "right")
        ).identity
        let foreignIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "foreign")
        ).identity
        let swapCalls = InvocationCounter()
        let fileSystem = DarwinFileSystemOperations(
            exclusiveRename: systemExclusiveRename,
            exchangeRename: { leftFD, left, rightFD, right in
                if swapCalls.increment() == 2 {
                    XCTAssertEqual(unlinkat(rightFD, right, 0), 0)
                    XCTAssertEqual(renameat(rightFD, "foreign", rightFD, right), 0)
                }
                return systemExchangeRename(leftFD, left, rightFD, right)
            }
        )

        let first = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        )
        XCTAssertEqual(first.leftIdentity, rightIdentity)
        XCTAssertEqual(first.rightIdentity, leftIdentity)

        let second = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: rightIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: leftIdentity
        )

        XCTAssertEqual(second.leftIdentity, foreignIdentity)
        XCTAssertEqual(second.rightIdentity, rightIdentity)
        XCTAssertEqual(swapCalls.value, 2)
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "left")?.identity,
            foreignIdentity
        )
        XCTAssertEqual(
            try baseline.statNoFollow(parent: handle, name: "right")?.identity,
            rightIdentity
        )
    }

    func testObservedSwapExchangesNonemptyDirectorySubtrees() throws {
        let root = try makeRoot()
        let leftURL = root.appendingPathComponent("left", isDirectory: true)
        let rightURL = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: leftURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: rightURL, withIntermediateDirectories: false)
        try Data("left-child".utf8).write(to: leftURL.appendingPathComponent("left.txt"))
        try Data("right-child".utf8).write(to: rightURL.appendingPathComponent("right.txt"))
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "right")
        ).identity

        let observation = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        )

        XCTAssertEqual(observation.leftIdentity, rightIdentity)
        XCTAssertEqual(observation.rightIdentity, leftIdentity)
        XCTAssertEqual(
            try String(contentsOf: leftURL.appendingPathComponent("right.txt"), encoding: .utf8),
            "right-child"
        )
        XCTAssertEqual(
            try String(contentsOf: rightURL.appendingPathComponent("left.txt"), encoding: .utf8),
            "left-child"
        )
    }

    func testObservedSwapExchangesSymlinkLeavesWithoutFollowingTargets() throws {
        let root = try makeRoot()
        let leftURL = root.appendingPathComponent("left")
        let rightURL = root.appendingPathComponent("right")
        XCTAssertEqual(symlink("left-target", leftURL.path), 0)
        XCTAssertEqual(symlink("right-target", rightURL.path), 0)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let leftIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "left")
        ).identity
        let rightIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "right")
        ).identity

        let observation = try fileSystem.swapObserved(
            leftParent: handle,
            leftName: "left",
            expectedLeft: leftIdentity,
            rightParent: handle,
            rightName: "right",
            expectedRight: rightIdentity
        )

        XCTAssertEqual(observation.leftIdentity, rightIdentity)
        XCTAssertEqual(observation.rightIdentity, leftIdentity)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: leftURL.path),
            "right-target"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: rightURL.path),
            "left-target"
        )
    }

    func testObservedSwapENOTSUPFailsWithoutMoveFallback() throws {
        try assertObservedSwapUnsupported(ENOTSUP)
    }

    func testObservedSwapEINVALFailsWithoutMoveFallback() throws {
        try assertObservedSwapUnsupported(EINVAL)
    }

    func testObservedSwapEXDEVFailsWithoutMoveFallback() throws {
        try assertObservedSwapUnsupported(EXDEV)
    }

    func testOwnedRemoveRejectsExternalDirectoryHandle() throws {
        let root = try makeRoot()
        try Data().write(to: root.appendingPathComponent("victim"))
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let identity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "victim")
        ).identity

        XCTAssertThrowsError(try fileSystem.removeOwnedNoFollow(
            parent: handle,
            name: "victim",
            expected: identity
        ))
    }

    func testOwnedRemoveRejectsNonOwnerOnlyTransactionRoot() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let victimURL = transactionURL.appendingPathComponent("victim")
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )
        try Data().write(to: victimURL)
        XCTAssertEqual(chmod(transactionURL.path, 0o755), 0)
        let identity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "victim")
        ).identity

        XCTAssertThrowsError(try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: identity
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .posix(function: "removeOwnedNoFollow.mode", code: EPERM)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimURL.path))
    }

    func testOwnedRemoveRejectsIdentityMismatchWithoutRemovingNode() throws {
        let root = try makeRoot()
        let victimURL = root
            .appendingPathComponent(".xzip-transaction", isDirectory: true)
            .appendingPathComponent("victim")
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )
        try Data().write(to: victimURL)
        let actual = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "victim")
        ).identity
        let expected = mismatchedIdentity(actual)

        XCTAssertThrowsError(try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: actual)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimURL.path))
    }


    func testOwnedRemoveRejectsReplacementSwappedBeforeDirectRemoval() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let victimURL = transactionURL.appendingPathComponent("victim")
        let replacementURL = transactionURL.appendingPathComponent("replacement")
        let baseline = DarwinFileSystemOperations()
        let external = try baseline.openDirectoryNoFollow(at: root)
        let transaction = try baseline.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )
        try Data("expected".utf8).write(to: victimURL)
        try Data("replacement".utf8).write(to: replacementURL)
        let expected = try XCTUnwrap(
            baseline.statNoFollow(parent: transaction, name: "victim")
        ).identity
        let replacementIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: transaction, name: "replacement")
        ).identity
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .beforeOwnedDirectRemoval, component == "victim" else { return }
            try FileManager.default.removeItem(at: victimURL)
            try FileManager.default.moveItem(at: replacementURL, to: victimURL)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)

        XCTAssertThrowsError(try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: replacementIdentity)
            )
        }
        XCTAssertEqual(try String(contentsOf: victimURL, encoding: .utf8), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
        XCTAssertEqual(try fileSystem.listNoFollow(transaction).map(\.name), ["victim"])
    }


    func testOwnedRemoveDoesNotUseHiddenQuarantineNames() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let victimURL = transactionURL.appendingPathComponent("victim")
        let collisionURL = transactionURL.appendingPathComponent(".xzip-remove-fixed")
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )
        try Data("victim".utf8).write(to: victimURL)
        try Data("collision".utf8).write(to: collisionURL)
        let expected = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "victim")
        ).identity

        try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: victimURL.path))
        XCTAssertEqual(try String(contentsOf: collisionURL, encoding: .utf8), "collision")
    }

    func testOwnedRemoveDeletesVerifiedTransactionNode() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent(".xzip-transaction", isDirectory: true)
        let victimURL = transactionURL.appendingPathComponent("victim")
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )
        try Data().write(to: victimURL)
        let identity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "victim")
        ).identity

        try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: identity
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: victimURL.path))
    }

    func testFileExtendedAttributeRequiresExpectedIdentity() throws {
        let root = try makeRoot()
        let fileURL = root.appendingPathComponent("file")
        let key = "com.xzip.tests.file"
        try Data("contents".utf8).write(to: fileURL)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let actual = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "file")
        ).identity
        let expected = mismatchedIdentity(actual)

        XCTAssertThrowsError(try fileSystem.setExtendedAttributeNoFollow(
            parent: handle,
            name: "file",
            expected: expected,
            key: key,
            value: Data("value".utf8)
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: actual)
            )
        }
        XCTAssertNil(try extendedAttribute(at: fileURL, key: key))
    }

    func testFileExtendedAttributeIsSetOnVerifiedNode() throws {
        let root = try makeRoot()
        let fileURL = root.appendingPathComponent("file")
        let key = "com.xzip.tests.file"
        let value = Data("value".utf8)
        try Data("contents".utf8).write(to: fileURL)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let expected = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "file")
        ).identity

        try fileSystem.setExtendedAttributeNoFollow(
            parent: handle,
            name: "file",
            expected: expected,
            key: key,
            value: value
        )

        XCTAssertEqual(try extendedAttribute(at: fileURL, key: key), value)
    }


    func testSymlinkExtendedAttributeIsSetOnLinkNodeWithoutTouchingTarget() throws {
        let root = try makeRoot()
        let targetURL = root.appendingPathComponent("target")
        let linkURL = root.appendingPathComponent("link")
        let key = "com.xzip.tests.symlink"
        let value = Data("value".utf8)
        try Data("contents".utf8).write(to: targetURL)
        XCTAssertEqual(symlink("target", linkURL.path), 0)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let expected = try XCTUnwrap(
            fileSystem.statNoFollow(parent: handle, name: "link")
        ).identity

        try fileSystem.setExtendedAttributeNoFollow(
            parent: handle,
            name: "link",
            expected: expected,
            key: key,
            value: value
        )

        XCTAssertEqual(
            try extendedAttribute(at: linkURL, key: key, options: XATTR_NOFOLLOW),
            value
        )
        XCTAssertNil(try extendedAttribute(at: targetURL, key: key))
    }


    func testSymlinkExtendedAttributeRejectsReplacementBeforeFinalOpen() throws {
        let root = try makeRoot()
        let targetAURL = root.appendingPathComponent("target-A")
        let targetBURL = root.appendingPathComponent("target-B")
        let linkURL = root.appendingPathComponent("link")
        let originalURL = root.appendingPathComponent("original")
        let replacementURL = root.appendingPathComponent("replacement")
        let key = "com.xzip.tests.symlink-replacement"
        try Data("target-A".utf8).write(to: targetAURL)
        try Data("target-B".utf8).write(to: targetBURL)
        XCTAssertEqual(symlink("target-A", linkURL.path), 0)
        XCTAssertEqual(symlink("target-B", replacementURL.path), 0)

        let baseline = DarwinFileSystemOperations()
        let handle = try baseline.openDirectoryNoFollow(at: root)
        let expected = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "link")
        ).identity
        let replacementIdentity = try XCTUnwrap(
            baseline.statNoFollow(parent: handle, name: "replacement")
        ).identity
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .beforeExtendedAttributeOpen, component == "link" else { return }
            try FileManager.default.moveItem(at: linkURL, to: originalURL)
            try FileManager.default.moveItem(at: replacementURL, to: linkURL)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)

        XCTAssertThrowsError(try fileSystem.setExtendedAttributeNoFollow(
            parent: handle,
            name: "link",
            expected: expected,
            key: key,
            value: Data("value".utf8)
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: replacementIdentity)
            )
        }
        XCTAssertNil(try extendedAttribute(at: originalURL, key: key, options: XATTR_NOFOLLOW))
        XCTAssertNil(try extendedAttribute(at: linkURL, key: key, options: XATTR_NOFOLLOW))
        XCTAssertNil(try extendedAttribute(at: targetAURL, key: key))
        XCTAssertNil(try extendedAttribute(at: targetBURL, key: key))
    }

    func testDirectoryExtendedAttributeRequiresExpectedIdentity() throws {
        let root = try makeRoot()
        let key = "com.xzip.tests.directory"
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let actual = try fileSystem.identity(of: handle)
        let expected = mismatchedIdentity(actual)

        XCTAssertThrowsError(try fileSystem.setExtendedAttribute(
            on: handle,
            expected: expected,
            key: key,
            value: Data("value".utf8)
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .identityMismatch(expected: expected, actual: actual)
            )
        }
        XCTAssertNil(try extendedAttribute(at: root, key: key))
    }

    func testDirectoryExtendedAttributeIsSetOnVerifiedHandle() throws {
        let root = try makeRoot()
        let key = "com.xzip.tests.directory"
        let value = Data("value".utf8)
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        let expected = try fileSystem.identity(of: handle)

        try fileSystem.setExtendedAttribute(
            on: handle,
            expected: expected,
            key: key,
            value: value
        )

        XCTAssertEqual(try extendedAttribute(at: root, key: key), value)
    }

    func testInvalidComponentIsRejectedBeforeSyscall() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.statNoFollow(parent: handle, name: "../escape")) {
            error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .invalidComponent("../escape")
            )
        }
    }

    func testReturnedDirectoryHandlesRemainCloseOnExec() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let duplicate = try fileSystem.openRelativeDirectoryNoFollow(
            root: external,
            components: [],
            expected: nil
        )
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: ".xzip-transaction"
        )

        for (label, handle) in [
            ("external", external),
            ("duplicate", duplicate),
            ("transaction", transaction)
        ] {
            let flags = try handle.withFileDescriptor { fcntl($0, F_GETFD) }
            XCTAssertGreaterThanOrEqual(flags, 0, label)
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0, label)
        }
    }

    func testClosedDirectoryHandleRejectsFurtherSyscalls() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)
        handle.close()

        XCTAssertThrowsError(try fileSystem.listNoFollow(handle)) { error in
            XCTAssertEqual(error as? FileSystemOperationError, .closedDirectoryHandle)
        }
    }


    func testDirectoryReadErrorAfterPartialEntryThrows() throws {
        let root = try makeRoot()
        guard let stream = opendir(root.path) else {
            throw FileSystemOperationError.posix(function: "opendir", code: errno)
        }
        defer { closedir(stream) }
        let entry = UnsafeMutablePointer<dirent>.allocate(capacity: 1)
        entry.initialize(to: dirent())
        defer {
            entry.deinitialize(count: 1)
            entry.deallocate()
        }
        withUnsafeMutablePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                _ = strcpy($0, "partial")
            }
        }
        var callCount = 0

        XCTAssertThrowsError(try DarwinFileSystemOperations.readDirectoryNames(
            stream: stream,
            readEntry: { _ in
                defer { callCount += 1 }
                if callCount == 0 {
                    errno = 0
                    return entry
                }
                errno = EIO
                return nil
            }
        )) { error in
            XCTAssertEqual(
                error as? FileSystemOperationError,
                .posix(function: "readdir", code: EIO)
            )
        }
    }

    func testDirectoryNameEnumerationStopsReadingWhenVisitorThrows() throws {
        let root = try makeRoot()
        guard let stream = opendir(root.path) else {
            throw FileSystemOperationError.posix(function: "opendir", code: errno)
        }
        defer { closedir(stream) }
        let entry = UnsafeMutablePointer<dirent>.allocate(capacity: 1)
        entry.initialize(to: dirent())
        defer {
            entry.deinitialize(count: 1)
            entry.deallocate()
        }
        withUnsafeMutablePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                _ = strcpy($0, "first")
            }
        }
        var readCount = 0

        XCTAssertThrowsError(try DarwinFileSystemOperations.visitDirectoryNames(
            stream: stream,
            readEntry: { _ in
                readCount += 1
                errno = 0
                return entry
            },
            visit: { _ in throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(readCount, 1)
    }

    func testDirectoryHandleCloseIsIdempotent() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let handle = try fileSystem.openDirectoryNoFollow(at: root)

        handle.close()
        handle.close()

        XCTAssertThrowsError(try fileSystem.identity(of: handle)) { error in
            XCTAssertEqual(error as? FileSystemOperationError, .closedDirectoryHandle)
        }
    }


    func testOpenTransactionOwnedDirectoryAbsoluteReconstitutesVerifiedCapability() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent("transaction", isDirectory: true)
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let created = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )
        let expected = try fileSystem.identity(of: created)
        created.close()

        let reopened = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: transactionURL,
            expected: expected
        )

        XCTAssertEqual(try fileSystem.identity(of: reopened), expected)
        XCTAssertEqual(reopened.scope, .transactionOwned)
    }

    func testOpenTransactionOwnedReservedChildRequiresOwnedParentAndExactMode() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let namespace = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "namespace"
        )
        let child = try fileSystem.createTransactionDirectoryExclusive(
            parent: namespace,
            name: "reserved"
        )
        let expected = try fileSystem.identity(of: child)
        child.close()

        let reopened = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "reserved",
            expected: nil
        )
        XCTAssertEqual(try fileSystem.identity(of: reopened), expected)

        let publicParent = try fileSystem.openDirectoryNoFollow(at: root)
        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: publicParent,
            name: "namespace",
            expected: nil
        ))
    }

    func testOpenTransactionOwnedDirectoryRejectsMismatchSymlinkFileAndWrongMode() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let namespace = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "namespace"
        )
        let expected = try fileSystem.identity(of: namespace)
        let namespaceURL = root.appendingPathComponent("namespace", isDirectory: true)

        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespaceURL,
            expected: mismatchedIdentity(expected)
        ))

        let wrongModeURL = namespaceURL.appendingPathComponent("wrong-mode", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongModeURL, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(wrongModeURL.path, 0o755), 0)
        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "wrong-mode",
            expected: nil
        ))

        let fileURL = namespaceURL.appendingPathComponent("file")
        try Data().write(to: fileURL)
        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "file",
            expected: nil
        ))

        let symlinkURL = namespaceURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: wrongModeURL.path)
        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "link",
            expected: nil
        ))
    }

    func testAdoptTransactionOwnedDirectoryRepairsArchiveModeToExact0700() throws {
        // An external extractor recreates archive directories with the archive's
        // own mode. `openTransactionOwnedDirectoryNoFollow` rejects those (see
        // `testOpenTransactionOwnedDirectoryRejectsMismatchSymlinkFileAndWrongMode`),
        // so adoption exists to tighten the mode instead of the caller having to
        // relax the requirement.
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let namespace = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "namespace"
        )
        let namespaceURL = root.appendingPathComponent("namespace", isDirectory: true)

        let stagedURL = namespaceURL.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(stagedURL.path, 0o755), 0)

        // Strict open rejects it; adoption accepts it and repairs the mode.
        XCTAssertThrowsError(try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "staged",
            expected: nil
        ))

        let probe = try fileSystem.openDirectoryNoFollow(at: stagedURL)
        let expected = try fileSystem.identity(of: probe)
        probe.close()
        let adopted = try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "staged",
            expected: nil
        )
        defer { adopted.close() }

        var meta = stat()
        XCTAssertEqual(lstat(stagedURL.path, &meta), 0)
        XCTAssertEqual(meta.st_mode & 0o7777, 0o700, "adoption must repair the mode to exact 0700")
        // Adoption must not replace the node: same inode/device as before.
        XCTAssertEqual(try fileSystem.identity(of: adopted), expected)

        // The returned handle carries owned authority, so the strict open that
        // previously failed now succeeds against the repaired directory.
        let reopened = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "staged",
            expected: expected
        )
        reopened.close()
    }

    func testAdoptTransactionOwnedDirectoryRejectsSymlinkFileMismatchAndPublicParent() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let namespace = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "namespace"
        )
        let namespaceURL = root.appendingPathComponent("namespace", isDirectory: true)

        // A directory outside the transaction that must never be reached or chmod'ed.
        let outsideURL = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outsideURL.path, 0o755), 0)

        // Symlink pointing at it: adoption must refuse and leave the target's mode alone.
        let linkURL = namespaceURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: outsideURL.path
        )
        XCTAssertThrowsError(try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "link",
            expected: nil
        ))
        var outsideMeta = stat()
        XCTAssertEqual(lstat(outsideURL.path, &outsideMeta), 0)
        XCTAssertEqual(
            outsideMeta.st_mode & 0o7777, 0o755,
            "adoption must not follow a symlink and chmod its target"
        )

        // A regular file is not adoptable.
        let fileURL = namespaceURL.appendingPathComponent("file")
        try Data().write(to: fileURL)
        XCTAssertThrowsError(try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "file",
            expected: nil
        ))

        // Identity mismatch still wins over repair.
        let stagedURL = namespaceURL.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(stagedURL.path, 0o755), 0)
        let stagedProbe = try fileSystem.openDirectoryNoFollow(at: stagedURL)
        let actual = try fileSystem.identity(of: stagedProbe)
        stagedProbe.close()
        XCTAssertThrowsError(try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: "staged",
            expected: mismatchedIdentity(actual)
        ))
        var stagedMeta = stat()
        XCTAssertEqual(lstat(stagedURL.path, &stagedMeta), 0)
        XCTAssertEqual(
            stagedMeta.st_mode & 0o7777, 0o755,
            "a rejected adoption must not have repaired the mode"
        )

        // Adoption still requires an owned parent; a public parent is refused.
        let publicParent = try fileSystem.openDirectoryNoFollow(at: root)
        XCTAssertThrowsError(try fileSystem.adoptTransactionOwnedDirectoryNoFollow(
            parent: publicParent,
            name: "namespace",
            expected: nil
        ))
    }

    func testDurableRegularFileRoundTripAtomicReplacementAndExactFsync() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )

        let destination = try fileSystem.createRegularFileExclusive(
            parent: transaction,
            name: "index"
        )
        try destination.write(Data("old".utf8))
        try destination.fsync()
        destination.close()

        let temporary = try fileSystem.createRegularFileExclusive(
            parent: transaction,
            name: ".index.replacement.tmp"
        )
        try temporary.write(Data("replacement".utf8))
        XCTAssertEqual(try temporary.seekToEnd(), UInt64("replacement".utf8.count))
        try temporary.seek(toOffset: 0)
        XCTAssertEqual(try temporary.read(upToCount: 64), Data("replacement".utf8))
        try temporary.fsync()
        temporary.close()

        let temporaryIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: ".index.replacement.tmp")
        ).identity
        try fileSystem.replaceRegularFileAtomically(
            parent: transaction,
            temporaryName: ".index.replacement.tmp",
            destinationName: "index",
            expectedTemporary: temporaryIdentity
        )
        let destinationIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "index")
        ).identity
        try fileSystem.fsyncRegularFileNoFollow(
            parent: transaction,
            name: "index",
            expected: destinationIdentity
        )
        let reopened = try fileSystem.openRegularFileNoFollow(
            parent: transaction,
            name: "index",
            expected: destinationIdentity,
            access: .readOnly
        )
        XCTAssertEqual(try reopened.read(upToCount: 64), Data("replacement".utf8))
        reopened.close()
    }

    func testDurableRegularFileOperationsRejectExternalCapabilityAndReplacementMismatch() throws {
        let root = try makeRoot()
        let fileSystem = DarwinFileSystemOperations()
        let external = try fileSystem.openDirectoryNoFollow(at: root)

        XCTAssertThrowsError(try fileSystem.createRegularFileExclusive(
            parent: external,
            name: "forbidden"
        ))

        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )
        let temporary = try fileSystem.createRegularFileExclusive(
            parent: transaction,
            name: "temporary"
        )
        temporary.close()
        let temporaryIdentity = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "temporary")
        ).identity

        XCTAssertThrowsError(try fileSystem.replaceRegularFileAtomically(
            parent: transaction,
            temporaryName: "temporary",
            destinationName: "destination",
            expectedTemporary: mismatchedIdentity(temporaryIdentity)
        ))
        XCTAssertNotNil(try fileSystem.statNoFollow(parent: transaction, name: "temporary"))
    }

    func testOwnedRemoveUsesDirectExactNameAndFsyncsParent() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent("transaction", isDirectory: true)
        var reached: [FileSystemOperationBoundary] = []
        let observer = OperationBoundaryObserver { boundary, component in
            guard component == "victim" else { return }
            reached.append(boundary)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )
        let victimURL = transactionURL.appendingPathComponent("victim")
        try Data("payload".utf8).write(to: victimURL)
        let expected = try XCTUnwrap(
            fileSystem.statNoFollow(parent: transaction, name: "victim")
        ).identity

        try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )

        XCTAssertEqual(reached, [
            .beforeOwnedDirectRemoval,
            .afterOwnedFinalVerification,
            .afterOwnedDirectRemoval,
            .afterOwnedParentSync,
        ])
        XCTAssertTrue(try fileSystem.listNoFollow(transaction).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: transactionURL.path)
            .contains { $0.hasPrefix(".xzip-remove-") })
    }

    func testOwnedRemoveAlreadyAbsentStillFsyncsParentWithoutHiddenName() throws {
        let root = try makeRoot()
        var reached: [FileSystemOperationBoundary] = []
        let observer = OperationBoundaryObserver { boundary, component in
            guard component == "victim" else { return }
            reached.append(boundary)
        }
        let fileSystem = DarwinFileSystemOperations(operationObserver: observer)
        let external = try fileSystem.openDirectoryNoFollow(at: root)
        let transaction = try fileSystem.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )
        let expected = FileNodeIdentity(
            device: try fileSystem.identity(of: transaction).device,
            inode: 42,
            generation: nil,
            kind: .regularFile
        )

        try fileSystem.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )

        XCTAssertEqual(reached, [.afterOwnedParentSync])
        XCTAssertTrue(try fileSystem.listNoFollow(transaction).isEmpty)
    }


    func testOwnedRemoveCrashAfterFinalVerificationLeavesExactNameForRetry() throws {
        let root = try makeRoot()
        let transactionURL = root.appendingPathComponent("transaction", isDirectory: true)
        let victimURL = transactionURL.appendingPathComponent("victim")
        let crash = FileSystemOperationError.posix(function: "simulated-crash", code: EIO)
        let observer = OperationBoundaryObserver { boundary, component in
            guard boundary == .afterOwnedFinalVerification, component == "victim" else { return }
            throw crash
        }
        let crashing = DarwinFileSystemOperations(operationObserver: observer)
        let external = try crashing.openDirectoryNoFollow(at: root)
        let transaction = try crashing.createTransactionDirectoryExclusive(
            parent: external,
            name: "transaction"
        )
        try Data("payload".utf8).write(to: victimURL)
        let expected = try XCTUnwrap(
            crashing.statNoFollow(parent: transaction, name: "victim")
        ).identity

        XCTAssertThrowsError(try crashing.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )) { error in
            XCTAssertEqual(error as? FileSystemOperationError, crash)
        }
        XCTAssertEqual(try String(contentsOf: victimURL, encoding: .utf8), "payload")

        let resumed = DarwinFileSystemOperations()
        try resumed.removeOwnedNoFollow(
            parent: transaction,
            name: "victim",
            expected: expected
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: victimURL.path))
    }
}
