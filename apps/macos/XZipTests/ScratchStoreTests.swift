import AppKit
import Foundation
import XCTest
import XZIPCore
@testable import XZip

/// Entries extracted for Quick Look, drag-out and Share are decrypted plaintext
/// when the archive is encrypted. Nothing used to remove them, so every preview
/// and every drag left a directory for the temp reaper, which can take days.
final class ScratchStoreTests: XCTestCase {

    private var parent: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Never the real temp directory: these tests delete what they find.
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
        parent = nil
        try super.tearDownWithError()
    }

    // MARK: - Preview lifetime

    /// Quick Look shows one file at a time, so a new preview means the old
    /// plaintext has no reader left and must go.
    @MainActor
    func testStartingAPreviewReleasesThePreviousOne() async throws {
        let store = ScratchStore(parent: parent)
        let first = try XCTUnwrap(store.makePreviewDirectory())
        try write("secret.txt", in: first)

        let second = try XCTUnwrap(store.makePreviewDirectory())

        XCTAssertFalse(exists(first), "the previous preview must be removed")
        XCTAssertTrue(exists(second))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Export lifetime

    /// The counterpart: these URLs go on the drag pasteboard, and the receiving app
    /// may read them long after the gesture ends. Deleting eagerly breaks the drop.
    @MainActor
    func testExportDirectoriesSurviveLaterExports() async throws {
        let store = ScratchStore(parent: parent)
        let first = try XCTUnwrap(store.makeExportDirectory())
        try write("dragged.txt", in: first)

        _ = try XCTUnwrap(store.makeExportDirectory())

        XCTAssertTrue(
            exists(first),
            "an exported file must still be readable after another export starts"
        )
    }

    /// A preview must not take an in-flight drag's files with it.
    @MainActor
    func testPreviewRotationLeavesExportsAlone() async throws {
        let store = ScratchStore(parent: parent)
        let export = try XCTUnwrap(store.makeExportDirectory())
        _ = store.makePreviewDirectory()
        _ = store.makePreviewDirectory()

        XCTAssertTrue(exists(export))
    }

    /// `NSItemProvider` cancels the `Progress` returned by its representation
    /// handler. That progress must own the extraction task so a cancelled drag
    /// discards partial plaintext before any URL is handed off.
    @MainActor
    func testCancelledDragCancelsAndDiscardsProvisionalExport() async throws {
        let fixture = try makeExportFixture(behavior: .waitForCancellation)
        let completed = expectation(description: "drag representation completed")
        let progress = ScratchExportItemProvider.startExport(
            entry: fixture.entry,
            model: fixture.model
        ) { _, _, _ in
            completed.fulfill()
        }
        await fulfillment(of: [fixture.engine.started], timeout: 1)
        guard let progress else {
            fixture.engine.finishPendingExport()
            await fulfillment(of: [completed], timeout: 1)
            XCTFail("drag representation must return cancellable Progress")
            return
        }

        progress.cancel()
        await fulfillment(of: [completed], timeout: 1)

        let destination = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(destination),
            "cancelled drag must remove partial decrypted plaintext"
        )
    }

    @MainActor
    func testCancellationWinsAtDragHandoffBoundary() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        let boundaryReached = expectation(description: "drag reached handoff boundary")
        let completed = expectation(description: "drag representation completed")
        let gate = ScratchExportTestGate()
        let progress = ScratchExportItemProvider.startExport(
            entry: fixture.entry,
            model: fixture.model,
            beforeDelivery: {
                boundaryReached.fulfill()
                await gate.wait()
            }
        ) { _, _, _ in
            completed.fulfill()
        }
        await fulfillment(of: [boundaryReached], timeout: 1)

        progress?.cancel()
        await gate.open()
        await fulfillment(of: [completed], timeout: 1)

        let destination = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(destination),
            "cancellation before handoff commit must discard decrypted plaintext"
        )
    }

    @MainActor
    func testAcceptedDragKeepsExportForLazyConsumer() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        let completed = expectation(description: "drag representation completed")

        let progress = ScratchExportItemProvider.startExport(
            entry: fixture.entry,
            model: fixture.model
        ) { _, _, _ in
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(progress?.completedUnitCount, 1)
        XCTAssertTrue(exists(try XCTUnwrap(fixture.engine.destination)))
    }

    /// Cancelling the "Other…" app chooser means no application accepted the URL.
    /// Its successful extraction therefore remains provisional and must be discarded.
    @MainActor
    func testCancelledOpenWithChooserDiscardsProvisionalExport() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        var offeredURL: URL?

        await ScratchExportConsumer.openWithChosenApp(
            entry: fixture.entry,
            model: fixture.model
        ) { url in
            offeredURL = url
            return false
        }

        XCTAssertNotNil(offeredURL, "chooser must receive the extracted URL")
        let destination = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(destination),
            "cancelled app chooser must remove decrypted plaintext"
        )
    }

    /// Dismissing the sharing-service picker before choosing a service means no
    /// lazy consumer accepted the URLs, so its provisional export must be discarded.
    @MainActor
    func testDismissedSharePickerDiscardsProvisionalExport() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        var presentedURLs: [URL] = []

        let sibling = XZip.ArchiveEntry(
            name: "other.txt",
            path: "other/other.txt",
            kind: .document,
            originalSize: 9,
            compressedSize: 9,
            modifiedAt: Date()
        )
        await ScratchExportConsumer.share(
            entries: [fixture.entry, sibling],
            model: fixture.model
        ) { urls, onCancelled in
            presentedURLs = urls
            onCancelled()
        }

        XCTAssertEqual(presentedURLs.count, 2)
        let destination = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(destination),
            "dismissed share picker must remove decrypted plaintext"
        )
    }

    @MainActor
    func testFailedDirectOpenDiscardsProvisionalExport() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)

        await ScratchExportConsumer.openWithApplication(
            entry: fixture.entry,
            model: fixture.model,
            applicationURL: URL(fileURLWithPath: "/Applications/Fake.app"),
            open: { _, _ in false }
        )

        let destination = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(destination),
            "failed application launch must remove decrypted plaintext"
        )
    }

    @MainActor
    func testAcceptedDirectOpenKeepsExportForLazyConsumer() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)

        await ScratchExportConsumer.openWithApplication(
            entry: fixture.entry,
            model: fixture.model,
            applicationURL: URL(fileURLWithPath: "/Applications/Fake.app"),
            open: { _, _ in true }
        )

        XCTAssertTrue(exists(try XCTUnwrap(fixture.engine.destination)))
    }

    @MainActor
    func testOpenWithServiceReportsWorkspaceFailure() async {
        let opened = await OpenWithService.open(
            URL(fileURLWithPath: "/tmp/file"),
            withApplicationAt: URL(fileURLWithPath: "/Applications/Fake.app"),
            perform: { completion in completion(false) }
        )

        XCTAssertFalse(opened)
    }

    @MainActor
    func testOpenWithServiceReportsWorkspaceAcceptance() async {
        let opened = await OpenWithService.open(
            URL(fileURLWithPath: "/tmp/file"),
            withApplicationAt: URL(fileURLWithPath: "/Applications/Fake.app"),
            perform: { completion in completion(true) }
        )

        XCTAssertTrue(opened)
    }

    @MainActor
    func testAcceptedOpenWithChooserKeepsExportForLazyConsumer() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)

        await ScratchExportConsumer.openWithChosenApp(
            entry: fixture.entry,
            model: fixture.model,
            chooseAndOpen: { _ in true }
        )

        XCTAssertTrue(exists(try XCTUnwrap(fixture.engine.destination)))
    }

    @MainActor
    func testAcceptedShareKeepsExportForLazyConsumer() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)

        await ScratchExportConsumer.share(
            entries: [fixture.entry],
            model: fixture.model,
            present: { _, _ in }
        )

        XCTAssertTrue(exists(try XCTUnwrap(fixture.engine.destination)))
    }

    @MainActor
    func testSelectingShareServiceWaitsForTerminalOutcome() async {
        var finished = false
        let handler = SharePicker.SelectionHandler(
            onCancelled: {},
            onFinished: { finished = true }
        )
        let service = NSSharingService(
            title: "Test",
            image: NSImage(),
            alternateImage: nil,
            handler: {}
        )

        handler.sharingServicePicker(
            NSSharingServicePicker(items: ["item"]),
            didChoose: service
        )

        XCTAssertFalse(
            finished,
            "choosing a service is not terminal; it can still fail while sharing"
        )
    }

    @MainActor
    func testFailedShareServiceDiscardsProvisionalExportOnce() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        var cancellationCount = 0
        var finishCount = 0

        await ScratchExportConsumer.share(
            entries: [fixture.entry],
            model: fixture.model
        ) { urls, onCancelled in
            let handler = SharePicker.SelectionHandler(
                onCancelled: {
                    cancellationCount += 1
                    onCancelled()
                },
                onFinished: { finishCount += 1 }
            )
            let service = NSSharingService(
                title: "Test",
                image: NSImage(),
                alternateImage: nil,
                handler: {}
            )
            handler.sharingServicePicker(
                NSSharingServicePicker(items: urls),
                didChoose: service
            )
            handler.sharingService(
                service,
                didFailToShareItems: urls,
                error: CocoaError(.fileWriteUnknown)
            )
            handler.sharingService(
                service,
                didFailToShareItems: urls,
                error: CocoaError(.fileWriteUnknown)
            )
        }

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(
            exists(try XCTUnwrap(fixture.engine.destination)),
            "failed share service must remove decrypted plaintext"
        )
    }

    @MainActor
    func testSuccessfulShareServiceKeepsProvisionalExportAndFinishesOnce() async throws {
        let fixture = try makeExportFixture(behavior: .succeed)
        var cancellationCount = 0
        var finishCount = 0

        await ScratchExportConsumer.share(
            entries: [fixture.entry],
            model: fixture.model
        ) { urls, onCancelled in
            let handler = SharePicker.SelectionHandler(
                onCancelled: {
                    cancellationCount += 1
                    onCancelled()
                },
                onFinished: { finishCount += 1 }
            )
            let service = NSSharingService(
                title: "Test",
                image: NSImage(),
                alternateImage: nil,
                handler: {}
            )
            handler.sharingServicePicker(
                NSSharingServicePicker(items: urls),
                didChoose: service
            )
            handler.sharingService(service, didShareItems: urls)
            handler.sharingService(service, didShareItems: urls)
            handler.sharingService(
                service,
                didFailToShareItems: urls,
                error: CocoaError(.fileWriteUnknown)
            )
        }

        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(
            exists(try XCTUnwrap(fixture.engine.destination)),
            "successful share must retain plaintext for lazy consumer"
        )
    }

    @MainActor
    func testSharePickerDelegateReportsDismissal() async {
        var wasCancelled = false
        let handler = SharePicker.SelectionHandler(
            onCancelled: { wasCancelled = true }
        )

        handler.sharingServicePicker(
            NSSharingServicePicker(items: ["item"]),
            didChoose: nil
        )

        XCTAssertTrue(wasCancelled)
    }

    /// Failed extraction can leave decrypted bytes behind before the engine reports
    /// its error. Those bytes were never handed to a consumer, so the provisional
    /// export directory must be removed immediately rather than retained until quit.
    @MainActor
    func testFailedExportRemovesPartialPlaintext() async throws {
        let fixture = try makeExportFixture(behavior: .fail)

        let exported = await fixture.model.extractEntriesToTemp([fixture.entry])

        XCTAssertTrue(exported.isEmpty)
        let failedExport = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(failedExport),
            "failed export must remove its directory and partial decrypted plaintext"
        )
    }

    /// Cancelling while the engine's progress stream is still open can make the
    /// async iterator end without throwing. Cancellation must still prevent a
    /// partial file from becoming a retained successful export.
    @MainActor
    func testCancelledExportRemovesPartialPlaintext() async throws {
        let fixture = try makeExportFixture(behavior: .waitForCancellation)
        let export = Task {
            await fixture.model.extractEntriesToTemp([fixture.entry])
        }
        await fulfillment(of: [fixture.engine.started], timeout: 1)

        export.cancel()
        let exported = await export.value

        XCTAssertTrue(exported.isEmpty, "cancelled export must not hand out partial files")
        let cancelledExport = try XCTUnwrap(fixture.engine.destination)
        XCTAssertFalse(
            exists(cancelledExport),
            "cancelled export must remove its directory and partial decrypted plaintext"
        )
    }

    // MARK: - Quit

    @MainActor
    func testRemoveAllClearsEverythingTheSessionCreated() async throws {
        let store = ScratchStore(parent: parent)
        let preview = try XCTUnwrap(store.makePreviewDirectory())
        let export = try XCTUnwrap(store.makeExportDirectory())
        try write("a.txt", in: preview)
        try write("b.txt", in: export)

        store.removeAll()

        XCTAssertFalse(exists(preview))
        XCTAssertFalse(exists(export))
        XCTAssertTrue(
            try contentsOfParent().isEmpty,
            "the session root itself must be gone, not just its contents"
        )
    }

    /// Quit with nothing previewed or dragged: there is no root, and asking for
    /// cleanup must not create one just to delete it.
    @MainActor
    func testRemoveAllOnAnUnusedStoreCreatesNothing() async throws {
        ScratchStore(parent: parent).removeAll()
        XCTAssertTrue(try contentsOfParent().isEmpty)
    }

    @MainActor
    func testRemoveAllIsSafeToCallTwice() async throws {
        let store = ScratchStore(parent: parent)
        _ = store.makePreviewDirectory()
        store.removeAll()
        store.removeAll()
        XCTAssertTrue(try contentsOfParent().isEmpty)
    }

    // MARK: - Leftovers from a previous run

    @MainActor
    func testStaleRootFromAnEarlierRunIsCollected() async throws {
        let stale = try makeDirectory("\(ScratchStore.rootPrefix)\(UUID().uuidString)")
        let current = parent.appendingPathComponent("\(ScratchStore.rootPrefix)current")

        XCTAssertEqual(
            ScratchStore.staleRoots(in: parent, excluding: current).map(\.lastPathComponent),
            [stale.lastPathComponent]
        )
    }

    /// The running session's own root is still in use.
    @MainActor
    func testCurrentRootIsExcluded() async throws {
        let current = try makeDirectory("\(ScratchStore.rootPrefix)current")
        XCTAssertTrue(ScratchStore.staleRoots(in: parent, excluding: current).isEmpty)
    }

    /// The rule this function exists for: it hands directories to `removeItem`, so
    /// anything that is not ours must not be collected.
    @MainActor
    func testUnrelatedDirectoriesAreNeverCollected() async throws {
        _ = try makeDirectory("my-notes")
        _ = try makeDirectory("my-\(ScratchStore.rootPrefix)notes")
        _ = try makeDirectory("Xcode")
        let current = parent.appendingPathComponent("\(ScratchStore.rootPrefix)current")

        XCTAssertTrue(
            ScratchStore.staleRoots(in: parent, excluding: current).isEmpty,
            "the prefix must match at the start of the name, not anywhere in it"
        )
    }

    /// A file that happens to carry the prefix is not a session root, and removing
    /// it would be deleting something we never created.
    @MainActor
    func testAFileCarryingThePrefixIsNotCollected() async throws {
        let file = parent.appendingPathComponent("\(ScratchStore.rootPrefix)notes.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let current = parent.appendingPathComponent("\(ScratchStore.rootPrefix)current")

        XCTAssertTrue(ScratchStore.staleRoots(in: parent, excluding: current).isEmpty)
    }

    /// End to end: a leftover root goes away, and the new session's does not.
    @MainActor
    func testPruneRemovesLeftoversButKeepsThisSession() async throws {
        let stale = try makeDirectory("\(ScratchStore.rootPrefix)from-a-crashed-run")
        try write("plaintext.txt", in: stale)

        let store = ScratchStore(parent: parent)
        let mine = try XCTUnwrap(store.makePreviewDirectory())
        store.pruneStaleRoots()

        XCTAssertFalse(exists(stale), "plaintext from a crashed run must not persist")
        XCTAssertTrue(exists(mine), "the running session's files must survive")
    }

    // MARK: - Helpers

    @MainActor
    private func makeExportFixture(
        behavior: ProvisionalExportEngine.Behavior
    ) throws -> (model: AppModel, engine: ProvisionalExportEngine, entry: XZip.ArchiveEntry) {
        let archive = parent.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        let scratchParent = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = ProvisionalExportEngine(behavior: behavior)
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: ScratchNoopEditor(),
            passwordStore: ScratchNoopPasswordStore(),
            presetStore: PresetStore(
                fileURL: parent.appendingPathComponent("presets-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        let model = AppModel(
            service: service,
            scratch: ScratchStore(parent: scratchParent)
        )
        let openArchive = OpenArchive(url: archive)
        model.openArchives = [openArchive]
        model.currentArchiveID = openArchive.id
        return (
            model,
            engine,
            XZip.ArchiveEntry(
                name: "secret.txt",
                path: "folder/secret.txt",
                kind: .document,
                originalSize: 9,
                compressedSize: 9,
                modifiedAt: Date()
            )
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in directory: URL) throws {
        try "plaintext".write(
            to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func contentsOfParent() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        )
    }
}

private actor ScratchExportTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class ProvisionalExportEngine: ArchiveEngine, @unchecked Sendable {
    enum Behavior { case fail, succeed, waitForCancellation }

    let supportedFormats: Set<ArchiveFormat> = [.zip]
    let started = XCTestExpectation(description: "provisional export started")
    private let behavior: Behavior
    private let lock = NSLock()
    private var recordedDestination: URL?
    private var retainedContinuation: AsyncThrowingStream<ArchiveProgress, Error>.Continuation?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var destination: URL? { lock.withLock { recordedDestination } }

    func finishPendingExport() {
        let continuation = lock.withLock { retainedContinuation }
        continuation?.finish(throwing: CancellationError())
    }

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
        lock.withLock { recordedDestination = destination }
        return AsyncThrowingStream { continuation in
            do {
                for entry in options.selectedEntries.isEmpty
                    ? ["secret.txt"]
                    : options.selectedEntries {
                    let output = destination.appendingPathComponent(entry)
                    try FileManager.default.createDirectory(
                        at: output.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("plaintext".utf8).write(to: output)
                }
                switch behavior {
                case .fail:
                    continuation.finish(throwing: CocoaError(.fileWriteUnknown))
                case .succeed:
                    continuation.finish()
                case .waitForCancellation:
                    lock.withLock { retainedContinuation = continuation }
                    continuation.yield(.indeterminate)
                    started.fulfill()
                }
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

private struct ScratchNoopPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}

private final class ScratchNoopEditor: ArchiveEditing, @unchecked Sendable {
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
    func delete(entries: [String], from archive: URL, password: String?) async throws {}
    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {}
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
