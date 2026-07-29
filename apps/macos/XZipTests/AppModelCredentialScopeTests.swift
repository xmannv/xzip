import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime
@testable import XZip

/// Wave 9E: a credential must belong to ONE archive.
///
/// `openArchive` clears the shared password when the URL differs, so switching
/// archives in the sidebar does not leak. The hole is the path that never calls
/// `openArchive` at all: `extractItem`, behind the folder browser's "Extract
/// Here" / "Extract…" context menu, extracts an archive out of the browsed
/// folder without opening it. That extraction read the same shared field and
/// therefore received whatever credential the viewed archive happened to hold.
/// (`extractFromFinder` does call `openArchive` first, so it was never the
/// leaking path.)
final class AppModelCredentialScopeTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: XZIPDefaults.conflictPolicy)
        super.tearDown()
    }

    @MainActor
    func testExtractingAnotherArchiveDoesNotReuseTheViewedArchivesPassword() async throws {
        let viewed = try makeArchive()
        let other = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: viewed)
            try? FileManager.default.removeItem(at: other)
        }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)
        // On screen: `viewed`, unlocked with its own password.
        let open = OpenArchive(url: viewed)
        model.openArchives = [open]
        model.currentArchiveID = open.id
        model.credentials.store("secret-for-viewed", for: viewed)

        // Extract a DIFFERENT archive, as a Finder Quick Action does.
        model.startExtraction(archive: other, destination: destination())
        try await Self.settle()

        // Assert the extraction happened first: without this, a nil password
        // would also "pass" when nothing ran at all.
        XCTAssertTrue(engine.wasExtracted(other), "the extraction must actually have run")
        XCTAssertEqual(
            engine.password(for: other), nil,
            "an archive with no credential of its own must not inherit another archive's"
        )
    }


    @MainActor
    func testFinderPasswordRetryExtractsCapturedArchiveAfterSelectionChanges() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)

        model.extractFromFinder(
            paths: [first.path],
            destination: .here,
            withPassword: true
        )
        XCTAssertEqual(model.passwordPromptArchive, first)

        model.openArchive(second)
        model.passwordPromptDidSubmit("first-secret")
        try await Self.settle()

        XCTAssertTrue(engine.wasExtracted(first))
        XCTAssertEqual(engine.password(for: first), "first-secret")
        XCTAssertFalse(
            engine.wasExtracted(second),
            "the retry must not follow a later current-archive selection"
        )
    }

    @MainActor
    func testFinderPasswordPromptRequiresExtractionValidation() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(engine: RecordingEngine())

        model.extractFromFinder(
            paths: [archive.path],
            destination: .here,
            withPassword: true
        )

        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertEqual(model.passwordPromptValidationContexts, [.extraction])
    }

    /// Same guarantee as above, but driven through the entry point that actually
    /// leaked: the folder browser's "Extract Here" / "Extract…" context menu.
    /// The test above calls `startExtraction` directly, so on its own it would
    /// not prove the real path is safe.
    @MainActor
    func testExtractingFromTheFolderBrowserDoesNotReuseTheViewedArchivesPassword() async throws {
        let viewed = try makeArchive()
        let browsed = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: viewed)
            try? FileManager.default.removeItem(at: browsed)
        }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)
        let open = OpenArchive(url: viewed)
        model.openArchives = [open]
        model.currentArchiveID = open.id
        model.credentials.store("secret-for-viewed", for: viewed)

        // `extractItem` never calls openArchive, so nothing clears a shared field.
        model.extractItem(
            FileItem(url: browsed, isDirectory: false, sizeBytes: 4, modifiedAt: Date()),
            to: destination()
        )
        try await Self.settle()

        XCTAssertTrue(engine.wasExtracted(browsed), "the extraction must actually have run")
        XCTAssertEqual(
            engine.password(for: browsed), nil,
            "an archive extracted from the folder browser must not inherit the viewed archive's password"
        )
    }

    @MainActor
    func testEachArchiveReceivesItsOwnPassword() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)
        model.credentials.store("first-pass", for: first)
        model.credentials.store("second-pass", for: second)

        model.startExtraction(archive: first, destination: destination())
        try await Self.settle()
        model.startExtraction(archive: second, destination: destination())
        try await Self.settle()

        XCTAssertEqual(engine.password(for: first), "first-pass")
        XCTAssertEqual(engine.password(for: second), "second-pass")
    }

    @MainActor
    func testCompressionDraftIsNotUsedAsAnArchiveCredential() async throws {
        // The compress sheet and the password prompt used to write to the same
        // field, so a password typed to CREATE an archive became the credential
        // used to READ the open one.
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)
        model.compressionPassword = "for-a-new-archive"

        model.startExtraction(archive: archive, destination: destination())
        try await Self.settle()

        XCTAssertTrue(engine.wasExtracted(archive), "the extraction must actually have run")
        XCTAssertEqual(
            engine.password(for: archive), nil,
            "a compression draft must never be sent as an extraction credential"
        )
    }

    @MainActor
    func testClosingAnArchiveDiscardsOnlyItsOwnCredential() throws {
        let closing = try makeArchive()
        let staying = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: closing)
            try? FileManager.default.removeItem(at: staying)
        }

        let model = makeModel(engine: RecordingEngine())
        let closingArchive = OpenArchive(url: closing)
        let stayingArchive = OpenArchive(url: staying)
        model.openArchives = [closingArchive, stayingArchive]
        model.currentArchiveID = closingArchive.id
        model.credentials.store("a", for: closing)
        model.credentials.store("b", for: staying)

        model.closeArchive(closingArchive.id)

        XCTAssertNil(
            model.credentials.credential(for: closing),
            "a closed archive's credential must not outlive it"
        )
        XCTAssertEqual(
            model.credentials.credential(for: staying), "b",
            "closing one archive must not disturb another's credential"
        )
    }

    @MainActor
    func testAnOpenPasswordPromptCannotBeRetargetedByAnotherArchive() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let model = makeModel(engine: RecordingEngine())
        var firstRetryRan = false
        var secondRetryRan = false

        model.presentPasswordPrompt(for: first) { firstRetryRan = true }
        model.presentPasswordPrompt(for: second) { secondRetryRan = true }

        XCTAssertEqual(
            model.passwordPromptArchive, first,
            "a second failure must not retarget a sheet where the user may already be typing"
        )
        let firstPresentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidSubmit("first-secret")
        XCTAssertTrue(firstRetryRan)
        XCTAssertFalse(secondRetryRan)
        XCTAssertEqual(model.credentials.credential(for: first), "first-secret")
        XCTAssertNil(model.credentials.credential(for: second))

        model.passwordPromptDidDismiss(presentationID: firstPresentationID)
        try await Self.waitUntil { model.passwordPromptArchive == second }
        XCTAssertEqual(
            model.passwordPromptArchive, second,
            "the deferred failure must be presented after the first sheet closes"
        )
        model.passwordPromptDidSubmit("second-secret")
        XCTAssertTrue(secondRetryRan)
        XCTAssertEqual(model.credentials.credential(for: second), "second-secret")
    }

    @MainActor
    func testDuplicatePasswordFailureForSameArchiveIsCoalesced() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(engine: RecordingEngine())

        model.presentPasswordPrompt(for: archive) {}
        model.presentPasswordPrompt(for: archive) {}
        let presentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidSubmit("secret")
        model.passwordPromptDidDismiss(presentationID: presentationID)

        XCTAssertNil(
            model.passwordPromptArchive,
            "the same unresolved archive must not create a duplicate queued prompt"
        )
        XCTAssertFalse(model.isPasswordPromptPresented)
    }


    @MainActor
    func testDuplicatePasswordPromptsUnionValidationContexts() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(engine: RecordingEngine())

        model.presentPasswordPrompt(
            for: archive,
            validationContext: .listing,
            error: .passwordRequired
        ) {}
        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .wrongPassword
        ) {}

        XCTAssertEqual(
            model.passwordPromptValidationContexts,
            [.listing, .extraction]
        )
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
    }

    @MainActor
    func testDuplicatePasswordFailuresFanOutAllRetries() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(engine: RecordingEngine())
        var retryCount = 0

        model.presentPasswordPrompt(for: archive) { retryCount += 1 }
        model.presentPasswordPrompt(for: archive) { retryCount += 1 }
        model.passwordPromptDidSubmit("secret")

        XCTAssertEqual(retryCount, 2)
    }


    @MainActor
    func testPasswordPromptErrorDoesNotLeakToDeferredArchive() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makeModel(engine: RecordingEngine())

        model.presentPasswordPrompt(
            for: first,
            validationContext: .extraction,
            error: .wrongPassword
        ) {}
        model.presentPasswordPrompt(
            for: second,
            validationContext: .listing,
            error: .passwordRequired
        ) {}

        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        let firstID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidCancel()
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: firstID)
        try await Self.waitUntil { model.passwordPromptArchive == second }

        XCTAssertNil(model.passwordPromptErrorMessage)
        XCTAssertEqual(model.passwordPromptValidationContexts, [.listing])
    }

    @MainActor
    func testPromptArrivingDuringDismissTransitionPreservesFIFO() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        let third = try makeArchive()
        defer {
            for archive in [first, second, third] { try? FileManager.default.removeItem(at: archive) }
        }
        let model = makeModel(engine: RecordingEngine())
        model.presentPasswordPrompt(for: first) {}
        model.presentPasswordPrompt(for: second) {}

        let firstPresentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidCancel()
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: firstPresentationID)
        model.presentPasswordPrompt(for: third) {}

        try await Self.waitUntil { model.passwordPromptArchive != nil }
        XCTAssertEqual(model.passwordPromptArchive, second)
    }


    @MainActor
    func testScheduledPasswordPromptRetainsMergedState() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makeModel(engine: RecordingEngine())
        var retryCount = 0
        model.presentPasswordPrompt(for: first) {}
        model.presentPasswordPrompt(
            for: second,
            validationContext: .listing,
            error: .passwordRequired
        ) { retryCount += 1 }

        let firstPresentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidCancel()
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: firstPresentationID)
        model.presentPasswordPrompt(
            for: second,
            validationContext: .extraction,
            error: .wrongPassword
        ) { retryCount += 1 }

        try await Self.waitUntil { model.passwordPromptArchive == second }
        XCTAssertEqual(model.passwordPromptValidationContexts, [.listing, .extraction])
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        model.passwordPromptDidSubmit("secret")
        XCTAssertEqual(retryCount, 2)
    }

    @MainActor
    func testClosingArchivePurgesItsActiveAndDeferredPrompts() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makeModel(engine: RecordingEngine())
        model.openArchive(first)
        let firstID = try XCTUnwrap(model.currentArchive?.id)
        model.presentPasswordPrompt(for: first) {}
        model.presentPasswordPrompt(for: second) {}

        let firstPresentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidAppear(presentationID: firstPresentationID)
        model.closeArchive(firstID)
        // A new failure arrives after purge lowered the sheet but before SwiftUI
        // delivers the old sheet's callback. It must queue, not activate early.
        var lateRetryCount = 0
        model.presentPasswordPrompt(for: second) { lateRetryCount += 1 }
        XCTAssertNil(model.passwordPromptArchive)

        model.passwordPromptDidDismiss(presentationID: firstPresentationID)
        try await Self.waitUntil { model.passwordPromptArchive == second }
        XCTAssertTrue(model.isPasswordPromptPresented)

        model.passwordPromptDidDismiss(presentationID: firstPresentationID)
        XCTAssertEqual(model.passwordPromptArchive, second)
        XCTAssertTrue(model.isPasswordPromptPresented)

        model.passwordPromptDidSubmit("secret")
        XCTAssertEqual(lateRetryCount, 1)
    }

    @MainActor
    func testClosingBeforePromptAppearsAdvancesWithoutDismissCallback() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makeModel(engine: RecordingEngine())
        model.openArchive(first)
        let firstID = try XCTUnwrap(model.currentArchive?.id)
        model.presentPasswordPrompt(for: first) {}
        model.presentPasswordPrompt(for: second) {}

        // No passwordPromptDidAppear: SwiftUI coalesced true→false before mounting.
        model.closeArchive(firstID)

        try await Self.waitUntil { model.passwordPromptArchive == second }
        XCTAssertTrue(model.isPasswordPromptPresented)
    }

    @MainActor
    func testOpeningAnotherArchiveDoesNotDestroyActivePromptRetry() throws {
        let prompted = try makeArchive()
        let opened = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: prompted)
            try? FileManager.default.removeItem(at: opened)
        }
        let model = makeModel(engine: RecordingEngine())
        var retryRan = false
        model.presentPasswordPrompt(for: prompted) { retryRan = true }

        model.openArchive(opened)
        model.passwordPromptDidSubmit("secret")

        XCTAssertTrue(retryRan)
        XCTAssertEqual(model.credentials.credential(for: prompted), "secret")
    }

    @MainActor
    func testDismissingPasswordPromptClearsItsTargetAndPendingRetry() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let model = makeModel(engine: RecordingEngine())
        var retryRan = false
        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .wrongPassword
        ) { retryRan = true }

        model.passwordPromptDidCancel()

        XCTAssertNil(model.passwordPromptArchive)
        XCTAssertNil(model.pendingExtractionRetry)
        XCTAssertNil(model.passwordPromptErrorMessage)
        XCTAssertTrue(model.passwordPromptValidationContexts.isEmpty)
        XCTAssertFalse(retryRan)
    }


    @MainActor
    func testPasswordPromptSubmitClearsStaleErrorButKeepsContextsWhileVerifying() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(engine: RecordingEngine())

        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .wrongPassword
        ) {}
        model.passwordPromptDidSubmit("secret")

        // The previous attempt's error must go: showing "Incorrect password"
        // while the new one is still being checked would be a lie.
        XCTAssertNil(model.passwordPromptErrorMessage)
        // The prompt is still live (awaiting a verdict), so its target and the
        // contexts that gate the Keychain save have to survive the submission.
        XCTAssertTrue(model.isVerifyingPassword)
        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertEqual(model.passwordPromptValidationContexts, [.extraction])
    }

    @MainActor
    func testSuccessfulExtractionOfNeverOpenedArchiveDiscardsItsCredential() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let model = makeModel(engine: engine)
        model.credentials.store("one-shot", for: archive)
        XCTAssertFalse(model.openArchives.contains(where: { $0.url == archive }))

        model.extractItem(
            FileItem(url: archive, isDirectory: false, sizeBytes: 4, modifiedAt: Date()),
            to: destination()
        )
        try await Self.settle()

        XCTAssertTrue(engine.wasExtracted(archive), "the extraction must actually have run")
        XCTAssertNil(
            model.credentials.credential(for: archive),
            "a credential for an archive that was never opened needs a success boundary"
        )
    }

    @MainActor
    func testOldLeaseCannotDiscardNewCredentialGeneration() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let credentials = ArchiveCredentials()
        credentials.store("old", for: archive)
        let lease = try XCTUnwrap(credentials.acquire(for: archive))

        credentials.store("new", for: archive)
        credentials.release(lease, discardWhenUnused: true)

        XCTAssertEqual(credentials.credential(for: archive), "new")
    }

    @MainActor
    func testCredentialWaitsForFinalLeaseBeforeDiscard() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let credentials = ArchiveCredentials()
        credentials.store("secret", for: archive)
        let first = try XCTUnwrap(credentials.acquire(for: archive))
        let second = try XCTUnwrap(credentials.acquire(for: archive))

        credentials.release(first, discardWhenUnused: true)
        XCTAssertEqual(credentials.credential(for: archive), "secret")
        credentials.release(second, discardWhenUnused: false)

        XCTAssertNil(credentials.credential(for: archive))
    }

    // MARK: - Fixtures

    @MainActor
    private func makeModel(engine: RecordingEngine) -> AppModel {
        UserDefaults.standard.set(
            ConflictPolicy.skip.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: CredentialScopeNoopEditor(),
            passwordStore: EmptyPasswordStore(),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("credential-scope-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        let bridge = EngineExtractionBridge(engine: engine)
        let stagingVolume = ExtractionRouter.volumeIdentifier(
            of: FileManager.default.temporaryDirectory
        )
        let router = ExtractionRouter(
            makeBridge: { bridge },
            resolveStagingVolume: { stagingVolume }
        )
        return AppModel(service: service, extractionRouter: router)
    }

    /// A real zip signature so `detectedFormat` resolves an engine.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-scope-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        return archive
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-scope-out-\(UUID().uuidString)")
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// Records the credential each archive was extracted with.
private final class RecordingEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]

    private let lock = NSLock()
    private var seen: [URL: String?] = [:]

    /// `nil` when the archive was extracted without a credential; the recorded
    /// value otherwise. Distinguishing "not called" from "called with nil" is
    /// deliberate: a test asserting nil must not pass merely because extraction
    /// never happened.
    func password(for archive: URL) -> String? {
        lock.withLock { seen[archive] ?? nil }
    }

    func wasExtracted(_ archive: URL) -> Bool {
        lock.withLock { seen.keys.contains(archive) }
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
        lock.withLock { seen[archive] = options.password }
        return AsyncThrowingStream { $0.finish() }
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

private final class CredentialScopeNoopEditor: ArchiveEditing, @unchecked Sendable {
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

private struct EmptyPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
