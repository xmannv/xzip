import XCTest
import XZIPCore
import XZIPDomain
@testable import XZip

/// Covers the seam between `ArchiveMutationGate` and the password prompt.
///
/// The gate and the prompt were developed on separate branches and both run on
/// the main actor, so this exercises them together: a mutation that holds an
/// archive's slot must not starve the prompt, and a refused mutation has to tell
/// the user rather than disappearing.
@MainActor
final class ArchiveMutationGateAppModelTests: XCTestCase {

    // MARK: - Refusal is reported

    func testASecondMutationOfTheSameArchiveTellsTheUserItIsBusy() async throws {
        let archive = try makeArchive()
        let editor = LatchingEditor()
        let model = makeModel(editor: editor)
        try await open(archive, in: model)

        let file = try makeSourceFile()
        model.addFilesToArchive([file])
        // Wait for the mutation to reach the gate: `ArchiveService` claims the
        // slot inside the async call, so it is not held the instant this returns.
        try await Self.settle()
        // The first add must now be in flight, holding the archive's slot.
        XCTAssertTrue(model.mutationGate.isMutating(archive))
        XCTAssertNil(model.errorMessage)

        model.addFilesToArchive([file])
        try await Self.settle()

        XCTAssertNotNil(
            model.errorMessage,
            "a refused mutation must surface a message, not fail silently")

        await editor.release()
        try await Self.settle()
    }

    func testMutatingADifferentArchiveIsNotRefused() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        let editor = LatchingEditor()
        let model = makeModel(editor: editor)
        let file = try makeSourceFile()

        try await open(first, in: model)
        model.addFilesToArchive([file])
        try await Self.settle()
        XCTAssertTrue(model.mutationGate.isMutating(first))

        // Switching to another archive and mutating it must not be blocked: the
        // gate keys work per archive, so only same-file rewrites wait.
        try await open(second, in: model)
        model.addFilesToArchive([file])
        try await Self.settle()

        XCTAssertNil(
            model.errorMessage,
            "mutating a different archive must not be refused")
        XCTAssertTrue(model.mutationGate.isMutating(second))

        await editor.release()
        try await Self.settle()
    }

    // MARK: - The prompt still works while a mutation holds the slot

    func testPasswordPromptStillPresentsWhileAMutationIsInFlight() async throws {
        let archive = try makeArchive()
        let editor = LatchingEditor()
        let model = makeModel(editor: editor)
        try await open(archive, in: model)

        let file = try makeSourceFile()
        model.addFilesToArchive([file])
        try await Self.settle()
        XCTAssertTrue(model.mutationGate.isMutating(archive))

        // The gated mutation awaits inside a main-actor task. If holding the slot
        // starved the actor, this prompt could never be raised.
        model.presentPasswordPrompt(for: archive, validationContext: .extraction)
        try await Self.settle()

        XCTAssertTrue(
            model.isPasswordPromptPresented,
            "an in-flight mutation must not block the password prompt")
        XCTAssertEqual(model.passwordPromptTarget, archive)

        await editor.release()
        try await Self.settle()
    }

    func testAMutationCanStartWhileAPasswordPromptIsOpen() async throws {
        let archive = try makeArchive()
        let editor = LatchingEditor()
        let model = makeModel(editor: editor)
        try await open(archive, in: model)

        model.presentPasswordPrompt(for: archive, validationContext: .extraction)
        try await Self.settle()
        XCTAssertTrue(model.isPasswordPromptPresented)

        // The prompt is modal in the UI only. It must not wedge the gate, or the
        // archive would stay unmutatable until the sheet is dismissed.
        let file = try makeSourceFile()
        model.addFilesToArchive([file])
        try await Self.settle()

        XCTAssertTrue(
            model.mutationGate.isMutating(archive),
            "an open prompt must not prevent a mutation from starting")
        XCTAssertNil(model.errorMessage)

        await editor.release()
        try await Self.settle()
    }

    // MARK: - Save-back queues instead of being refused

    func testSaveBackQueuesBehindAUserMutationRatherThanBeingDropped() async throws {
        let archive = try makeArchive()
        let gate = ArchiveMutationGate()
        let order = Recorder()
        let editor = LatchingEditor()

        XCTAssertTrue(gate.tryRun(archive: archive) {
            await editor.wait()
            order.record("user-edit")
        })

        // Edit & Save Back is driven by the file-system watcher, so it must wait
        // its turn: dropping it would discard an edit the user believes is saved.
        let saveBack = Task { @MainActor in
            try await gate.enqueue(archive: archive) { order.record("save-back") }
        }
        await Task.yield()
        XCTAssertTrue(order.events.isEmpty, "neither mutation should have run yet")

        await editor.release()
        try await saveBack.value

        XCTAssertEqual(order.events, ["user-edit", "save-back"])
    }

    // MARK: - Helpers

    /// Opens `archive`, then drops the error the open itself produced.
    ///
    /// The stub service deliberately has no engines, so the listing pass behind
    /// `openArchive` fails with "Unsupported format". These tests assert on the
    /// message a *refused mutation* produces, so that unrelated error has to be
    /// cleared or it would be mistaken for one.
    private func open(_ archive: URL, in model: AppModel) async throws {
        model.openArchive(archive)
        try await Self.settle()
        model.errorMessage = nil
    }

    private func makeModel(editor: any ArchiveEditing) -> AppModel {
        // Bypass the conflict pre-scan, which would divert into the dialog path.
        UserDefaults.standard.set(
            ConflictPolicy.replace.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        let service = ArchiveService(
            // No engines: these tests drive the editor (add / delete / rename),
            // never an extraction, and format detection reads magic bytes.
            engineFactory: ArchiveEngineFactory(engines: []),
            editor: editor,
            passwordStore: NoopStore(),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("gate-appmodel-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        return AppModel(service: service)
    }

    /// A real zip header so `detectedFormat` resolves the format and the add
    /// takes the native-append branch that goes through the gate.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-appmodel-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: archive)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    private func makeSourceFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-source-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    /// The model hands work to detached main-actor tasks, so give them room to
    /// reach a terminal state. Static so awaiting it from a `@MainActor` test
    /// does not send `self` across an isolation boundary.
    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }
}

/// Records the order mutations ran in. A class because the gate's closures are
/// `@Sendable`, which rules out mutating a captured local.
@MainActor
private final class Recorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Holds every mutation open until the test releases it, so a test can observe
/// the gate while a rewrite is genuinely in flight.
///
/// An `actor` rather than a locked class: `ArchiveEditing` is `Sendable` and its
/// requirements are `async`, and a plain mutex cannot be taken from an async
/// context.
private actor LatchingEditor: ArchiveEditing {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {
        await wait()
    }
    func delete(entries: [String], from archive: URL, password: String?) async throws {
        await wait()
    }
    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        await wait()
    }
    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {
        await wait()
    }
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        await wait()
    }
}

private struct NoopStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
