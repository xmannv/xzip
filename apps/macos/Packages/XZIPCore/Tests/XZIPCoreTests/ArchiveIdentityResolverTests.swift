import Darwin
import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

private struct UnavailableIdentityReader: FileSystemIdentityReading {
    func stableIdentity(for url: URL) throws -> FileSystemIdentity? { nil }
}

private final class SequenceIncarnationTokenProvider:
    ArchiveIncarnationTokenProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var tokens: [ArchiveIncarnationToken]

    init(_ tokens: [ArchiveIncarnationToken]) {
        self.tokens = tokens
    }

    func nextToken() -> ArchiveIncarnationToken {
        lock.lock()
        defer { lock.unlock() }
        return tokens.removeFirst()
    }
}


private final class ReplacingIdentityReader:
    FileSystemIdentityReading,
    @unchecked Sendable
{
    private let replacementURL: URL

    init(replacementURL: URL) {
        self.replacementURL = replacementURL
    }

    func stableIdentity(for url: URL) throws -> FileSystemIdentity? {
        let identity = try DarwinFileSystemIdentityReader().stableIdentity(for: url)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacementURL)
        return identity
    }
}

final class ArchiveIdentityResolverTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveIdentityResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeTemporaryFile(
        named name: String = "archive.zip",
        contents: Data = Data("AAAA".utf8)
    ) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }

    func testRenameKeepsStableIdentity() throws {
        let resolver = ArchiveIdentityResolver()
        let original = try makeTemporaryFile()
        let before = try resolver.resolve(original)
        let renamed = original.deletingLastPathComponent().appendingPathComponent("renamed.zip")

        try FileManager.default.moveItem(at: original, to: renamed)
        let after = try resolver.resolve(renamed)

        XCTAssertEqual(before.locator.archiveID, after.locator.archiveID)
    }

    func testHardLinkAliasUsesSameStableIdentity() throws {
        let resolver = ArchiveIdentityResolver()
        let original = try makeTemporaryFile()
        let alias = original.deletingLastPathComponent().appendingPathComponent("alias.zip")
        try FileManager.default.linkItem(at: original, to: alias)

        let first = try resolver.resolve(original)
        let second = try resolver.resolve(alias)

        XCTAssertEqual(first.locator.archiveID, second.locator.archiveID)
    }

    func testAtomicReplacementAlwaysChangesArchiveIdentity() throws {
        let resolver = ArchiveIdentityResolver(fingerprintByteLimit: 4)
        let original = try makeTemporaryFile(contents: Data("AAAA".utf8))
        let replacement = original.deletingLastPathComponent()
            .appendingPathComponent("replacement.zip")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: original.path
        )
        let before = try resolver.resolve(original)

        try Data("BBBB".utf8).write(to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: replacement.path
        )
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: original.path
        )
        let after = try resolver.resolve(original)

        XCTAssertNotEqual(before.locator.archiveID, after.locator.archiveID)
    }

    func testMiddleRewriteWithRestoredModificationDateChangesRevision() throws {
        let archive = try makeTemporaryFile(
            contents: Data(repeating: 0x41, count: 256 * 1_024)
        )
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: archive.path
        )
        let resolver = ArchiveIdentityResolver()
        let before = try resolver.resolve(archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: 128 * 1_024)
        try handle.write(contentsOf: Data(repeating: 0x42, count: 4 * 1_024))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: archive.path
        )

        let after = try resolver.resolve(archive)

        XCTAssertNotEqual(before.revision, after.revision)
    }

    func testConcurrentRewriteDuringFingerprintingIsRejected() throws {
        let archive = try makeTemporaryFile(
            contents: Data(repeating: 0x41, count: 256 * 1_024)
        )
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: archive.path
        )
        let resolver = ArchiveIdentityResolver(
            identityReader: DarwinFileSystemIdentityReader(),
            incarnationTokenProvider: SequenceIncarnationTokenProvider([]),
            fingerprintByteLimit: 64 * 1_024,
            fingerprintChunkObserver: { chunkIndex in
                guard chunkIndex == 0 else { return }
                let writer = try FileHandle(forWritingTo: archive)
                try writer.seek(toOffset: 1_024)
                try writer.write(contentsOf: Data(repeating: 0x42, count: 4 * 1_024))
                try writer.synchronize()
                try writer.close()
                try FileManager.default.setAttributes(
                    [.modificationDate: fixedDate],
                    ofItemAtPath: archive.path
                )
            }
        )

        XCTAssertThrowsError(try resolver.resolve(archive)) { error in
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                .fileReadCorruptFile
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: archive).subdata(in: 1_024 ..< 5_120),
            Data(repeating: 0x42, count: 4 * 1_024)
        )
    }

    func testCanonicalFallbackUsesResolvedPathAndInjectedIncarnation() throws {
        let original = try makeTemporaryFile()
        let symlink = original.deletingLastPathComponent().appendingPathComponent("linked.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let token = ArchiveIncarnationToken(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        )
        let resolver = ArchiveIdentityResolver(
            identityReader: UnavailableIdentityReader(),
            incarnationTokenProvider: SequenceIncarnationTokenProvider([token])
        )

        let resolved = try resolver.resolve(symlink)

        XCTAssertEqual(
            resolved.locator.archiveID.identity,
            .canonicalPath(
                path: original.resolvingSymlinksInPath().standardizedFileURL.path,
                incarnation: token
            )
        )
    }

    func testFallbackSamePathReplacementAlwaysMintsNewArchiveID() throws {
        let firstToken = ArchiveIncarnationToken(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        )
        let secondToken = ArchiveIncarnationToken(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        )
        let resolver = ArchiveIdentityResolver(
            identityReader: UnavailableIdentityReader(),
            incarnationTokenProvider: SequenceIncarnationTokenProvider([firstToken, secondToken])
        )
        let archive = try makeTemporaryFile(contents: Data("AAAA".utf8))
        let before = try resolver.resolve(archive)

        try Data("BBBB".utf8).write(to: archive, options: .atomic)
        let after = try resolver.resolve(archive)

        XCTAssertNotEqual(before.locator.archiveID, after.locator.archiveID)
        XCTAssertEqual(before.locator.url, after.locator.url)
    }

    func testFallbackKnownMovePreservesArchiveIDByUpdatingLocatorOnly() throws {
        let id = ArchiveID(identity: .canonicalPath(
            path: "/before.zip",
            incarnation: ArchiveIncarnationToken(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
            )
        ))
        var locator = ArchiveLocator(archiveID: id, url: URL(fileURLWithPath: "/before.zip"))

        locator.updateURL(URL(fileURLWithPath: "/after.zip"))

        XCTAssertEqual(locator.archiveID, id)
    }


    func testSignedDeviceIdentifierPreservesBitPattern() {
        XCTAssertEqual(
            volumeIdentifierBitPattern(for: dev_t(-1)),
            UInt64(UInt32.max)
        )
    }


    func testReplacementDuringResolutionIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let archive = directory.appendingPathComponent("archive.zip")
        let replacement = directory.appendingPathComponent("replacement.zip")
        let originalContents = Data("AAAA".utf8)
        let replacementContents = Data("BBBBBBBB".utf8)
        try originalContents.write(to: archive)
        try replacementContents.write(to: replacement)
        let resolver = ArchiveIdentityResolver(
            identityReader: ReplacingIdentityReader(replacementURL: replacement),
            incarnationTokenProvider: SequenceIncarnationTokenProvider([]),
            fingerprintByteLimit: 64
        )

        XCTAssertThrowsError(try resolver.resolve(archive)) { error in
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                .fileReadCorruptFile
            )
        }
        XCTAssertEqual(try Data(contentsOf: archive), replacementContents)
    }

    func testStableVolumeIdentifierUsesNearestExistingParentForMissingDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("archive.zip")
        let resolver = ArchiveIdentityResolver()

        let existingVolume = try resolver.stableVolumeIdentifier(for: root)
        let destinationVolume = try resolver.stableVolumeIdentifier(for: destination)

        XCTAssertNotEqual(existingVolume, 0)
        XCTAssertEqual(destinationVolume, existingVolume)
    }
}
