import XCTest
import XZIPCore
import XZIPDomain
@testable import XZip

/// Proves that **every** way the app rewrites an archive goes through
/// `ArchiveMutationGate`.
///
/// The gate is only worth having if nothing can slip past it, and that property
/// is easy to break by adding a new action that calls the editor directly — which
/// is exactly how "New Folder from Selection" and the comment writer ended up
/// ungated. So rather than testing the gate's own mechanics (see
/// `ArchiveMutationGateTests`), each test here holds the archive's slot and then
/// asserts the entry point never reached the editor.
///
/// A path that bypassed the gate would show up as a non-zero call count on the
/// editor probe while the slot is held.
@MainActor
final class ArchiveMutationGatingTests: XCTestCase {

    // MARK: - The gate is a single shared instance

    func testTheModelAndTheServiceShareOneGate() throws {
        let model = try makeModel().model

        // Two gates would serialize nothing: a mutation could hold one while the
        // UI consulted (and cancelled through) the other.
        XCTAssertTrue(
            model.mutationGate === model.service.mutationGate,
            "AppModel must forward to the service's gate, not own a second one")
    }

    // MARK: - Every entry point is gated

    func testAddingFilesIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()
        let file = try makeSourceFile()
        try await holdingTheGate(context) {
            context.model.addFilesToArchive([file])
        }

