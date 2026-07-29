import Foundation
import XCTest
@testable import XZIPCore
@testable import XZIPDomain
@testable import XZIPRuntime

final class CapturedTreeManifestTests: XCTestCase {
    func testCapturedManifestCanonicalizesRootRelativePathsAndDigest() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        try Data("a".utf8).write(to: fixture.folder.appendingPathComponent("a.txt"))
        let nested = fixture.folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))

        let manifest = try fixture.capture()

        XCTAssertEqual(manifest.rootPath, "folder")
        XCTAssertEqual(manifest.entries.map(\.relativePath), [
            "",
            "a.txt",
            "nested",
            "nested/b.txt"
        ])
        XCTAssertEqual(manifest.entries.first?.identity, try fixture.rootIdentity())
        XCTAssertEqual(manifest.digest.count, 32)
    }

    func testCapturedManifestIsIndependentOfDirectoryEnumerationOrder() throws {
        let root = manifestEntry(relativePath: "", inode: 1, kind: .directory)
        let a = manifestEntry(relativePath: "a.txt", inode: 2, kind: .regularFile)
        let nested = manifestEntry(relativePath: "nested", inode: 3, kind: .directory)
        let b = manifestEntry(
            relativePath: "nested/b.txt",
            inode: 4,
            kind: .regularFile
        )

        let first = try CapturedTreeManifest(
            rootPath: "folder",
            entries: [nested, b, root, a]
        )
        let second = try CapturedTreeManifest(
            rootPath: "folder",
            entries: [a, root, b, nested]
        )

        XCTAssertEqual(first.entries, second.entries)
        XCTAssertEqual(first.digest, second.digest)
    }

    func testCapturedManifestHashingPreservesExactUnicodeBytes() throws {
        let composed = try CapturedTreeManifest(
            rootPath: "folder",
            entries: [
                manifestEntry(relativePath: "", inode: 1, kind: .directory),
                manifestEntry(relativePath: "é", inode: 2, kind: .regularFile)
            ]
        )
        let decomposed = try CapturedTreeManifest(
            rootPath: "folder",
            entries: [
                manifestEntry(relativePath: "", inode: 1, kind: .directory),
                manifestEntry(
                    relativePath: "e\u{301}",
                    inode: 2,
                    kind: .regularFile
                )
            ]
        )

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(composed.digest, decomposed.digest)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
    }

    func testCapturedManifestDigestChangesForAddedRemovedAndReplacedDescendants() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        let firstURL = fixture.folder.appendingPathComponent("first.txt")
        let secondURL = fixture.folder.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        let original = try fixture.capture()

        try Data("second".utf8).write(to: secondURL)
        let added = try fixture.capture()
        XCTAssertNotEqual(original.digest, added.digest)

        try FileManager.default.removeItem(at: firstURL)
        let removed = try fixture.capture()
        XCTAssertNotEqual(added.digest, removed.digest)

        try FileManager.default.removeItem(at: secondURL)
        try Data("replacement".utf8).write(to: secondURL)
        let replaced = try fixture.capture()
        XCTAssertNotEqual(removed.digest, replaced.digest)
    }

    func testCapturedManifestUsesMandatoryStreamingVisitorForCaps() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        let sentinel = JournalTestFileSystem(
            base: fixture.fileSystem,
            streamedNodes: [
                syntheticFileNode(name: "first", inode: 2),
                syntheticFileNode(name: "second", inode: 3),
                syntheticFileNode(name: "third", inode: 4)
            ],
            failIfListCalled: true
        )

        XCTAssertThrowsError(try fixture.capture(
            resourcePolicy: .production.replacingForTests(listingHardCap: 1),
            fileSystem: sentinel
        )) { error in
            XCTAssertEqual(
                error as? ArchiveFailure,
                .resourceLimitExceeded(kind: .listingEntries, limit: 1, observed: 2)
            )
        }
        XCTAssertEqual(sentinel.streamedNodeCount(), 1)
    }

    func testCapturedManifestRejectsListingCountCap() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        try Data("x".utf8).write(to: fixture.folder.appendingPathComponent("x"))

        XCTAssertThrowsError(try fixture.plan(
            resourcePolicy: .production.replacingForTests(listingHardCap: 1)
        )) { error in
            XCTAssertEqual(
                error as? ArchiveFailure,
                .resourceLimitExceeded(kind: .listingEntries, limit: 1, observed: 2)
            )
        }
    }

    func testCapturedManifestRejectsTotalPathByteCap() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        try Data("x".utf8).write(to: fixture.folder.appendingPathComponent("aa"))

        XCTAssertThrowsError(try fixture.plan(
            resourcePolicy: .production.replacingForTests(totalPathByteCap: 1)
        )) { error in
            XCTAssertEqual(
                error as? ArchiveFailure,
                .resourceLimitExceeded(kind: .pathBytes, limit: 1, observed: 2)
            )
        }
    }

    func testCapturedManifestRejectsMaximumPathByteCount() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        try Data("x".utf8).write(to: fixture.folder.appendingPathComponent("aa"))

        XCTAssertThrowsError(try fixture.plan(
            resourcePolicy: .production.replacingForTests(maximumPathByteCount: 1)
        )) { error in
            XCTAssertEqual(
                error as? ArchiveFailure,
                .resourceLimitExceeded(kind: .pathBytes, limit: 1, observed: 2)
            )
        }
    }

    func testCapturedManifestRejectsMaximumPathDepth() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        let nested = fixture.folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: nested.appendingPathComponent("x"))

        XCTAssertThrowsError(try fixture.plan(
            resourcePolicy: .production.replacingForTests(maximumPathDepth: 1)
        )) { error in
            XCTAssertEqual(
                error as? ArchiveFailure,
                .resourceLimitExceeded(kind: .pathBytes, limit: 1, observed: 2)
            )
        }
    }

    func testCapturedManifestTreatsSymlinkAsLeaf() throws {
        let fixture = try CapturedTreeFixture.make()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: target.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: fixture.folder.appendingPathComponent("link").path,
            withDestinationPath: target.path
        )

        let manifest = try fixture.capture()

        XCTAssertEqual(manifest.entries.map(\.relativePath), ["", "link"])
        XCTAssertEqual(manifest.entries.last?.identity.kind, .symbolicLink)
    }
}

