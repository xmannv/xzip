import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZip

final class ArchiveServiceTests: XCTestCase {
    func testCompressRejectsInvalidDestinationNameBeforeEngineInvocation() throws {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)
        let destination = URL(fileURLWithPath: "/tmp/bad\nname.zip")

        XCTAssertThrowsError(try service.compress(
            sources: [URL(fileURLWithPath: "/tmp/input")],
            destination: destination,
            options: CompressionOptions(format: .zip)
        )) { error in
            XCTAssertEqual(
                error as? ArchiveNameValidationError,
                .containsLineBreak("bad\nname.zip")
            )
        }
        XCTAssertEqual(engine.compressCallCount, 0)
    }

    func testCompressPreservesValidDestinationWhitespace() throws {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)
        let destination = URL(fileURLWithPath: "/tmp/ report .zip")

        _ = try service.compress(
            sources: [URL(fileURLWithPath: "/tmp/input")],
            destination: destination,
            options: CompressionOptions(format: .zip)
        )

        XCTAssertEqual(engine.compressCallCount, 1)
        XCTAssertEqual(engine.lastCompressionDestination, destination)
    }

    func testRenameAcceptsExpandedFolderMappingAndForwardsExactPairs() async throws {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)
        let pairs = [
            (entry: "docs", newName: "notes"),
            (entry: "docs/report.txt", newName: "notes/report.txt"),
            (entry: "docs/nested/data.bin", newName: "notes/nested/data.bin")
        ]

        try await service.rename(
            pairs: pairs,
            in: URL(fileURLWithPath: "/tmp/archive.zip"),
            password: nil,
            admission: .refuseIfBusy
        )

        XCTAssertEqual(editor.renameCallCount, 1)
        XCTAssertEqual(editor.lastRenameEntries, pairs.map(\.entry))
        XCTAssertEqual(editor.lastRenameDestinations, pairs.map(\.newName))
    }

    func testRenameRejectsDestinationOutsideSourceParentBeforeEditorInvocation() async {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)

        do {
            try await service.rename(
                pairs: [(entry: "docs/report.txt", newName: "../escape.txt")],
                in: URL(fileURLWithPath: "/tmp/archive.zip"),
                password: nil,
                admission: .refuseIfBusy
            )
            XCTFail("Expected unsafe rename destination to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? ArchiveNameValidationError,
                .unsafeRelativePath("../escape.txt")
            )
        }
        XCTAssertEqual(editor.renameCallCount, 0)
    }

    func testRenameRejectsUnsafeLaterPairBeforeEditorInvocation() async {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)

        do {
            try await service.rename(
                pairs: [
                    (entry: "docs/first.txt", newName: "docs/renamed.txt"),
                    (entry: "docs/second.txt", newName: "../escape.txt")
                ],
                in: URL(fileURLWithPath: "/tmp/archive.zip"),
                password: nil,
                admission: .refuseIfBusy
            )
            XCTFail("Expected every rename pair to be validated.")
        } catch {
            XCTAssertEqual(
                error as? ArchiveNameValidationError,
                .unsafeRelativePath("../escape.txt")
            )
        }
        XCTAssertEqual(editor.renameCallCount, 0)
    }

    func testRenameRejectsSourceParentOutsideVirtualArchiveRoot() async {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)

        do {
            try await service.rename(
                pairs: [(entry: "../report.txt", newName: "../renamed.txt")],
                in: URL(fileURLWithPath: "/tmp/archive.zip"),
                password: nil,
                admission: .refuseIfBusy
            )
            XCTFail("Expected an escaping archive-relative parent to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? ArchiveNameValidationError,
                .unsafeRelativePath("../renamed.txt")
            )
        }
        XCTAssertEqual(editor.renameCallCount, 0)
    }

    @MainActor
    func testCreateNewItemRejectsNormalizedParentTraversalBeforeFilesystemOrService() async throws {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)
        let model = AppModel(service: service)
        let archive = OpenArchive(url: URL(fileURLWithPath: "/tmp/archive.zip"))
        model.openArchives = [archive]
        model.currentArchiveID = archive.id
        model.currentFolderPath = "safe/../other"

        model.createNewItem(kind: .folder, name: "child")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(editor.addCallCount, 0)
    }

    @MainActor
    func testNewFolderFromSelectionRejectsEscapingCurrentFolderBeforeFilesystemOrService() async throws {
        let engine = EngineProbe()
        let editor = EditorProbe()
        let service = makeService(engine: engine, editor: editor)
        let escapeName = "XZipSelectionEscape-\(UUID().uuidString)"
        let escapedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(escapeName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedRoot) }

        let model = AppModel(service: service)
        let archive = OpenArchive(url: URL(fileURLWithPath: "/tmp/archive.zip"))
        model.openArchives = [archive]
        model.currentArchiveID = archive.id
        model.currentFolderPath = "../\(escapeName)"

        model.newFolderFromSelection(named: "child")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedRoot.path))
        XCTAssertEqual(editor.addCallCount, 0)
    }

    private func makeService(engine: EngineProbe, editor: EditorProbe) -> ArchiveService {
        ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: editor,
            passwordStore: PasswordStoreProbe(),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ArchiveServiceTests-presets-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
    }
}

private final class EngineProbe: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]

    private let lock = NSLock()
    private var compressCalls = 0
    private var compressionDestination: URL?

    var compressCallCount: Int {
        lock.withLock { compressCalls }
    }

    var lastCompressionDestination: URL? {
        lock.withLock { compressionDestination }
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.withLock {
            compressCalls += 1
            compressionDestination = destination
        }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
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

private final class EditorProbe: ArchiveEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var addCalls = 0
    private var renameCalls = 0
    private var renameEntries: [String] = []
    private var renameDestinations: [String] = []

    var addCallCount: Int {
        lock.withLock { addCalls }
    }

    var renameCallCount: Int {
        lock.withLock { renameCalls }
    }

    var lastRenameEntries: [String] {
        lock.withLock { renameEntries }
    }

    var lastRenameDestinations: [String] {
        lock.withLock { renameDestinations }
    }

    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {
        lock.withLock { addCalls += 1 }
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {}

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        lock.withLock {
            renameCalls += 1
            renameEntries = pairs.map(\.entry)
            renameDestinations = pairs.map(\.newName)
        }
    }

    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {}

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}
}

private struct PasswordStoreProbe: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
