import XCTest
@testable import XZIPCore

/// The App Group identifier is read back from the signed entitlement rather than
/// duplicated in source. These tests cover the selection rule without requiring a
/// signed bundle. The exact concrete identifier is registered in Apple Developer
/// and embedded in the provisioning profile; application-group values are not the
/// same namespace as application identifiers or keychain access groups.
final class AppGroupTests: XCTestCase {

    func testTeamPrefixedNearMatchIsRejected() {
        XCTAssertNil(
            XZIPAppGroup.selectGroup(from: ["7E6Z9B4F2H.group.com.codetay.xzip"]),
            "a Team-prefixed value is a different App Group, not an alias for ours"
        )
    }

    /// Selection must not depend on the order the entitlement happens to list
    /// groups in, which is what taking `first` would have done.
    func testOurGroupIsFoundRegardlessOfPosition() {
        let ours = "group.com.codetay.xzip"
        XCTAssertEqual(
            XZIPAppGroup.selectGroup(from: [ours, "7E6Z9B4F2H.com.other"]),
            ours
        )
        XCTAssertEqual(
            XZIPAppGroup.selectGroup(from: ["7E6Z9B4F2H.com.other", ours]),
            ours
        )
    }

    /// The one that matters: another vendor's group must never be mistaken for
    /// ours just because it contains our name. If it were, the app would resolve a
    /// container it has no business writing into.
    func testForeignGroupsAreRejected() {
        XCTAssertNil(
            XZIPAppGroup.selectGroup(from: ["4FG648TM2A.group.com.aone.keka"])
        )
        XCTAssertNil(
            XZIPAppGroup.selectGroup(from: ["group.com.codetay.xzip.evil"]),
            "a longer identifier that merely starts with ours is not ours"
        )
        XCTAssertNil(
            XZIPAppGroup.selectGroup(from: ["7E6Z9B4F2H.group.com.codetay.xzipextra"]),
            "the suffix must match on a component boundary, not any substring"
        )
        XCTAssertNil(XZIPAppGroup.selectGroup(from: []))
    }

    /// The concrete identifier embedded by the profile is the only one accepted.
    func testRegisteredGroupIsOurs() {
        XCTAssertEqual(
            XZIPAppGroup.selectGroup(from: ["group.com.codetay.xzip"]),
            "group.com.codetay.xzip"
        )
    }

    /// The suffix is the contract between the source and all four entitlement
    /// files; a rename here has to be made deliberately.
    func testGroupSuffixMatchesTheEntitlements() {
        XCTAssertEqual(XZIPAppGroup.groupSuffix, "group.com.codetay.xzip")
    }

    // MARK: - Releasing staged files

    private let inbox = URL(fileURLWithPath: "/tmp/container/SharedInbox", isDirectory: true)

    /// Compared as paths, not URLs: the returned folders come from
    /// `deletingLastPathComponent()` and therefore carry a trailing slash, which
    /// `URL` equality treats as a different value. `removeItem` does not care, and
    /// asserting on paths keeps these tests about the containment rule.
    private func folderPaths(holding urls: [URL], in inbox: URL? = nil) -> Set<String> {
        Set(
            XZIPAppGroup.stagedFolders(in: inbox ?? self.inbox, holding: urls)
                .map(\.path)
        )
    }

    func testStagedFolderIsCollectedForItsFile() {
        XCTAssertEqual(
            folderPaths(holding: [inbox.appendingPathComponent("ABC/photo.jpg")]),
            ["/tmp/container/SharedInbox/ABC"]
        )
    }

    /// Several files from one share sit in the same folder; it is removed once.
    func testFilesSharingAFolderCollapseToOneEntry() {
        XCTAssertEqual(
            folderPaths(holding: [
                inbox.appendingPathComponent("ABC/one.txt"),
                inbox.appendingPathComponent("ABC/two.txt")
            ]),
            ["/tmp/container/SharedInbox/ABC"]
        )
    }

    /// The inbox holds every pending share, so deleting it would discard files
    /// belonging to shares this operation knows nothing about.
    func testInboxItselfIsNeverReturned() {
        XCTAssertTrue(
            XZIPAppGroup.stagedFolders(
                in: inbox,
                holding: [inbox.appendingPathComponent("loose.txt")]
            ).isEmpty
        )
    }

    /// The rule this function exists for: these delete directories, so a path that
    /// is not staged must never yield one.
    func testUnstagedPathsAreRejected() {
        XCTAssertTrue(
            XZIPAppGroup.stagedFolders(
                in: inbox,
                holding: [URL(fileURLWithPath: "/Users/me/Documents/taxes.pdf")]
            ).isEmpty,
            "a real user folder must never be collected"
        )
        XCTAssertTrue(
            XZIPAppGroup.stagedFolders(
                in: inbox,
                holding: [URL(fileURLWithPath: "/tmp/container/SharedInboxEvil/x/f.txt")]
            ).isEmpty,
            "a sibling whose name merely starts with the inbox's is not the inbox"
        )
        XCTAssertTrue(
            XZIPAppGroup.stagedFolders(
                in: inbox,
                holding: [inbox.appendingPathComponent("ABC/nested/deep.txt")]
            ).isEmpty,
            "only the shape `stage` writes is accepted"
        )
    }

    /// `..` must not be usable to have an outside directory pass the check.
    func testDotDotCannotEscapeAndStillLookStaged() {
        XCTAssertTrue(
            XZIPAppGroup.stagedFolders(
                in: inbox,
                holding: [inbox.appendingPathComponent("ABC/../../../Users/me/Documents/f.txt")]
            ).isEmpty
        )
    }

    /// The reason the comparison is on `path`: a directory URL carries a trailing
    /// slash, and comparing URLs would then miss every match.
    func testTrailingSlashOnTheInboxStillMatches() {
        XCTAssertEqual(
            folderPaths(
                holding: [inbox.appendingPathComponent("ABC/photo.jpg")],
                in: URL(fileURLWithPath: "/tmp/container/SharedInbox/")
            ),
            ["/tmp/container/SharedInbox/ABC"]
        )
    }
}
