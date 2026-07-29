import Foundation
import XCTest
@testable import XZIPCore

/// Wave 9A: StagingWriteAuthority is the Core-owned, Runtime-independent
/// value that reproduces the transaction's normalized path/kind write
/// authority (see ExtractionTransaction.makeManifest / validateStaging).
/// It authorizes exactly the explicit inventory entries plus their implicit
/// parent directories, all NFC-normalized, and rejects anything else.
final class StagingWriteAuthorityTests: XCTestCase {

    private func inventory(
        _ entries: [ExtractionInventoryEntry],
        implicit: Set<String> = []
    ) -> ExtractionInventory {
        ExtractionInventory(
            entries: entries,
            implicitDirectories: implicit,
            advertisedOutputByteCount: 0,
            advertisedDictionaryByteCount: 0
        )
    }

    private func file(_ path: String) -> ExtractionInventoryEntry {
        ExtractionInventoryEntry(
            path: path, kind: .regularFile, size: 3,
            linkTarget: nil, isExplicitDirectory: false
        )
    }

    private func dir(_ path: String) -> ExtractionInventoryEntry {
        ExtractionInventoryEntry(
            path: path, kind: .directory, size: 0,
            linkTarget: nil, isExplicitDirectory: true
        )
    }

    private func link(_ path: String, target: String) -> ExtractionInventoryEntry {
        ExtractionInventoryEntry(
            path: path, kind: .symbolicLink, size: 0,
            linkTarget: target, isExplicitDirectory: false
        )
    }

