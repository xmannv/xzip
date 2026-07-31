import Foundation
import XCTest
import XZIPCore
@testable import XZip

/// Dragging a folder out of an archive used to deliver nothing: the export path
/// filtered every folder away (`entries.filter { !isFolder($0) }`), so the
/// selection came back empty and Finder failed the drop. Selecting a folder plus
/// loose files therefore extracted only the files.
///
/// The contract these lock down: a folder is expanded to the file entries beneath
/// it (a folder row can be synthesized for a directory the archive never
/// recorded, so passing its own path to 7zz matches nothing), and the URL handed
/// to Finder is the folder itself rather than a file inside it — dragging `Docs/`
/// must deliver `Docs/` with its tree intact.
final class FolderDragExportTests: XCTestCase {
    private var parent: URL!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    /// The reported bug: a dragged folder produced no export at all.
    @MainActor
    func testDraggingAFolderDeliversTheFolderItself() async throws {
        let fixture = try makeFixture(archivePaths: [
            "Docs/a.txt",
            "Docs/nested/b.txt",
            "loose.txt"
        ])

        let url = await fixture.model.extractEntryToTemp(folderEntry(path: "Docs"))

        let delivered = try XCTUnwrap(url, "a dragged folder must produce an export")
        XCTAssertEqual(
            delivered.lastPathComponent,
            "Docs",
            "Finder must receive the folder, not a file inside it"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: delivered.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue, "the delivered URL must be a directory")
    }

