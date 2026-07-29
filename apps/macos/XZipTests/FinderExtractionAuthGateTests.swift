import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime
@testable import XZip

/// A `xzip://` extract command can make the app spend a password kept in the
/// Keychain vault: the caller cannot read that password, but it can read the
/// plaintext files the extraction writes. Any local process can open such a URL
/// and cannot be authenticated (the app is unsandboxed and the caller runs as the
/// same user), so `extractFromFinder` authenticates the *user* before spending a
/// remembered credential.
///
/// These tests pin both halves of that rule: the gate holds when it should, and —
/// just as important — it stays out of the way for the ordinary Finder case, which
/// is what makes the trade-off acceptable.
final class FinderExtractionAuthGateTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: XZIPDefaults.conflictPolicy)
        super.tearDown()
    }

    // MARK: - The gate holds

    @MainActor
    func testDecliningAuthenticationDoesNotExtractAnArchiveWithASavedPassword() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let auth = AuthSpy(verdict: false)
        let model = makeModel(engine: engine, auth: auth, saved: [archive: "vault-secret"])

        model.extractFromFinder(paths: [archive.path], destination: .downloads, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 1, "spending a saved password must ask the user")
        XCTAssertFalse(
            engine.wasExtracted(archive),
            "a declined authentication must not extract, or the caller gets the plaintext anyway"
        )
    }

    @MainActor
    func testApprovingAuthenticationExtractsUsingTheSavedPassword() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let auth = AuthSpy(verdict: true)
        let model = makeModel(engine: engine, auth: auth, saved: [archive: "vault-secret"])

        model.extractFromFinder(paths: [archive.path], destination: .downloads, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 1)
        // Asserting the extraction ran AND which credential it used: a gate that
        // silently dropped the password would otherwise look like a pass here.
        XCTAssertTrue(engine.wasExtracted(archive), "an approved authentication must still extract")
        XCTAssertEqual(engine.password(for: archive), "vault-secret")
    }

    @MainActor
    func testDeclinedAuthenticationIsReportedRatherThanFailingSilently() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let model = makeModel(
            engine: RecordingEngine(),
            auth: AuthSpy(verdict: false),
            saved: [archive: "vault-secret"]
        )

        model.extractFromFinder(paths: [archive.path], destination: .here, withPassword: false)
        try await Self.settle()

        // A Finder command that does nothing and says nothing reads as a bug.
        XCTAssertNotNil(model.infoMessage)
        XCTAssertNil(model.errorMessage, "declining is a choice, not a failure")
    }

    /// The `withPassword` branch looks like it already involves the user, but it
    /// reaches `openArchive` first, where a remembered password can satisfy the
    /// listing before the prompt is ever answered. So it is gated too.
    @MainActor
    func testThePasswordPromptBranchIsGatedAsWell() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let auth = AuthSpy(verdict: false)
        let model = makeModel(
            engine: RecordingEngine(),
            auth: auth,
            saved: [archive: "vault-secret"]
        )

        model.extractFromFinder(paths: [archive.path], destination: .here, withPassword: true)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 1)
        XCTAssertNil(
            model.passwordPromptArchive,
            "a declined authentication must not even reach the password prompt"
        )
    }

    /// Opening without extracting (`destination: nil`) still lists the archive,
    /// which is itself a use of the saved password.
    @MainActor
    func testOpenOnlyCommandIsGatedToo() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let auth = AuthSpy(verdict: false)
        let model = makeModel(
            engine: RecordingEngine(),
            auth: auth,
            saved: [archive: "vault-secret"]
        )

        model.extractFromFinder(paths: [archive.path], destination: nil, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 1)
        XCTAssertTrue(
            model.openArchives.isEmpty,
            "a declined authentication must not list the archive either"
        )
    }

    // MARK: - The gate stays out of the way

    @MainActor
    func testAnArchiveWithNoSavedPasswordIsExtractedWithoutAuthenticating() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        // Verdict false on purpose: if the gate wrongly engaged, the extraction
        // would be blocked and the assertion below would catch it.
        let auth = AuthSpy(verdict: false)
        let model = makeModel(engine: engine, auth: auth, saved: [:])

        model.extractFromFinder(paths: [archive.path], destination: .downloads, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(
            auth.callCount, 0,
            "the ordinary Finder case (nothing saved) must not prompt for authentication"
        )
        XCTAssertTrue(engine.wasExtracted(archive))
    }

    /// A credential that appears after the external request was accepted must not
    /// be picked up by that already-unauthenticated request. Otherwise another app
    /// can race a legitimate password prompt and spend its credential generation.
    @MainActor
    func testCredentialAddedAfterExternalRequestIsNotSpentWithoutAuthentication() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let auth = AuthSpy(verdict: false)
        let model = makeModel(engine: engine, auth: auth, saved: [:])

        model.extractFromFinder(paths: [archive.path], destination: .downloads, withPassword: false)
        model.credentials.store("late-secret", for: archive)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 0, "no credential existed when the request was accepted")
        XCTAssertTrue(engine.wasExtracted(archive))
        XCTAssertNil(
            engine.password(for: archive),
            "an unauthenticated external request must not acquire a later credential generation"
        )
    }

    /// A session credential still decrypts data on behalf of an unauthenticated
    /// external caller. Knowing that the user typed it earlier does not prove the
    /// user authorized THIS extraction, so every external use asks again.
    @MainActor
    func testASessionCredentialStillRequiresAuthenticationForEveryExternalExtract() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        let engine = RecordingEngine()
        let auth = AuthSpy(verdict: false)
        let model = makeModel(engine: engine, auth: auth, saved: [archive: "vault-secret"])
        model.credentials.store("typed-by-user", for: archive)

        model.extractFromFinder(paths: [archive.path], destination: .downloads, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 1, "every external extraction must ask the user")
        XCTAssertFalse(
            engine.wasExtracted(archive),
            "a session credential must not let an external caller bypass a declined authentication"
        )
    }

    /// Guards against gating by "is there anything in the vault at all": a saved
    /// password for a DIFFERENT archive must not make this one prompt.
    @MainActor
    func testASavedPasswordForAnotherArchiveDoesNotTriggerAuthentication() async throws {
        let target = try makeArchive()
        let unrelated = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: unrelated)
        }

        let engine = RecordingEngine()
        let auth = AuthSpy(verdict: false)
        let model = makeModel(engine: engine, auth: auth, saved: [unrelated: "other-secret"])

        model.extractFromFinder(paths: [target.path], destination: .downloads, withPassword: false)
        try await Self.settle()

        XCTAssertEqual(auth.callCount, 0)
        XCTAssertTrue(engine.wasExtracted(target))
        XCTAssertNil(engine.password(for: target), "and it must not borrow that password either")
    }

    // MARK: - Fixtures

    @MainActor
    private func makeModel(
        engine: RecordingEngine,
        auth: AuthSpy,
        saved: [URL: String]
    ) -> AppModel {
        // Conflict semantics are irrelevant here. Use the non-destructive policy
        // supported by the transactional test bridge so the real credential path runs.
        UserDefaults.standard.set(
            ConflictPolicy.skip.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        var byKey: [String: String] = [:]
        for (url, password) in saved {
            byKey[url.standardizedFileURL.path] = password
        }
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: AuthGateNoopEditor(),
            passwordStore: StubPasswordStore(passwords: byKey),
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("auth-gate-\(UUID().uuidString).json")
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
        let model = AppModel(service: service, extractionRouter: router)
        model.authenticator = { reason in auth.evaluate(reason) }
        return model
    }

    /// A real zip signature so `detectedFormat` resolves an engine.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-gate-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        return archive
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// Records how many times the app asked the user to authenticate, and answers
/// with a fixed verdict. Stands in for `AuthService`, which cannot evaluate an
/// `LAContext` policy in a unit-test host.
@MainActor
private final class AuthSpy {
    private let verdict: Bool
    private(set) var callCount = 0
    private(set) var lastReason: String?

    init(verdict: Bool) {
        self.verdict = verdict
    }

    func evaluate(_ reason: String) -> Bool {
        callCount += 1
        lastReason = reason
        return verdict
    }
}

private struct StubPasswordStore: PasswordStoring {
    let passwords: [String: String]
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { passwords[key] }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { Array(passwords.keys) }
}

/// Records the credential each archive was extracted with.
private final class RecordingEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]

    private let lock = NSLock()
    private var seen: [URL: String?] = [:]

    /// `nil` when the archive was extracted without a credential; the recorded
    /// value otherwise. Distinguishing "not called" from "called with nil" matters:
    /// a test asserting nil must not pass merely because extraction never ran.
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

private final class AuthGateNoopEditor: ArchiveEditing, @unchecked Sendable {
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