    func testFromInventoryUnionsExplicitEntriesAndImplicitDirectories() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file("a/b.txt"), link("a/l", target: "b.txt")], implicit: ["a"])
        )
        XCTAssertEqual(
            authority.authorizedPaths,
            ["a", "a/b.txt", "a/l"]
        )
        XCTAssertTrue(authority.isAuthorized(relativePath: "a", kind: .directory))
        XCTAssertTrue(authority.isAuthorized(relativePath: "a/b.txt", kind: .regularFile))
        XCTAssertTrue(authority.isAuthorized(relativePath: "a/l", kind: .symbolicLink))
    }

    func testExplicitDirectoryKindOverridesAndIsAuthorizedAsDirectory() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([dir("top"), file("top/inner.txt")])
        )
        XCTAssertTrue(authority.isAuthorized(relativePath: "top", kind: .directory))
        XCTAssertTrue(authority.authorizedDirectory("top"))
    }

    func testFromInventoryNormalizesPathsToNFC() throws {
        // "cafe" + combining acute (NFD) must normalize to precomposed "café".
        let decomposed = "cafe\u{0301}/x.txt"
        let precomposed = "caf\u{00E9}/x.txt"
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file(decomposed)], implicit: ["cafe\u{0301}"])
        )
        XCTAssertTrue(authority.authorizedPaths.contains(precomposed))
        XCTAssertTrue(authority.authorizedPaths.contains("caf\u{00E9}"))
        // Query with either normalization form resolves the same authority.
        XCTAssertTrue(authority.isAuthorized(relativePath: decomposed, kind: .regularFile))
        XCTAssertTrue(authority.isAuthorized(relativePath: precomposed, kind: .regularFile))
    }

    func testEntriesAreSortedByRelativePath() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file("b.txt"), file("a.txt"), file("m.txt")])
        )
        XCTAssertEqual(
            authority.entries.map(\.relativePath),
            ["a.txt", "b.txt", "m.txt"]
        )
    }

    func testIsAuthorizedFalseForKindMismatch() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file("a.txt")])
        )
        XCTAssertFalse(authority.isAuthorized(relativePath: "a.txt", kind: .directory))
        XCTAssertFalse(authority.isAuthorized(relativePath: "a.txt", kind: .symbolicLink))
    }

    func testIsAuthorizedFalseForUnknownPath() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file("a.txt")])
        )
        XCTAssertFalse(authority.isAuthorized(relativePath: "evil.txt", kind: .regularFile))
        XCTAssertFalse(authority.isAuthorized(relativePath: "a.txt/child", kind: .regularFile))
    }

    func testAuthorizedDirectoryTrueForRootAndImplicitParent() throws {
        let authority = try StagingWriteAuthority.fromInventory(
            inventory([file("a/b/c.txt")], implicit: ["a", "a/b"])
        )
        XCTAssertTrue(authority.authorizedDirectory(""), "staging root is always writable")
        XCTAssertTrue(authority.authorizedDirectory("a"))
        XCTAssertTrue(authority.authorizedDirectory("a/b"))
        XCTAssertFalse(authority.authorizedDirectory("a/b/c.txt"), "a file is not a directory")
    }

    func testFromInventoryRejectsParentTraversalComponent() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromInventory(inventory([file("../escape.txt")]))
        )
    }

    func testFromInventoryRejectsAbsolutePath() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromInventory(inventory([file("/etc/passwd")]))
        )
    }

    func testFromInventoryRejectsEmptyComponent() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromInventory(inventory([file("a//b.txt")]))
        )
    }

    // MARK: - fromAuthorizedEntries (Wave 9B)

    private func entry(_ path: String, _ kind: ExtractionNodeKind) -> StagingWriteAuthority.Entry {
        StagingWriteAuthority.Entry(relativePath: path, kind: kind)
    }

    func testFromAuthorizedEntriesEqualsFromInventoryForEquivalentSet() throws {
        // The durable cleanup manifest is the already-unioned set that
        // fromInventory would produce; converting it back must yield the same
        // authority (same authorizedPaths + same kind gating).
        let fromInv = try StagingWriteAuthority.fromInventory(
            inventory([file("a/b.txt"), link("a/l", target: "b.txt")], implicit: ["a"])
        )
        let fromManifest = try StagingWriteAuthority.fromAuthorizedEntries(fromInv.entries)
        XCTAssertEqual(fromManifest.authorizedPaths, fromInv.authorizedPaths)
        XCTAssertTrue(fromManifest.isAuthorized(relativePath: "a", kind: .directory))
        XCTAssertTrue(fromManifest.isAuthorized(relativePath: "a/b.txt", kind: .regularFile))
        XCTAssertTrue(fromManifest.isAuthorized(relativePath: "a/l", kind: .symbolicLink))
    }

    func testFromAuthorizedEntriesSortsAndPreservesKind() throws {
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            entry("b.txt", .regularFile),
            entry("a", .directory),
            entry("a/inner", .regularFile),
        ])
        XCTAssertEqual(authority.entries.map(\.relativePath), ["a", "a/inner", "b.txt"])
        XCTAssertTrue(authority.isAuthorized(relativePath: "a", kind: .directory))
        XCTAssertTrue(authority.authorizedDirectory("a"))
    }

    func testFromAuthorizedEntriesNormalizesToNFC() throws {
        let decomposed = "cafe\u{0301}/x.txt"
        let precomposed = "caf\u{00E9}/x.txt"
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            entry("cafe\u{0301}", .directory),
            entry(decomposed, .regularFile),
        ])
        XCTAssertTrue(authority.authorizedPaths.contains(precomposed))
        XCTAssertTrue(authority.isAuthorized(relativePath: decomposed, kind: .regularFile))
    }

    func testFromAuthorizedEntriesDedupsExactDuplicate() throws {
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            entry("a/b.txt", .regularFile),
            entry("a/b.txt", .regularFile),
        ])
        XCTAssertEqual(authority.entries.count, 1)
    }

    func testFromAuthorizedEntriesRejectsConflictingKindForSamePath() {
        // Order-independent: a conflicting kind for the same normalized path is
        // rejected rather than resolved by array order (9B1-M1).
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromAuthorizedEntries([
                entry("a/b.txt", .regularFile),
                entry("a/b.txt", .directory),
            ])
        )
    }

    func testFromAuthorizedEntriesRejectsAbsolutePath() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromAuthorizedEntries([entry("/etc/passwd", .regularFile)])
        )
    }

    func testFromAuthorizedEntriesRejectsParentTraversal() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromAuthorizedEntries([entry("../escape", .regularFile)])
        )
    }

    func testFromAuthorizedEntriesRejectsEmptyComponent() {
        XCTAssertThrowsError(
            try StagingWriteAuthority.fromAuthorizedEntries([entry("a//b.txt", .regularFile)])
        )
    }
}