    /// The tree has to survive, which is what the user asked for: `Docs/` arrives
    /// whole rather than flattened.
    @MainActor
    func testTheFoldersTreeIsExtractedIntact() async throws {
        let fixture = try makeFixture(archivePaths: [
            "Docs/a.txt",
            "Docs/nested/b.txt"
        ])

        let exported = await fixture.model.extractEntryToTemp(folderEntry(path: "Docs"))
        let delivered = try XCTUnwrap(exported)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: delivered.appendingPathComponent("a.txt").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: delivered.appendingPathComponent("nested/b.txt").path
            ),
            "a nested descendant must be extracted too, not just direct children"
        )
    }

    /// A folder row is often synthesized for a directory the archive never stored,
    /// so the folder's own path must not be what gets handed to the engine.
    @MainActor
    func testFolderIsExpandedToItsDescendantEntries() async throws {
        let fixture = try makeFixture(archivePaths: [
            "Docs/a.txt",
            "Docs/nested/b.txt",
            "elsewhere/c.txt"
        ])

        _ = await fixture.model.extractEntryToTemp(folderEntry(path: "Docs"))

        XCTAssertEqual(
            fixture.engine.requestedEntries.sorted(),
            ["Docs/a.txt", "Docs/nested/b.txt"],
            "the folder expands to its own descendants only"
        )
        XCTAssertFalse(
            fixture.engine.requestedEntries.contains("Docs"),
            "a synthesized folder path matches no archive entry"
        )
    }

    /// The mixed selection from the report: one folder plus loose files.
    @MainActor
    func testMixedSelectionExtractsFoldersAndFilesTogether() async throws {
        let fixture = try makeFixture(archivePaths: [
            "Docs/a.txt",
            "loose.txt",
            "other.txt"
        ])

        let urls = await fixture.model.extractEntriesToTemp([
            folderEntry(path: "Docs"),
            fileEntry(path: "loose.txt")
        ])

        XCTAssertEqual(
            fixture.engine.requestedEntries.sorted(),
            ["Docs/a.txt", "loose.txt"],
            "both the folder's contents and the loose file must be extracted"
        )
        XCTAssertFalse(urls.isEmpty)
        XCTAssertFalse(
            fixture.engine.requestedEntries.contains("other.txt"),
            "an unselected file must not be dragged along"
        )
    }

    /// Selecting a file that already lives inside a selected folder must not
    /// extract it twice.
    @MainActor
    func testAFileInsideASelectedFolderIsNotDuplicated() async throws {
        let fixture = try makeFixture(archivePaths: ["Docs/a.txt", "Docs/b.txt"])

        _ = await fixture.model.extractEntriesToTemp([
            folderEntry(path: "Docs"),
            fileEntry(path: "Docs/a.txt")
        ])

        XCTAssertEqual(
            fixture.engine.requestedEntries.sorted(),
            ["Docs/a.txt", "Docs/b.txt"]
        )
    }

    /// A folder whose name prefixes another's must not drag the sibling in.
    @MainActor
    func testASiblingSharingANamePrefixIsNotIncluded() async throws {
        let fixture = try makeFixture(archivePaths: ["Docs/a.txt", "Docs-backup/b.txt"])

        _ = await fixture.model.extractEntryToTemp(folderEntry(path: "Docs"))

        XCTAssertEqual(
            fixture.engine.requestedEntries,
            ["Docs/a.txt"],
            "matching must respect the path separator, not raw string prefixes"
        )
    }

    /// An empty folder has no descendants, so there is nothing to extract and the
    /// promise has to fail rather than deliver a bogus URL.
    @MainActor
    func testAnEmptyFolderProducesNoExport() async throws {
        let fixture = try makeFixture(archivePaths: ["other/a.txt"])

        let url = await fixture.model.extractEntryToTemp(folderEntry(path: "Empty"))

        XCTAssertNil(url)
    }

    /// Files keep their existing behaviour: the file's own URL is delivered.
    @MainActor
    func testDraggingAFileStillDeliversThatFile() async throws {
        let fixture = try makeFixture(archivePaths: ["Docs/a.txt", "loose.txt"])

        let exported = await fixture.model.extractEntryToTemp(fileEntry(path: "loose.txt"))
        let delivered = try XCTUnwrap(exported)

        XCTAssertEqual(delivered.lastPathComponent, "loose.txt")
    }

    // MARK: - Helpers

    @MainActor
    private func makeFixture(
        archivePaths: [String]
    ) throws -> (model: AppModel, engine: FolderDragEngine) {
        let archive = parent.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        let engine = FolderDragEngine()
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: FolderDragNoopEditor(),
            passwordStore: FolderDragNoopPasswordStore(),
            presetStore: PresetStore(
                fileURL: parent.appendingPathComponent("presets-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        let model = AppModel(
            service: service,
            scratch: ScratchStore(
                parent: parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
        )
        let open = OpenArchive(url: archive)
        model.openArchives = [open]
        model.currentArchiveID = open.id
        // `expandFoldersToFileEntries` resolves descendants against the loaded
        // listing, so the model has to hold the archive's file rows.
        model.archiveEntries = archivePaths.map { fileEntry(path: $0) }
        return (model, engine)
    }

    private func fileEntry(path: String) -> XZip.ArchiveEntry {
        XZip.ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: .document,
            originalSize: 9,
            compressedSize: 9,
            modifiedAt: Date()
        )
    }

    private func folderEntry(path: String) -> XZip.ArchiveEntry {
        XZip.ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: .folder,
            originalSize: 0,
            compressedSize: 0,
            modifiedAt: Date()
        )
    }
}

/// Writes each requested entry at its full in-archive path, the way `7zz x`
/// does, and records what was asked for.
private final class FolderDragEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]

    private let lock = NSLock()
    private var recorded: [String] = []

    var requestedEntries: [String] { lock.withLock { recorded } }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.withLock { recorded = options.selectedEntries }
        return AsyncThrowingStream { continuation in
            do {
                for entry in options.selectedEntries {
                    let output = destination.appendingPathComponent(entry)
                    try FileManager.default.createDirectory(
                        at: output.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("plaintext".utf8).write(to: output)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] { [] }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        ArchiveListingResult(entries: [], truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool { true }
}

private struct FolderDragNoopPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}

private struct FolderDragNoopEditor: ArchiveEditing {
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}
    func delete(entries: [String], from archive: URL, password: String?) async throws {}
    func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws {}
    func update(entry entryPath: String, from workingDirectory: URL, in archive: URL, password: String?) async throws {}
}