private struct CapturedTreeFixture {
    let root: URL
    let destination: URL
    let folder: URL
    let fileSystem = DarwinFileSystemOperations()

    static func make() throws -> CapturedTreeFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        let folder = destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return CapturedTreeFixture(root: root, destination: destination, folder: folder)
    }

    func rootIdentity() throws -> FileNodeIdentity {
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationHandle.close() }
        return try XCTUnwrap(
            fileSystem.statNoFollow(parent: destinationHandle, name: "folder")
        ).identity
    }

    func capture(
        resourcePolicy: ArchiveResourcePolicy = .production,
        fileSystem: any FileSystemOperations = DarwinFileSystemOperations()
    ) throws -> CapturedTreeManifest {
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationHandle.close() }
        let rootNode = try XCTUnwrap(
            fileSystem.statNoFollow(parent: destinationHandle, name: "folder")
        )
        return try CapturedTreeManifest.capture(
            rootPath: "folder",
            rootNode: rootNode,
            parent: destinationHandle,
            fileSystem: fileSystem,
            listingPolicy: resourcePolicy.listing
        )
    }

    func plan(resourcePolicy: ArchiveResourcePolicy) throws -> ExtractionPublicationPlan {
        let inventory = try ExtractionInventory.validated(
            entries: [
                .init(
                    path: "folder/new.txt",
                    kind: .regularFile,
                    size: 1,
                    linkTarget: nil,
                    isExplicitDirectory: false
                )
            ],
            advertisedDictionaryByteCount: 0,
            policy: .production
        )
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destination)
        defer { destinationHandle.close() }
        return try ExtractionConflictPlanner(fileSystem: fileSystem).plan(
            inventory: inventory,
            selectedEntries: [],
            destination: destinationHandle,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: resourcePolicy
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func syntheticFileNode(name: String, inode: UInt64) -> FileNode {
    FileNode(
        name: name,
        identity: FileNodeIdentity(
            device: 1,
            inode: inode,
            generation: nil,
            kind: .regularFile
        ),
        byteCount: 0,
        linkTarget: nil
    )
}

private func manifestEntry(
    relativePath: String,
    inode: UInt64,
    kind: ExtractionNodeKind
) -> CapturedTreeManifestEntry {
    CapturedTreeManifestEntry(
        relativePath: relativePath,
        identity: FileNodeIdentity(
            device: 1,
            inode: inode,
            generation: nil,
            kind: kind
        ),
        byteCount: 0,
        allocatedByteCount: 0,
        timestamps: nil
    )
}
