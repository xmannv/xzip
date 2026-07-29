import XCTest
import XZIPCore
@testable import XZip

/// Two properties the credential store inherited from the session-password
/// design it replaced, neither of which was covered elsewhere:
///
/// - a URL that differs only in redundant components must resolve to the same
///   credential, otherwise the same archive gets prompted for twice;
/// - a password remembered in the Keychain must unlock an archive without
///   prompting, which is the whole point of the "Remember" checkbox.
@MainActor
final class ArchiveCredentialVaultTests: XCTestCase {

    // MARK: - Keying

    func testEquivalentPathsResolveToTheSameCredential() throws {
        let archive = try makeArchive()
        let model = AppModel(service: makeService(engine: PasswordEngineProbe()))

        model.credentials.store("secret", for: archive)
        // Same file, spelled with a redundant "." component.
        let alias = archive.deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(archive.lastPathComponent)

        XCTAssertEqual(
            model.credential(for: alias), "secret",
            "an equivalent path must not be treated as a different archive")
    }

    func testDistinctArchivesDoNotShareACredential() throws {
        let first = try makeArchive()
        let second = try makeArchive()
        let model = AppModel(service: makeService(engine: PasswordEngineProbe()))

        model.credentials.store("first-secret", for: first)

        XCTAssertNil(
            model.credential(for: second),
            "a credential must never leak to another archive")
    }

    // MARK: - Vault fallback

    func testARememberedVaultPasswordUnlocksWithoutPrompting() async throws {
        let archive = try makeArchive()
        let engine = PasswordEngineProbe(required: "vaulted")
        // Seeded under the vault key, which is the standardized path.
        let store = PasswordStoreProbe(
            seeded: [archive.standardizedFileURL.path: "vaulted"])
        let model = AppModel(service: makeService(engine: engine, store: store))
        open(archive, in: model)

        await model.refreshEntries().value

        XCTAssertEqual(
            engine.listedPasswords, ["vaulted"],
            "the listing must use the remembered password, not list unauthenticated")
        XCTAssertFalse(
            model.isPasswordPromptPresented,
            "a remembered password must not prompt the user again")
    }

    func testAVaultPasswordForAnotherArchiveIsNotUsed() async throws {
        let archive = try makeArchive()
        let other = try makeArchive()
        let engine = PasswordEngineProbe(required: "vaulted")
        // The vault holds a password for a DIFFERENT archive.
        let store = PasswordStoreProbe(
            seeded: [other.standardizedFileURL.path: "vaulted"])
        let model = AppModel(service: makeService(engine: engine, store: store))
        open(archive, in: model)

        await model.refreshEntries().value

        XCTAssertEqual(
            engine.listedPasswords, [nil],
            "another archive's vault entry must not be offered as this one's password")
    }

    // MARK: - Probes

    /// Records the password each listing was attempted with, and can demand a
    /// specific password before it agrees to list.
    private final class PasswordEngineProbe: ArchiveEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String?] = []
        private let required: String?

        init(required: String? = nil) {
            self.required = required
        }

        var listedPasswords: [String?] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        var supportedFormats: Set<XZIPCore.ArchiveFormat> { [.zip, .sevenZip] }

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

        func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] {
            // Locking lives in a synchronous helper: NSLock's lock/unlock are
            // unavailable directly from an async context.
            record(password)
            if let required, password != required {
                throw password == nil
                    ? ArchiveEngineError.passwordRequired
                    : ArchiveEngineError.wrongPassword
            }
            return []
        }

        private func record(_ password: String?) {
            lock.lock(); defer { lock.unlock() }
            seen.append(password)
        }

        func list(
            archive: URL,
            password: String?,
            limit: Int
        ) async throws -> ArchiveListingResult {
            let entries = try await list(archive: archive, password: password)
            return ArchiveListingResult(entries: entries, truncated: false)
        }

        func test(archive: URL, password: String?) async throws -> Bool { true }
    }

    private struct EngineFactoryProbe: ArchiveEngineProviding {
        let engine: PasswordEngineProbe
        func engine(for format: XZIPCore.ArchiveFormat) throws -> any ArchiveEngine { engine }
        func engine(forArchive url: URL) throws -> any ArchiveEngine { engine }
    }

    private struct EditorProbe: ArchiveEditing {
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

    private final class PasswordStoreProbe: PasswordStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        init(seeded: [String: String] = [:]) {
            storage = seeded
        }

        func save(password: String, for key: String) throws {
            lock.lock(); defer { lock.unlock() }
            storage[key] = password
        }

        func password(for key: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        func delete(for key: String) throws {
            lock.lock(); defer { lock.unlock() }
            storage[key] = nil
        }

        func allKeys() throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(storage.keys)
        }
    }

    // MARK: - Fixtures

    private func makeService(
        engine: PasswordEngineProbe,
        store: PasswordStoreProbe = PasswordStoreProbe()
    ) -> ArchiveService {
        ArchiveService(
            engineFactory: EngineFactoryProbe(engine: engine),
            editor: EditorProbe(),
            passwordStore: store,
            presetStore: PresetStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).presets.json")),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
    }

    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try Data().write(to: archive)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// Marks `archive` as the open, current one without going through
    /// `openArchive`, so a test controls exactly when the listing runs.
    @discardableResult
    private func open(_ archive: URL, in model: AppModel) -> OpenArchive {
        let open = OpenArchive(url: archive)
        model.openArchives.append(open)
        model.currentArchiveID = open.id
        return open
    }
}