        XCTAssertEqual(context.editor.addCallCount, 0, "add bypassed the gate")
        XCTAssertNotNil(context.model.errorMessage, "the refusal must be reported")
    }

    func testDeletingEntriesIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()
        context.model.archiveEntries = [entry("file.txt")]
        context.model.selectedArchiveEntryIDs = ["file.txt"]

        try await holdingTheGate(context) {
            context.model.deleteSelectedEntries()
        }

        XCTAssertEqual(context.editor.deleteCallCount, 0, "delete bypassed the gate")
        XCTAssertNotNil(context.model.errorMessage)
    }

    func testRenamingAnEntryIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()
        context.model.archiveEntries = [entry("file.txt")]

        try await holdingTheGate(context) {
            context.model.renameEntry("file.txt", to: "renamed.txt")
        }

        XCTAssertEqual(context.editor.renameCallCount, 0, "rename bypassed the gate")
        XCTAssertNotNil(context.model.errorMessage)
    }

    func testCreatingAnItemIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()

        try await holdingTheGate(context) {
            context.model.createNewItem(kind: .file, name: "note.txt")
        }

        XCTAssertEqual(context.editor.addCallCount, 0, "New Item bypassed the gate")
        XCTAssertNotNil(context.model.errorMessage)
    }

    /// The regression this suite exists for: `newFolderFromSelection` used to be a
    /// copy of the New Item pipeline that never took the archive's turn.
    func testNewFolderFromSelectionIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()

        try await holdingTheGate(context) {
            context.model.newFolderFromSelection(named: "Untitled")
        }

        XCTAssertEqual(
            context.editor.addCallCount, 0,
            "New Folder from Selection bypassed the gate")
        XCTAssertNotNil(context.model.errorMessage)
    }

    func testWritingACommentIsRefusedWhileTheArchiveIsBusy() async throws {
        let context = try makeModel()
        let latch = Latch()
        XCTAssertTrue(context.model.mutationGate.tryRun(archive: context.archive) {
            await latch.wait()
        })

        do {
            // `zip -z` rewrites the central directory, so this is a mutation like
            // any other; it used to reach the archive with no turn taken.
            try await context.model.service.writeComment(
                "hello", to: context.archive, admission: .refuseIfBusy)
            XCTFail("a comment write must not proceed while the archive is busy")
        } catch is ArchiveMutationGate.ArchiveBusyError {
            // Expected.
        }

        latch.open()
        try await Self.settle()
    }

    // MARK: - Save-back queues rather than being refused

    func testSaveBackWaitsItsTurnInsteadOfBeingRefused() async throws {
        let context = try makeModel()
        let latch = Latch()
        XCTAssertTrue(context.model.mutationGate.tryRun(archive: context.archive) {
            await latch.wait()
        })

        // Edit & Save Back is watcher-driven: refusing it would silently discard
        // an edit the user already made and believes is saved.
        let queued = Task { @MainActor in
            try await context.model.service.update(
                entry: "file.txt",
                from: FileManager.default.temporaryDirectory,
                in: context.archive,
                password: nil,
                admission: .waitTurn)
        }
        await Task.yield()
        XCTAssertEqual(
            context.editor.updateCallCount, 0,
            "the queued save-back must wait, not run alongside the running mutation")

        latch.open()
        try await queued.value

        XCTAssertEqual(
            context.editor.updateCallCount, 1,
            "the save-back must still run once the archive is free")
    }

    // MARK: - Double-submit before the claim lands

    /// The gate is claimed inside the async mutation, so for one turn after a
    /// mutation is requested `isMutating` still reads false. `repackAdd` has side
    /// effects before that claim (it raises the progress sheet), so it must not
    /// gate on `isMutating`: a second drop in that window would overwrite the
    /// sheet state and its teardown would dismiss the sheet of the repack still
    /// running, orphaning Cancel.
    func testASecondRepackInTheSameTurnIsRefusedBeforeTouchingTheSheet() throws {
        let context = try makeModel(archiveExtension: "tar.gz")
        let file = try makeSourceFile()

        // Both calls in one turn: nothing has awaited, so no claim has landed.
        context.model.addFilesToArchive([file])
        let sheetAfterFirst = context.model.activeRepack
        context.model.addFilesToArchive([file])

        XCTAssertNotNil(sheetAfterFirst, "the first repack must raise its sheet")
        XCTAssertEqual(
            context.model.activeRepack?.id, sheetAfterFirst?.id,
            "a refused second repack must not replace the running repack's sheet")
        XCTAssertEqual(
            context.model.repackArchive, context.archive,
            "the cancel target must still point at the running repack")
        XCTAssertNotNil(context.model.errorMessage, "the refusal must be reported")
    }

    // MARK: - A free archive is not blocked

    func testAddingFilesProceedsWhenTheArchiveIsFree() async throws {
        let context = try makeModel()
        let file = try makeSourceFile()

        context.model.addFilesToArchive([file])
        try await Self.settle()

        XCTAssertEqual(context.editor.addCallCount, 1)
        // Not `assertNil(errorMessage)`: the add is followed by a refresh, and
        // this service has no engines, so the listing legitimately fails here.
        // What matters is that the mutation was not turned away as busy.
        XCTAssertNotEqual(
            context.model.errorMessage,
            ArchiveMutationGate.ArchiveBusyError(archive: context.archive).localizedDescription,
            "an idle archive must not be reported as busy")
    }

    // MARK: - Helpers

    private struct Context {
        let model: AppModel
        let editor: EditorProbe
        let archive: URL
    }

    /// Runs `body` while `context.archive` is held by another mutation, then
    /// releases the slot and lets the refusal settle.
    private func holdingTheGate(
        _ context: Context,
        _ body: () -> Void
    ) async throws {
        let latch = Latch()
        XCTAssertTrue(
            context.model.mutationGate.tryRun(archive: context.archive) {
                await latch.wait()
            },
            "the test could not take the slot it needs to hold")

        body()
        try await Self.settle()

        latch.open()
        try await Self.settle()
    }

    private func makeModel(archiveExtension: String = "zip") throws -> Context {
        // Bypass the conflict pre-scan, which would divert into the dialog path.
        UserDefaults.standard.set(
            ConflictPolicy.replace.rawValue, forKey: XZIPDefaults.conflictPolicy)
        let editor = EditorProbe()
        let service = ArchiveService(
            // No engines: these tests drive the editor, never an extraction, and
            // format detection reads the file's magic bytes instead.
            engineFactory: ArchiveEngineFactory(engines: []),
            editor: editor,
            passwordStore: NoopPasswordStore(),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("gating-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        let model = AppModel(service: service)
        let archive = try makeArchive(extension: archiveExtension)
        let open = OpenArchive(url: archive)
        // Registered directly rather than via `openArchive`, whose listing pass
        // would fail (no engines) and leave an error these tests assert on.
        model.openArchives = [open]
        model.currentArchiveID = open.id
        return Context(model: model, editor: editor, archive: archive)
    }

    /// For `zip`, a real (empty) zip so `detectedFormat` resolves and the add path
    /// takes the native-append branch. For anything else, gzip magic bytes: that
    /// is not an appendable format, so `addFilesToArchive` falls through to the
    /// filename-based tar-wrapper check and routes into the repack pipeline.
    private func makeArchive(extension pathExtension: String) throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("gating-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        let contents: [UInt8] = pathExtension == "zip"
            ? [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
            : [0x1F, 0x8B, 0x08, 0x00]
        try Data(contents).write(to: archive)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    private func makeSourceFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gating-source-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    /// Explicitly `XZip.ArchiveEntry`: `XZIPCore` declares a type of the same
    /// name, and both modules are imported here.
    private func entry(_ path: String) -> XZip.ArchiveEntry {
        XZip.ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: .document,
            originalSize: 1,
            compressedSize: 1,
            modifiedAt: Date()
        )
    }

    /// The model hands work to main-actor tasks, so give them room to reach a
    /// terminal state. Static so awaiting it from a `@MainActor` test does not
    /// send `self` across an isolation boundary.
    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }
}

/// Holds a mutation open until the test releases it, so the gate can be observed
/// while a rewrite is genuinely in flight.
@MainActor
private final class Latch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Counts editor calls. Any non-zero count while the gate is held means that
/// mutation path reached `7zz` without taking a turn.
///
/// `@unchecked Sendable` with a lock because `ArchiveEditing` is `Sendable` and
/// its requirements are `async`, so the counters are touched off the main actor.
private final class EditorProbe: ArchiveEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var adds = 0
    private var deletes = 0
    private var renames = 0
    private var updates = 0

    var addCallCount: Int { lock.withLock { adds } }
    var deleteCallCount: Int { lock.withLock { deletes } }
    var renameCallCount: Int { lock.withLock { renames } }
    var updateCallCount: Int { lock.withLock { updates } }

    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {
        lock.withLock { adds += 1 }
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {
        lock.withLock { deletes += 1 }
    }

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        lock.withLock { renames += 1 }
    }

    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {
        lock.withLock { updates += 1 }
    }

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        lock.withLock { adds += 1 }
    }
}

private struct NoopPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
