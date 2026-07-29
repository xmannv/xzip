import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime
@testable import XZip

private enum EngineExtractionBridgeError: Error {
    case unsupportedPolicy(ExistingFilePolicy)
}

actor ExtractionPreflightPasswordProbe {
    private var arrived = false
    private var password: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func record(_ password: String?) {
        arrived = true
        self.password = password
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: password)
        }
    }

    func wait() async -> String? {
        if arrived { return password }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class EngineExtractionBridge:
    ExtractionBridging,
    @unchecked Sendable
{
    private let engine: any ArchiveEngine
    private let preflightProbe: ExtractionPreflightPasswordProbe?

    init(
        engine: any ArchiveEngine,
        preflightProbe: ExtractionPreflightPasswordProbe? = nil
    ) {
        self.engine = engine
        self.preflightProbe = preflightProbe
    }

    func preflight(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> ExtractionPreflight {
        guard options.existingFilePolicy == .skip else {
            throw EngineExtractionBridgeError.unsupportedPolicy(
                options.existingFilePolicy
            )
        }
        await preflightProbe?.record(options.password)
        let locator = ArchiveLocator(
            archiveID: ArchiveID(identity: .stable(
                volumeIdentifier: 1,
                fileIdentifier: 2,
                generation: 1
            )),
            url: archive
        )
        return ExtractionPreflight(
            archive: locator,
            archiveRevision: ArchiveRevision(
                archiveID: locator.archiveID,
                fileSize: 4,
                contentModificationDate: Date(timeIntervalSince1970: 100),
                boundedContentFingerprint: Data([0xAA])
            ),
            destination: destination,
            destinationIdentity: ExtractionDestinationIdentity(
                parent: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 10,
                    generation: 1
                ),
                root: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 11,
                    generation: 1
                )
            ),
            selectedEntries: options.selectedEntries,
            conflictPolicy: .skip,
            preserveTimestamps: true,
            resourcePolicy: .production,
            planDigest: ExtractionPlanDigest(bytes: Data([0x03])),
            publicationBinding: [],
            conflicts: [],
            destructiveReplacementPaths: []
        )
    }

    func extract(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?
    ) -> AsyncThrowingStream<Double, Error> {
        let source = engine.extract(
            archive: preflight.archive.url,
            destination: preflight.destination,
            options: ExtractionOptions(
                password: password,
                selectedEntries: preflight.selectedEntries,
                existingFilePolicy: .skip
            )
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await progress in source {
                        if let fraction = progress.fraction {
                            continuation.yield(fraction)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// Wave 9D: the credential must not outlive the operation it belongs to.
///
/// `run` stores a closure that can re-run an operation, and that closure captures
/// the `ExtractionOptions` — password included. It is only dropped on success, so
/// a failed encrypted extraction would otherwise park the password in
/// `retryActions` for the rest of the session, which the security brief forbids.
///
/// These tests drive the **failure** path deliberately: a successful operation
/// clears `retryActions` anyway, so a success-based test would pass whether or
/// not the credential is handled correctly.
final class AppModelRetryCredentialTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: XZIPDefaults.conflictPolicy)
        super.tearDown()
    }

    @MainActor
    func testFailedPasswordProtectedExtractionStoresNoRetryClosure() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive)
        model.credentials.store("secret", for: archive)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        let id = try XCTUnwrap(model.operations.first?.id)
        XCTAssertEqual(
            model.operations.first?.state, .failed,
            "the fixture must actually fail, or this test proves nothing"
        )
        XCTAssertNil(
            model.retryActions[id],
            "a retry closure capturing the password must not outlive the operation"
        )
    }

    @MainActor
    func testPasswordFailureWithoutStoredCredentialTransfersRetryToPrompt() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive, failure: .wrongPassword)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        let id = try XCTUnwrap(model.operations.first?.id)
        XCTAssertEqual(model.operations.first?.state, .failed)
        XCTAssertNil(model.retryActions[id])
        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        XCTAssertEqual(model.passwordPromptValidationContexts, [.extraction])
    }


    @MainActor
    func testPasswordRequiredPromptHasNoErrorMessage() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive, failure: .passwordRequired)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertNil(model.passwordPromptErrorMessage)
        XCTAssertEqual(model.passwordPromptValidationContexts, [.extraction])
    }

    @MainActor
    func testPasswordlessNonPasswordFailureKeepsItsRetryClosure() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive, failure: .io)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        let id = try XCTUnwrap(model.operations.first?.id)
        XCTAssertEqual(model.operations.first?.state, .failed)
        XCTAssertNotNil(model.retryActions[id])
        XCTAssertNil(model.passwordPromptArchive)
    }

    // MARK: - Fixtures

    @MainActor
    func testRememberedExtractionPasswordIsSavedOnlyAfterSuccess() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()
        XCTAssertEqual(model.passwordPromptArchive, archive)

        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        XCTAssertEqual(store.saveCount, 0, "submit must not persist an unverified password")
        // The sheet stays up while the password is being checked; the model takes
        // it down itself once the backend accepts it.
        XCTAssertTrue(model.isVerifyingPassword)

        try await Self.settle()
        XCTAssertFalse(model.isVerifyingPassword)
        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertEqual(store.savedValue(for: model.vaultKey(for: archive)), "correct")
        XCTAssertEqual(store.saveCount, 1)
    }

    @MainActor
    func testRememberedListingPasswordIsSavedOnlyAfterSuccess() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.openArchive(archive)
        try await Self.settle()
        XCTAssertEqual(model.passwordPromptArchive, archive)

        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        XCTAssertEqual(store.saveCount, 0, "submit must not persist an unverified password")
        XCTAssertTrue(model.isVerifyingPassword)

        try await Self.settle()
        XCTAssertFalse(model.isVerifyingPassword)
        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertEqual(store.savedValue(for: model.vaultKey(for: archive)), "correct")
        XCTAssertEqual(store.saveCount, 1)
    }

    @MainActor
    func testWrongPasswordIsNeverSavedAndRememberIntentSurvivesReprompt() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        model.passwordPromptDidSubmit("wrong", saveToKeychain: true)
        XCTAssertEqual(store.saveCount, 0)

        try await Self.settle()
        XCTAssertEqual(store.saveCount, 0)
        // The rejection lands on the sheet the user is still looking at: same
        // archive, still presented, now carrying the error.
        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertFalse(model.isVerifyingPassword)
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        XCTAssertTrue(model.passwordPromptShouldRemember)

        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        // A fresh attempt must not keep showing the previous failure.
        XCTAssertNil(model.passwordPromptErrorMessage)
        try await Self.settle()
        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertEqual(store.savedValue(for: model.vaultKey(for: archive)), "correct")
        XCTAssertEqual(store.saveCount, 1)
    }


    @MainActor
    func testListingSuccessDoesNotConfirmExtractionPendingSave() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .passwordRequired
        )
        let presentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: presentationID)

        model.openArchive(archive)
        try await Self.settle()

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.savedValue(for: model.vaultKey(for: archive)))
    }

    @MainActor
    func testDifferentArchiveOrPasswordDoesNotConfirmPendingSave() async throws {
        let archive = try makeArchive()
        let otherArchive = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: otherArchive)
        }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .passwordRequired
        )
        let presentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidSubmit("candidate", saveToKeychain: true)
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: presentationID)

        model.credentials.store("correct", for: otherArchive)
        model.startExtraction(
            archive: otherArchive,
            destination: destination(for: otherArchive)
        )
        try await Self.settle()
        XCTAssertEqual(store.saveCount, 0)

        model.credentials.store("correct", for: archive)
        model.startExtraction(
            archive: archive,
            destination: destination(for: archive)
        )
        try await Self.settle()
        XCTAssertEqual(store.saveCount, 0)
    }

    @MainActor
    func testCancelClearsPendingRememberedPassword() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        model.passwordPromptDidSubmit("wrong", saveToKeychain: true)
        try await Self.settle()

        XCTAssertTrue(model.passwordPromptShouldRemember)
        let presentationID = try XCTUnwrap(model.passwordPromptPresentationID)
        model.passwordPromptDidCancel()
        model.isPasswordPromptPresented = false
        model.passwordPromptDidDismiss(presentationID: presentationID)

        model.credentials.store("correct", for: archive)
        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.savedValue(for: model.vaultKey(for: archive)))
    }

    @MainActor
    func testGenericFailureDoesNotPersistPendingPassword() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makeModel(
            archive: archive,
            failure: .io,
            passwordStore: store
        )
        let output = destination(for: archive)

        model.presentPasswordPrompt(
            for: archive,
            validationContext: .extraction,
            error: .passwordRequired
        ) {
            model.startExtraction(
                archive: archive,
                destination: output
            )
        }
        model.passwordPromptDidSubmit("candidate", saveToKeychain: true)
        try await Self.settle()

        XCTAssertEqual(model.operations.first?.state, .failed)
        XCTAssertEqual(store.saveCount, 0)
        // A non-password failure rules on nothing, but must still release the
        // sheet rather than leave it waiting on a verdict that never comes.
        XCTAssertFalse(model.isVerifyingPassword)
    }

    @MainActor
    func testWrongSavedPasswordIsDeletedForMatchingArchive() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")
        let key = model.vaultKey(for: archive)
        store.seed("stale", for: key)
        let baselineAllKeysCallCount = store.allKeysCallCount

        model.openArchive(archive)
        try await Self.settle()

        XCTAssertNil(store.savedValue(for: key))
        XCTAssertEqual(store.deletedKeys, [key])
        XCTAssertEqual(
            store.allKeysCallCount,
            baselineAllKeysCallCount,
            "invalidating one rejected credential must not enumerate other accounts"
        )
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
    }

    @MainActor
    func testKeychainSaveFailureKeepsPendingPasswordForLaterSuccess() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingPasswordStore()
        let model = makePasswordGateModel(store: store, correctPassword: "correct")

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()
        store.failNextSave()

        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        try await Self.settle()

        XCTAssertEqual(model.errorMessage, CocoaError(.fileWriteUnknown).localizedDescription)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.savedValue(for: model.vaultKey(for: archive)))

        model.credentials.store("correct", for: archive)
        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        XCTAssertEqual(store.savedValue(for: model.vaultKey(for: archive)), "correct")
        XCTAssertEqual(store.saveCount, 1)
    }

    /// A password the backend rejected must not stay in the session store.
    ///
    /// The lease released on the terminal path only discards the credential for
    /// an archive that was never opened (`discardWhenUnused: !isOpen`), so for an
    /// OPEN archive a wrong password used to survive the failure. Cancelling the
    /// prompt then left it armed, and the next operation reused a credential
    /// already proven wrong.
    @MainActor
    func testWrongPasswordIsDiscardedFromTheSessionStoreForAnOpenArchive() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive)
        // Open it, so the lease release deliberately does NOT clean up.
        let open = OpenArchive(url: archive)
        model.openArchives = [open]
        model.currentArchiveID = open.id
        model.credentials.store("wrong", for: archive)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        XCTAssertNil(
            model.credential(for: archive),
            "a password the engine rejected must not remain available"
        )
        // The prompt still comes up, so the user can supply the right one.
        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
    }

    /// A replacement password submitted before the failure lands must survive.
    ///
    /// The discard is conditional on still holding the rejected value, which is
    /// what keeps a late-arriving failure from wiping a newer credential.
    @MainActor
    func testWrongPasswordDiscardDoesNotRemoveANewerCredential() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let preflightProbe = ExtractionPreflightPasswordProbe()
        let model = makeModel(
            archive: archive,
            preflightProbe: preflightProbe
        )
        let open = OpenArchive(url: archive)
        model.openArchives = [open]
        model.currentArchiveID = open.id
        model.credentials.store("wrong", for: archive)

        model.startExtraction(archive: archive, destination: destination(for: archive))
        let leasedPassword = await preflightProbe.wait()
        XCTAssertEqual(leasedPassword, "wrong")
        // Replace the credential only after the operation has leased the old
        // generation, so the assertion verifies generation-aware discard.
        model.credentials.store("newer", for: archive)
        try await Self.settle()

        XCTAssertEqual(
            model.credential(for: archive),
            "newer",
            "the failure must not discard a credential it never tried"
        )
    }

    /// The point of the verification gate: a rejected password reports on the
    /// archive the user is looking at.
    ///
    /// Previously the sheet closed on submit, so the NEXT queued archive's prompt
    /// appeared before the backend reported the failure. The rejected archive was
    /// pushed to the tail of the queue, and the user met an unrelated prompt with
    /// no error shown, then saw "Incorrect password" much later.
    @MainActor
    func testWrongPasswordReportsOnItsOwnSheetInsteadOfAdvancingTheQueue() async throws {
        let first = try makeArchive()
        let second = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = makePasswordGateModel(
            store: RecordingPasswordStore(),
            correctPassword: "correct"
        )

        // Started one at a time on purpose. Under a non-`.ask` policy the two
        // extractions would run concurrently, and the sheet goes to whichever
        // task reaches `presentPasswordPrompt` first — the queue is FIFO by
        // arrival there, not by `startExtraction` call order. Waiting for the
        // first sheet pins which archive is on screen so the assertions below
        // are about the verification gate rather than that race.
        model.startExtraction(archive: first, destination: destination(for: first))
        try await Self.settle()
        XCTAssertEqual(model.passwordPromptArchive, first)

        // Queued behind the presented sheet.
        model.startExtraction(archive: second, destination: destination(for: second))
        try await Self.settle()
        XCTAssertEqual(
            model.passwordPromptArchive,
            first,
            "a newly queued archive must not steal the presented sheet"
        )

        model.passwordPromptDidSubmit("wrong")
        try await Self.settle()

        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(
            model.passwordPromptArchive,
            first,
            "the rejection must land on the archive that was submitted, not the next in the queue"
        )
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        XCTAssertFalse(model.isVerifyingPassword)

        // Correcting it releases the sheet and lets the queue move on.
        model.passwordPromptDidSubmit("correct")
        try await Self.settle()
        XCTAssertEqual(model.passwordPromptArchive, second)
    }

    /// The queue is held only for the verification, not the whole extraction.
    ///
    /// The verdict comes from the backend's first progress report, so a long
    /// extraction does not keep the next archive's prompt waiting.
    @MainActor
    func testAcceptedPasswordReleasesTheSheetBeforeExtractionFinishes() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makePasswordGateModel(
            store: RecordingPasswordStore(),
            correctPassword: "correct"
        )

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()
        XCTAssertEqual(model.passwordPromptArchive, archive)

        model.passwordPromptDidSubmit("correct")
        try await Self.settle()

        XCTAssertFalse(model.isVerifyingPassword)
        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertNil(model.passwordPromptArchive)
    }

    /// Cancelling while a password is being checked must not trap the user.
    @MainActor
    func testCancellingDuringVerificationReleasesTheGate() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makePasswordGateModel(
            store: RecordingPasswordStore(),
            correctPassword: "correct"
        )

        model.startExtraction(archive: archive, destination: destination(for: archive))
        try await Self.settle()

        model.passwordPromptDidSubmit("wrong")
        XCTAssertTrue(model.isVerifyingPassword)
        model.passwordPromptDidCancel()

        XCTAssertFalse(model.isVerifyingPassword)
        XCTAssertNil(model.passwordPromptArchive)
    }

    @MainActor
    private func makeModel(
        archive: URL,
        failure: FailingExtractionEngine.Failure = .wrongPassword,
        passwordStore: any PasswordStoring = NoopPasswordStore(),
        preflightProbe: ExtractionPreflightPasswordProbe? = nil
    ) -> AppModel {
        UserDefaults.standard.set(
            ConflictPolicy.skip.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        let engine = FailingExtractionEngine(failure: failure)
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: NoopEditor(),
            passwordStore: passwordStore,
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("retry-credential-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        let bridge = EngineExtractionBridge(
            engine: engine,
            preflightProbe: preflightProbe
        )
        let stagingVolume = ExtractionRouter.volumeIdentifier(
            of: FileManager.default.temporaryDirectory
        )
        let router = ExtractionRouter(
            makeBridge: { bridge },
            resolveStagingVolume: { stagingVolume }
        )
        return AppModel(service: service, extractionRouter: router)
    }

    @MainActor
    private func makePasswordGateModel(
        store: RecordingPasswordStore,
        correctPassword: String
    ) -> AppModel {
        UserDefaults.standard.set(
            ConflictPolicy.skip.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        let engine = PasswordGateEngine(correctPassword: correctPassword)
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: NoopEditor(),
            passwordStore: store,
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "password-gate-\(UUID().uuidString).json"
                    )
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

    /// A real zip header, so `detectedFormat` identifies the archive and the
    /// service resolves an engine rather than failing for an unrelated reason.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-credential-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        return archive
    }

    private func destination(for archive: URL) -> URL {
        archive.deletingLastPathComponent()
            .appendingPathComponent("out-\(UUID().uuidString)")
    }

    /// The operation runs on a detached task and reports back through the main
    /// actor, so give it room to reach its terminal state.
    ///
    /// Static so awaiting it from a `@MainActor` test does not send `self`
    /// across an isolation boundary.
    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

private final class RecordingPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var saves: [(key: String, password: String)] = []
    private var deletes: [String] = []
    private var allKeysReads = 0
    private var shouldFailNextSave = false

    func save(password: String, for key: String) throws {
        try lock.withLock {
            if shouldFailNextSave {
                shouldFailNextSave = false
                throw CocoaError(.fileWriteUnknown)
            }
            values[key] = password
            saves.append((key, password))
        }
    }

    func password(for key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    func delete(for key: String) throws {
        lock.withLock {
            values[key] = nil
            deletes.append(key)
        }
    }

    func allKeys() throws -> [String] {
        lock.withLock {
            allKeysReads += 1
            return Array(values.keys)
        }
    }

    func seed(_ password: String, for key: String) {
        lock.withLock { values[key] = password }
    }

    func failNextSave() {
        lock.withLock { shouldFailNextSave = true }
    }

    func savedValue(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    var saveCount: Int { lock.withLock { saves.count } }
    var deletedKeys: [String] { lock.withLock { deletes } }
    var allKeysCallCount: Int { lock.withLock { allKeysReads } }
}

private final class PasswordGateEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]
    private let correctPassword: String

    init(correctPassword: String) {
        self.correctPassword = correctPassword
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
        AsyncThrowingStream { continuation in
            do {
                try validate(options.password)
                continuation.yield(ArchiveProgress(fraction: 1))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func list(
        archive: URL,
        password: String?
    ) async throws -> [XZIPCore.ArchiveEntry] {
        try validate(password)
        return []
    }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        try validate(password)
        return ArchiveListingResult(entries: [], truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        try validate(password)
        return true
    }

    private func validate(_ password: String?) throws {
        guard let password else {
            throw ArchiveEngineError.passwordRequired
        }
        guard password == correctPassword else {
            throw ArchiveEngineError.wrongPassword
        }
    }
}

private final class FailingExtractionEngine: ArchiveEngine, @unchecked Sendable {
    enum Failure { case passwordRequired, wrongPassword, io }

    let supportedFormats: Set<ArchiveFormat> = [.zip]
    private let failure: Failure

    init(failure: Failure) { self.failure = failure }

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
        AsyncThrowingStream { continuation in
            switch failure {
            case .passwordRequired:
                continuation.finish(throwing: ArchiveEngineError.passwordRequired)
            case .wrongPassword:
                continuation.finish(throwing: ArchiveEngineError.wrongPassword)
            case .io:
                continuation.finish(throwing: CocoaError(.fileWriteUnknown))
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

private final class NoopEditor: ArchiveEditing, @unchecked Sendable {
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

private struct NoopPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
