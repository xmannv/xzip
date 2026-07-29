import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

/// Wave 9B-2: the live `PublicationQuarantining` applies the macOS
/// `com.apple.quarantine` extended attribute to every staged manifest node,
/// no-follow and identity-checked, without opening a symlink's target. These
/// tests build a real transaction-owned staging tree (0700 root) with
/// `DarwinFileSystemOperations`, invoke the quarantine, and read the xattr back.
final class LivePublicationQuarantineTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - value builder (pure)

    func testQuarantineValueHasGatekeeperFieldFormat() {
        let time = Date(timeIntervalSince1970: 0x5f8c_3a2b)
        let uuid = UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")!
        let value = LivePublicationQuarantine.quarantineValue(
            flags: "0081", timestamp: time, agentName: "XZIP", uuid: uuid)
        XCTAssertEqual(
            String(decoding: value, as: UTF8.self),
            "0081;5f8c3a2b;XZIP;A1B2C3D4-1111-2222-3333-444455556666"
        )
    }

    // MARK: - integration (real staging tree)

    private func readXattr(at url: URL, noFollow: Bool) throws -> Data? {
        let options = noFollow ? XATTR_NOFOLLOW : 0
        let size = getxattr(url.path, LivePublicationQuarantine.attributeKey, nil, 0, 0, options)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, LivePublicationQuarantine.attributeKey,
                     $0.baseAddress, $0.count, 0, options)
        }
        guard read == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return data
    }

    private func collect(
        _ fs: DarwinFileSystemOperations,
        _ dir: DirectoryHandle,
        _ prefix: String
    ) throws -> [QuarantineManifestEntry] {
        var out: [QuarantineManifestEntry] = []
        for node in try fs.listNoFollow(dir) {
            let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
            out.append(QuarantineManifestEntry(
                relativePath: path, kind: node.identity.kind, identity: node.identity))
            if node.identity.kind == .directory {
                let child = try fs.openDirectoryNoFollow(
                    parent: dir, name: node.name, expected: node.identity)
                defer { child.close() }
                out += try collect(fs, child, path)
            }
        }
        return out
    }

    /// Builds staging/{a.txt, sub/, sub/inner.txt, link->target}, chmod 0700,
    /// and returns (fs, stagingURL, rootIdentity, entries, targetURL).
    private func makeStagingTree() throws -> (
        fs: DarwinFileSystemOperations,
        staging: URL,
        rootIdentity: FileNodeIdentity,
        entries: [QuarantineManifestEntry],
        target: URL
    ) {
        let staging = workDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = workDir.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)

        try Data("hello".utf8).write(to: staging.appendingPathComponent("a.txt"))
        let sub = staging.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: sub.appendingPathComponent("inner.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: staging.appendingPathComponent("link").path,
            withDestinationPath: target.path)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: staging.path)

        let fs = DarwinFileSystemOperations()
        let rootHandle = try fs.openDirectoryNoFollow(at: staging)
        defer { rootHandle.close() }
        let rootIdentity = try fs.identity(of: rootHandle)
        let entries = try collect(fs, rootHandle, "")
        return (fs, staging, rootIdentity, entries, target)
    }

    func testAppliesQuarantineToEveryStagedNodeNoFollow() throws {
        let tree = try makeStagingTree()
        let time = Date(timeIntervalSince1970: 0x6000_0000)
        let uuid = UUID(uuidString: "DEADBEEF-0000-1111-2222-333344445555")!
        let quarantine = LivePublicationQuarantine(
            now: { time }, uuidProvider: { uuid })

        try quarantine.apply(
            to: tree.entries,
            stagingRoot: tree.staging,
            stagingRootIdentity: tree.rootIdentity,
            fileSystem: tree.fs
        )

        let expected = LivePublicationQuarantine.quarantineValue(
            flags: "0081", timestamp: time, agentName: "XZIP", uuid: uuid)
        // Every staged node (file, dir, nested file, symlink) is quarantined.
        for rel in ["a.txt", "sub", "sub/inner.txt", "link"] {
            let value = try readXattr(
                at: tree.staging.appendingPathComponent(rel), noFollow: true)
            XCTAssertEqual(value, expected, "missing/incorrect quarantine on \(rel)")
        }
        // The symlink target (outside staging) must be untouched.
        XCTAssertNil(try readXattr(at: tree.target, noFollow: false))
    }

    func testApplyThrowsOnIdentityMismatch() throws {
        let tree = try makeStagingTree()
        // Corrupt one entry's identity so enforcement must reject it.
        let corrupted = tree.entries.map { entry -> QuarantineManifestEntry in
            guard entry.relativePath == "a.txt" else { return entry }
            let bogus = FileNodeIdentity(
                device: entry.identity.device,
                inode: entry.identity.inode &+ 99999,
                generation: entry.identity.generation,
                kind: entry.identity.kind)
            return QuarantineManifestEntry(
                relativePath: entry.relativePath, kind: entry.kind, identity: bogus)
        }
        let quarantine = LivePublicationQuarantine()
        XCTAssertThrowsError(
            try quarantine.apply(
                to: corrupted,
                stagingRoot: tree.staging,
                stagingRootIdentity: tree.rootIdentity,
                fileSystem: tree.fs
            )
        ) { error in
            guard case FileSystemOperationError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
    }

    func testApplyThrowsOnSymlinkIdentityMismatch() throws {
        let tree = try makeStagingTree()
        // Corrupt the symlink entry's identity: the O_SYMLINK no-follow path
        // must also surface identityMismatch (rollback-mapped by the caller).
        let corrupted = tree.entries.map { entry -> QuarantineManifestEntry in
            guard entry.relativePath == "link" else { return entry }
            let bogus = FileNodeIdentity(
                device: entry.identity.device,
                inode: entry.identity.inode &+ 424242,
                generation: entry.identity.generation,
                kind: entry.identity.kind)
            return QuarantineManifestEntry(
                relativePath: entry.relativePath, kind: entry.kind, identity: bogus)
        }
        let quarantine = LivePublicationQuarantine()
        XCTAssertThrowsError(
            try quarantine.apply(
                to: corrupted,
                stagingRoot: tree.staging,
                stagingRootIdentity: tree.rootIdentity,
                fileSystem: tree.fs
            )
        ) { error in
            guard case FileSystemOperationError.identityMismatch = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
        }
        // The symlink target must remain untouched even on the failure path.
        XCTAssertNil(try readXattr(at: tree.target, noFollow: false))
    }
}
