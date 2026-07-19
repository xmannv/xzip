import XCTest
@testable import XZip

/// Unit tests for the round-2 browser/queue logic extracted into `ArchiveBrowsing`.
/// These are pure and need no `AppModel`, engine, or Keychain.
final class ArchiveBrowsingTests: XCTestCase {

    // MARK: - Helpers

    private func entry(_ path: String, kind: ArchiveEntryKind = .file) -> ArchiveEntry {
        ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            originalSize: 100,
            compressedSize: 50,
            modifiedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - visibleEntries (mockup 1b folder scoping)

    func testVisibleEntriesAtRootShowsDirectChildrenOnly() {
        let entries = [
            entry("Docs", kind: .folder),
            entry("Docs/readme.md"),
            entry("Docs/img/logo.png"),
            entry("top.txt")
        ]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "")
        let names = Set(visible.map(\.name))
        // Direct children of root: "Docs" folder + "top.txt". Nested files excluded.
        XCTAssertEqual(names, ["Docs", "top.txt"])
    }

    func testVisibleEntriesInsideFolder() {
        let entries = [
            entry("Docs/readme.md"),
            entry("Docs/img/logo.png"),
            entry("top.txt")
        ]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "Docs")
        // Only the direct child of "Docs" (readme.md); nested "img/logo.png" excluded.
        XCTAssertEqual(visible.map(\.name), ["readme.md"])
    }

    func testVisibleEntriesNormalizesLeadingSlash() {
        let entries = [entry("/Docs/readme.md"), entry("/top.txt")]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "Docs")
        XCTAssertEqual(visible.map(\.name), ["readme.md"])
    }

    func testVisibleEntriesFlatArchiveFallsBackToAllAtRoot() {
        // No directory structure, all entries have nested-looking paths but we're
        // at root and nothing matched the "direct child" rule → return all.
        let entries = [entry("a/b/c.txt"), entry("d/e/f.txt")]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "")
        XCTAssertEqual(visible.count, 2)
    }

    func testVisibleEntriesEmptyInput() {
        XCTAssertTrue(ArchiveBrowsing.visibleEntries([], currentFolderPath: "").isEmpty)
        XCTAssertTrue(ArchiveBrowsing.visibleEntries([], currentFolderPath: "Docs").isEmpty)
    }

    // MARK: - breadcrumbs (mockup 1b)

    func testBreadcrumbsAtRoot() {
        let crumbs = ArchiveBrowsing.breadcrumbs(archiveName: "Backup.zip", currentFolderPath: "")
        XCTAssertEqual(crumbs.count, 1)
        XCTAssertEqual(crumbs[0].name, "Backup.zip")
        XCTAssertEqual(crumbs[0].path, "")
    }

    func testBreadcrumbsNestedAccumulatesPaths() {
        let crumbs = ArchiveBrowsing.breadcrumbs(archiveName: "Backup.zip", currentFolderPath: "a/b/c")
        XCTAssertEqual(crumbs.map(\.name), ["Backup.zip", "a", "b", "c"])
        XCTAssertEqual(crumbs.map(\.path), ["", "a", "a/b", "a/b/c"])
    }

    // MARK: - estimateRemaining (mockup 3e ETA)

    func testEstimateRemainingTooEarlyReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 0.01, elapsed: 10))
    }

    func testEstimateRemainingCompleteReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 1.0, elapsed: 10))
    }

    func testEstimateRemainingSeconds() {
        // 50% done in 10s → ~10s remaining.
        XCTAssertEqual(ArchiveBrowsing.estimateRemaining(fraction: 0.5, elapsed: 10), "10 s left")
    }

    func testEstimateRemainingMinutes() {
        // 10% done in 60s → total 600s, ~540s remaining → 9 min.
        XCTAssertEqual(ArchiveBrowsing.estimateRemaining(fraction: 0.1, elapsed: 60), "9 min left")
    }

    func testEstimateRemainingNearDoneReturnsNil() {
        // 99.5% done in 100s → total ~100.5s, remaining ~0.5s → under 1s threshold.
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 0.995, elapsed: 100))
    }

    // MARK: - savedPercent (mockup 4c)

    func testSavedPercentTypical() {
        XCTAssertEqual(ArchiveBrowsing.savedPercent(inputBytes: 1000, outputBytes: 250), 75)
    }

    func testSavedPercentLargerOutputClampsToZero() {
        XCTAssertEqual(ArchiveBrowsing.savedPercent(inputBytes: 1000, outputBytes: 1200), 0)
    }

    func testSavedPercentZeroInputReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.savedPercent(inputBytes: 0, outputBytes: 100))
        XCTAssertNil(ArchiveBrowsing.savedPercent(inputBytes: 100, outputBytes: 0))
    }

    // MARK: - relativePath

    func testRelativePathStripsLeadingSlash() {
        XCTAssertEqual(ArchiveBrowsing.relativePath(entry("/a/b.txt")), "a/b.txt")
        XCTAssertEqual(ArchiveBrowsing.relativePath(entry("a/b.txt")), "a/b.txt")
    }
}
