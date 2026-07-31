import Foundation
import XCTest
import XZIPCore
@testable import XZip

/// Covers the archives whose data is encrypted behind a PLAINTEXT header — what
/// `7z a -p`, ZIP and RAR without `-hp` produce, and the common case by far.
///
/// `list` succeeds on these with no password at all, which used to mean two
/// things: opening one never prompted (the user saw the file list and a lock
/// badge, but was never asked to unlock), and a wrong password submitted from
/// some other flow was declared correct by the listing and written to the
/// Keychain. Both verdicts now come from `verifyPassword`, which decrypts.
@MainActor
final class DataEncryptedListingPasswordTests: XCTestCase {

    // MARK: - Prompting on open

    func testOpeningADataEncryptedArchivePromptsForAPassword() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(archive: archive, correctPassword: "correct")

        model.openArchive(archive)
        try await Self.settle()

        XCTAssertEqual(
            model.passwordPromptArchive,
            archive,
            "an encrypted archive must ask for a password even though it listed"
        )
        // The listing worked, so the entries are on screen behind the sheet.
        XCTAssertFalse(model.archiveEntries.isEmpty)
    }

    func testOpeningAPlaintextArchiveDoesNotPrompt() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(
            archive: archive,
            correctPassword: "correct",
            isEncrypted: false
        )

        model.openArchive(archive)
        try await Self.settle()

        XCTAssertNil(model.passwordPromptArchive)
        XCTAssertFalse(model.isPasswordPromptPresented)
    }

    // MARK: - The Keychain regression

    func testAWrongPasswordIsRejectedAndNeverReachesTheKeychain() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingStore()
        let model = makeModel(
            archive: archive,
            correctPassword: "correct",
            store: store
        )

        model.openArchive(archive)
        try await Self.settle()
        model.passwordPromptDidSubmit("wrong", saveToKeychain: true)
        try await Self.settle()

        XCTAssertEqual(
            store.saveCount,
            0,
            "a listing that succeeds without a password proves nothing, so a wrong password must not be persisted"
        )
        // The sheet stays on this archive, now carrying the rejection.
        XCTAssertTrue(model.isPasswordPromptPresented)
        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertEqual(
            model.passwordPromptErrorMessage,
            ArchiveEngineError.wrongPassword.localizedDescription
        )
        XCTAssertNil(
            model.credential(for: archive),
            "a password proven wrong must not stay available to the next operation"
        )
    }

    func testACorrectPasswordIsAcceptedSavedAndClosesTheSheet() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingStore()
        let model = makeModel(
            archive: archive,
            correctPassword: "correct",
            store: store
        )

        model.openArchive(archive)
        try await Self.settle()
        model.passwordPromptDidSubmit("correct", saveToKeychain: true)
        try await Self.settle()

        XCTAssertEqual(store.savedValue(for: model.vaultKey(for: archive)), "correct")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertFalse(model.isPasswordPromptPresented)
        XCTAssertEqual(model.credential(for: archive), "correct")
    }

    /// A password remembered from a previous session that no longer works (the
    /// user changed the archive's password) must be caught on open rather than
    /// silently reused until the next extraction fails.
    func testAStaleKeychainPasswordIsDiscardedAndRePrompted() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = RecordingStore()
        let model = makeModel(
            archive: archive,
            correctPassword: "correct",
            store: store
        )
        let key = model.vaultKey(for: archive)
        try store.save(password: "stale", for: key)

        model.openArchive(archive)
        try await Self.settle()

        XCTAssertEqual(model.passwordPromptArchive, archive)
        XCTAssertNil(
            store.savedValue(for: key),
            "a saved password the engine rejected must be dropped from the vault"
        )
        XCTAssertNil(model.credential(for: archive))
    }

    // MARK: - Item counts stay consistent (issue 3)

    /// The status bar counts `archiveEntries`, which includes the folder rows
    /// synthesized for archives without directory records. The sidebar and window
    /// subtitle count `itemCount`, which used to come from the raw listing and so
    /// reported a smaller number for the same archive.
    func testSidebarItemCountMatchesTheRowsTheStatusBarCounts() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let model = makeModel(
            archive: archive,
            correctPassword: "correct",
            isEncrypted: false,
            entryPaths: ["Docs/guide.pdf", "Docs/notes/inner.txt"]
        )

        model.openArchive(archive)
        try await Self.settle()

        let open = try XCTUnwrap(model.openArchives.first { $0.url == archive })
        XCTAssertEqual(open.itemCount, model.archiveEntries.count)
        XCTAssertGreaterThan(
            open.itemCount,
            2,
            "the synthesized Docs and Docs/notes folders are rows too"
        )
    }

    // MARK: - Fixtures

    private func makeModel(
        archive: URL,
        correctPassword: String,
        isEncrypted: Bool = true,
        store: RecordingStore = RecordingStore(),
        entryPaths: [String] = ["secret.txt"]
    ) -> AppModel {
        let engine = DataEncryptedEngine(
            correctPassword: correctPassword,
            isEncrypted: isEncrypted,
            entryPaths: entryPaths
        )
        let service = ArchiveService(
            engineFactory: ArchiveEngineFactory(engines: [engine]),
            editor: NoopMutationEditor(),
            passwordStore: store,
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("data-encrypted-\(UUID().uuidString).json")
            ),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
        return AppModel(service: service)
    }

    /// A real ZIP magic number, so `detectedFormat` resolves an engine.
    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-encrypted-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        return archive
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// Models encrypted data behind a plaintext header: `list` always succeeds, and
/// only `verifyPassword` can tell a right password from a wrong one.
private final class DataEncryptedEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<ArchiveFormat> = [.zip]
    private let correctPassword: String
    private let isEncrypted: Bool
    private let entryPaths: [String]

    init(correctPassword: String, isEncrypted: Bool, entryPaths: [String]) {
        self.correctPassword = correctPassword
        self.isEncrypted = isEncrypted
        self.entryPaths = entryPaths
    }

    private var entries: [XZIPCore.ArchiveEntry] {
        entryPaths.map { path in
            XZIPCore.ArchiveEntry(
                path: path,
                uncompressedSize: 10,
                compressedSize: 10,
                modificationDate: nil,
                isDirectory: false,
                isEncrypted: isEncrypted
            )
        }
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
            guard !isEncrypted || options.password == correctPassword else {
                continuation.finish(
                    throwing: options.password == nil
                        ? ArchiveEngineError.passwordRequired
                        : ArchiveEngineError.wrongPassword
                )
                return
            }
            continuation.yield(ArchiveProgress(fraction: 1))
            continuation.finish()
        }
    }

    /// Deliberately password-blind: this is the whole point of the fixture.
    func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] {
        entries
    }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        ArchiveListingResult(entries: entries, truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        try verifyPassword(password)
        return true
    }

    func verifyPassword(archive: URL, password: String?) async throws {
        try verifyPassword(password)
    }

    private func verifyPassword(_ password: String?) throws {
        guard isEncrypted else { return }
        guard let password, !password.isEmpty else {
            throw ArchiveEngineError.passwordRequired
        }
        guard password == correctPassword else {
            throw ArchiveEngineError.wrongPassword
        }
    }
}

private final class NoopMutationEditor: ArchiveEditing, @unchecked Sendable {
    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {}

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}

    func delete(entries: [String], from archive: URL, password: String?) async throws {}

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {}

    func update(
        entry: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {}
}

private final class RecordingStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    private var saves: [String] = []

    func password(for key: String) throws -> String? {
        lock.withLock { stored[key] }
    }

    func save(password: String, for key: String) throws {
        lock.withLock {
            stored[key] = password
            saves.append(key)
        }
    }

    func delete(for key: String) throws {
        lock.withLock { stored[key] = nil }
    }

    func allKeys() throws -> [String] {
        lock.withLock { Array(stored.keys) }
    }

    func savedValue(for key: String) -> String? {
        lock.withLock { stored[key] }
    }

    var saveCount: Int { lock.withLock { saves.count } }
}
