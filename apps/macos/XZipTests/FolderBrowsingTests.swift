import XCTest
@testable import XZip

/// Unit tests for the Places folder-browser logic in `FolderBrowsing`.
/// These build a real temp directory tree so `FileManager` access is exercised.
final class FolderBrowsingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-folderbrowsing-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Layout:
        //   root/
        //     Alpha/            (dir)
        //     beta.txt          (12 bytes)
        //     photo.png         (3 bytes)
        //     backup.zip        (1 byte, archive)
        //     .hidden           (dot file, must be skipped)
        try fm.createDirectory(at: root.appendingPathComponent("Alpha"),
                               withIntermediateDirectories: true)
        try Data(repeating: 0, count: 12).write(to: root.appendingPathComponent("beta.txt"))
        try Data(repeating: 0, count: 3).write(to: root.appendingPathComponent("photo.png"))
        try Data(repeating: 0, count: 1).write(to: root.appendingPathComponent("backup.zip"))
        try Data(repeating: 0, count: 5).write(to: root.appendingPathComponent(".hidden"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - contents

    func testContentsSkipsHiddenFiles() {
        let names = Set(FolderBrowsing.contents(of: root).map(\.name))
        XCTAssertEqual(names, ["Alpha", "beta.txt", "photo.png", "backup.zip"])
        XCTAssertFalse(names.contains(".hidden"))
    }

    func testContentsFlagsDirectories() {
        let items = FolderBrowsing.contents(of: root)
        let alpha = items.first { $0.name == "Alpha" }
        let beta = items.first { $0.name == "beta.txt" }
        XCTAssertEqual(alpha?.isDirectory, true)
        XCTAssertEqual(beta?.isDirectory, false)
        XCTAssertEqual(beta?.sizeBytes, 12)
    }

    func testContentsOfUnreadableFolderIsEmpty() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertTrue(FolderBrowsing.contents(of: missing).isEmpty)
    }

    // MARK: - sort (folders always first)

    func testSortByNameFoldersFirst() {
        let sorted = FolderBrowsing.sort(FolderBrowsing.contents(of: root), by: .name)
        XCTAssertEqual(sorted.first?.name, "Alpha")   // the only folder leads
        // Remaining files are alphabetical, case-insensitive.
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "backup.zip", "beta.txt", "photo.png"])
    }

    func testSortBySizeKeepsFoldersFirst() {
        let sorted = FolderBrowsing.sort(FolderBrowsing.contents(of: root), by: .size)
        XCTAssertEqual(sorted.first?.name, "Alpha")
        // Files by ascending size: backup.zip(1) < photo.png(3) < beta.txt(12).
        XCTAssertEqual(sorted.dropFirst().map(\.name), ["backup.zip", "photo.png", "beta.txt"])
    }

    // MARK: - isArchive

    func testIsArchiveTrueForZip() {
        let items = FolderBrowsing.contents(of: root)
        let zip = items.first { $0.name == "backup.zip" }!
        XCTAssertTrue(FolderBrowsing.isArchive(zip))
    }

    func testIsArchiveFalseForPlainFileAndFolder() {
        let items = FolderBrowsing.contents(of: root)
        let txt = items.first { $0.name == "beta.txt" }!
        let dir = items.first { $0.name == "Alpha" }!
        XCTAssertFalse(FolderBrowsing.isArchive(txt))
        XCTAssertFalse(FolderBrowsing.isArchive(dir))
    }

    // MARK: - uniqueName

    func testUniqueNameNoCollisionReturnsDesired() {
        XCTAssertEqual(
            FolderBrowsing.uniqueName(desired: "untitled folder", existing: []),
            "untitled folder")
    }

    func testUniqueNameFolderAppendsCounter() {
        let existing: Set<String> = ["untitled folder"]
        XCTAssertEqual(
            FolderBrowsing.uniqueName(desired: "untitled folder", existing: existing),
            "untitled folder 2")
    }

    func testUniqueNameSkipsMultipleCollisions() {
        let existing: Set<String> = ["a", "a 2", "a 3"]
        XCTAssertEqual(FolderBrowsing.uniqueName(desired: "a", existing: existing), "a 4")
    }

    func testUniqueNamePreservesExtension() {
        let existing: Set<String> = ["notes.txt"]
        XCTAssertEqual(
            FolderBrowsing.uniqueName(desired: "notes.txt", existing: existing),
            "notes 2.txt")
    }

    // MARK: - FileTypeFilter

    /// Build an in-memory `FileItem` (no disk access needed for classification).
    private func item(_ name: String, dir: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"),
                 isDirectory: dir,
                 sizeBytes: 0,
                 modifiedAt: .distantPast)
    }

    func testFilterAllMatchesEverything() {
        let filter = FolderBrowsing.FileTypeFilter.all
        XCTAssertTrue(filter.matches(item("Alpha", dir: true)))
        XCTAssertTrue(filter.matches(item("beta.txt")))
        XCTAssertTrue(filter.matches(item("backup.zip")))
    }

    func testFilterFoldersMatchesOnlyDirectories() {
        let filter = FolderBrowsing.FileTypeFilter.folders
        XCTAssertTrue(filter.matches(item("Alpha", dir: true)))
        XCTAssertFalse(filter.matches(item("beta.txt")))
    }

    func testFilterArchivesUsesArchiveFormats() {
        let filter = FolderBrowsing.FileTypeFilter.archives
        XCTAssertTrue(filter.matches(item("backup.zip")))
        XCTAssertTrue(filter.matches(item("data.tar.gz")))
        XCTAssertFalse(filter.matches(item("beta.txt")))
        XCTAssertFalse(filter.matches(item("Alpha", dir: true)))
    }

    func testFilterImagesDocumentsMediaByExtension() {
        XCTAssertTrue(FolderBrowsing.FileTypeFilter.images.matches(item("photo.PNG")))
        XCTAssertTrue(FolderBrowsing.FileTypeFilter.images.matches(item("scan.heic")))
        XCTAssertFalse(FolderBrowsing.FileTypeFilter.images.matches(item("beta.txt")))

        XCTAssertTrue(FolderBrowsing.FileTypeFilter.documents.matches(item("report.pdf")))
        XCTAssertTrue(FolderBrowsing.FileTypeFilter.documents.matches(item("beta.txt")))
        XCTAssertFalse(FolderBrowsing.FileTypeFilter.documents.matches(item("photo.png")))

        XCTAssertTrue(FolderBrowsing.FileTypeFilter.media.matches(item("song.mp3")))
        XCTAssertTrue(FolderBrowsing.FileTypeFilter.media.matches(item("clip.mov")))
        XCTAssertFalse(FolderBrowsing.FileTypeFilter.media.matches(item("report.pdf")))
    }

    func testFilterOtherCatchesUnclassifiedFilesOnly() {
        let filter = FolderBrowsing.FileTypeFilter.other
        XCTAssertTrue(filter.matches(item("binary.dat")))
        XCTAssertTrue(filter.matches(item("no-extension")))
        XCTAssertFalse(filter.matches(item("backup.zip")))
        XCTAssertFalse(filter.matches(item("photo.png")))
        XCTAssertFalse(filter.matches(item("beta.txt")))
        XCTAssertFalse(filter.matches(item("Alpha", dir: true)))
    }
}
