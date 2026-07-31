import Foundation
import XCTest
import XZIPCore
@testable import XZip

/// A window presents one sheet at a time, and `MainWindowView` attaches several
/// to the same view. A password prompt raised while one of those is up used to be
/// dropped by SwiftUI while the model went on believing the sheet was visible —
/// so every later prompt queued behind a presentation that never happened, and
/// no user-visible event could ever clear it.
///
/// These cover the two halves of the fix: the prompt is deferred rather than
/// published into an occupied slot, and it is raised again once the slot frees.
final class PasswordPromptSheetSlotTests: XCTestCase {

    @MainActor
    func testPromptIsDeferredWhileAnotherSheetOwnsTheSlot() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel()
        // An unrelated sheet is up. This is the state that used to swallow the
        // prompt: SwiftUI never builds it, so no `onDismiss` ever arrives.
        model.errorMessage = "Something already went wrong."

        model.presentPasswordPrompt(for: archive)

        XCTAssertFalse(
            model.isPasswordPromptPresented,
            "publishing into an occupied slot is what SwiftUI silently drops"
        )
        XCTAssertNil(
            model.passwordPromptArchive,
            "a prompt that cannot be shown must not be treated as active"
        )
    }

    /// The half that makes deferring recoverable rather than a one-way trip.
    @MainActor
    func testDeferredPromptIsRaisedOnceTheSlotFrees() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel()
        model.errorMessage = "Something already went wrong."
        model.presentPasswordPrompt(for: archive)
        XCTAssertFalse(model.isPasswordPromptPresented)

        // What `MainWindowView` observes: the competing sheet closed.
        model.errorMessage = nil
        model.resumeDeferredPasswordPromptIfPossible()

        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(model.passwordPromptArchive, archive)
    }

    /// Resuming must not steal a slot another sheet still owns, otherwise the
    /// prompt is dropped exactly as before.
    @MainActor
    func testResumeIsANoOpWhileASheetIsStillPresented() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel()
        model.errorMessage = "Something already went wrong."
        model.presentPasswordPrompt(for: archive)

        // Two sheets were queued; only one of them closed.
        model.newItemRequest = NewItemRequest(kind: .folder)
        model.errorMessage = nil
        model.resumeDeferredPasswordPromptIfPossible()

        XCTAssertFalse(
            model.isPasswordPromptPresented,
            "the slot is still occupied by the other sheet"
        )

        // Once the last one goes, the prompt is finally raised.
        model.newItemRequest = nil
        model.resumeDeferredPasswordPromptIfPossible()
        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(model.passwordPromptArchive, archive)
    }

    /// Called on every change of the observed flag, including ones with nothing
    /// waiting, so it has to stay harmless.
    @MainActor
    func testResumeWithNothingQueuedDoesNotRaiseASheet() {
        let model = makeModel()

        model.resumeDeferredPasswordPromptIfPossible()

        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertNil(model.passwordPromptArchive)
    }

    /// Cancelling a prompt can itself raise a sheet (an operation's failure sets
    /// `errorMessage`). Reserving the next queued prompt into that slot would
    /// lose it the same way, so the dismissal path checks too.
    @MainActor
    func testDismissalDoesNotAdvanceTheQueueIntoASheetItJustRaised() throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makeModel()

        model.presentPasswordPrompt(for: first)
        XCTAssertTrue(model.isPasswordPromptPresented)
        let presentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        // Queued behind the visible one.
        model.presentPasswordPrompt(for: second)

        // The first prompt closes, and a failure raises an error sheet in the
        // same turn.
        model.errorMessage = "The operation failed."
        model.passwordPromptDidDismiss(presentationID: presentationID)

        XCTAssertFalse(
            model.isPasswordPromptPresented,
            "the error sheet owns the slot, so the queued prompt must wait"
        )

        model.errorMessage = nil
        model.resumeDeferredPasswordPromptIfPossible()

        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(
            model.passwordPromptArchive,
            second,
            "the queued prompt must survive, not be consumed by the blocked advance"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel() -> AppModel {
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [SheetSlotEngine()]),
            editor: SheetSlotNoopEditor(),
            passwordStore: SheetSlotPasswordStore(),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("sheet-slot-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        return AppModel(service: service)
    }

    /// A real zip signature so `detectedFormat` resolves an engine.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheet-slot-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        return archive
    }
}

private struct SheetSlotEngine: ArchiveEngine {
    let supportedFormats: Set<ArchiveFormat> = [.zip]

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
        AsyncThrowingStream { $0.finish() }
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

private struct SheetSlotNoopEditor: ArchiveEditing {
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}
    func delete(entries: [String], from archive: URL, password: String?) async throws {}
    func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws {}
    func update(entry: String, from workingDirectory: URL, in archive: URL, password: String?) async throws {}
}

private struct SheetSlotPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
