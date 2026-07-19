import XCTest
import XZIPCore
@testable import XZip

/// Unit tests for the round-2 browser/queue logic extracted into `ArchiveBrowsing`.
/// These are pure and need no `AppModel`, engine, or Keychain.
final class ArchiveBrowsingTests: XCTestCase {

    // MARK: - Helpers

    private func entry(_ path: String, kind: XZip.ArchiveEntryKind = .file) -> XZip.ArchiveEntry {
        XZip.ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            originalSize: 100,
            compressedSize: 50,
            modifiedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - visibleEntries (mockup 1b folder scoping)

    func testVisibleEntriesAtRootShowsDirectChildrenOnly() {
        let entries = [
            entry("Docs", kind: .folder),
            entry("Docs/readme.md"),
            entry("Docs/img/logo.png"),
            entry("top.txt")
        ]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "")
        let names = Set(visible.map(\.name))
        // Direct children of root: "Docs" folder + "top.txt". Nested files excluded.
        XCTAssertEqual(names, ["Docs", "top.txt"])
    }

    func testVisibleEntriesInsideFolder() {
        let entries = [
            entry("Docs/readme.md"),
            entry("Docs/img/logo.png"),
            entry("top.txt")
        ]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "Docs")
        // Only the direct child of "Docs" (readme.md); nested "img/logo.png" excluded.
        XCTAssertEqual(visible.map(\.name), ["readme.md"])
    }

    func testVisibleEntriesNormalizesLeadingSlash() {
        let entries = [entry("/Docs/readme.md"), entry("/top.txt")]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "Docs")
        XCTAssertEqual(visible.map(\.name), ["readme.md"])
    }

    func testVisibleEntriesFlatArchiveFallsBackToAllAtRoot() {
        // No directory structure, all entries have nested-looking paths but we're
        // at root and nothing matched the "direct child" rule → return all.
        let entries = [entry("a/b/c.txt"), entry("d/e/f.txt")]
        let visible = ArchiveBrowsing.visibleEntries(entries, currentFolderPath: "")
        XCTAssertEqual(visible.count, 2)
    }

    func testVisibleEntriesEmptyInput() {
        XCTAssertTrue(ArchiveBrowsing.visibleEntries([], currentFolderPath: "").isEmpty)
        XCTAssertTrue(ArchiveBrowsing.visibleEntries([], currentFolderPath: "Docs").isEmpty)
    }

    // MARK: - breadcrumbs (mockup 1b)

    func testBreadcrumbsAtRoot() {
        let crumbs = ArchiveBrowsing.breadcrumbs(archiveName: "Backup.zip", currentFolderPath: "")
        XCTAssertEqual(crumbs.count, 1)
        XCTAssertEqual(crumbs[0].name, "Backup.zip")
        XCTAssertEqual(crumbs[0].path, "")
    }

    func testBreadcrumbsNestedAccumulatesPaths() {
        let crumbs = ArchiveBrowsing.breadcrumbs(archiveName: "Backup.zip", currentFolderPath: "a/b/c")
        XCTAssertEqual(crumbs.map(\.name), ["Backup.zip", "a", "b", "c"])
        XCTAssertEqual(crumbs.map(\.path), ["", "a", "a/b", "a/b/c"])
    }

    // MARK: - estimateRemaining (mockup 3e ETA)

    func testEstimateRemainingTooEarlyReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 0.01, elapsed: 10))
    }

    func testEstimateRemainingCompleteReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 1.0, elapsed: 10))
    }

    func testEstimateRemainingSeconds() {
        // 50% done in 10s → ~10s remaining.
        XCTAssertEqual(ArchiveBrowsing.estimateRemaining(fraction: 0.5, elapsed: 10), "10 s left")
    }

    func testEstimateRemainingMinutes() {
        // 10% done in 60s → total 600s, ~540s remaining → 9 min.
        XCTAssertEqual(ArchiveBrowsing.estimateRemaining(fraction: 0.1, elapsed: 60), "9 min left")
    }

    func testEstimateRemainingNearDoneReturnsNil() {
        // 99.5% done in 100s → total ~100.5s, remaining ~0.5s → under 1s threshold.
        XCTAssertNil(ArchiveBrowsing.estimateRemaining(fraction: 0.995, elapsed: 100))
    }

    // MARK: - savedPercent (mockup 4c)

    func testSavedPercentTypical() {
        XCTAssertEqual(ArchiveBrowsing.savedPercent(inputBytes: 1000, outputBytes: 250), 75)
    }

    func testSavedPercentLargerOutputClampsToZero() {
        XCTAssertEqual(ArchiveBrowsing.savedPercent(inputBytes: 1000, outputBytes: 1200), 0)
    }

    func testSavedPercentZeroInputReturnsNil() {
        XCTAssertNil(ArchiveBrowsing.savedPercent(inputBytes: 0, outputBytes: 100))
        XCTAssertNil(ArchiveBrowsing.savedPercent(inputBytes: 100, outputBytes: 0))
    }

    // MARK: - relativePath

    func testRelativePathStripsLeadingSlash() {
        XCTAssertEqual(ArchiveBrowsing.relativePath(entry("/a/b.txt")), "a/b.txt")
        XCTAssertEqual(ArchiveBrowsing.relativePath(entry("a/b.txt")), "a/b.txt")
    }
}

final class ArchiveListingCacheTests: XCTestCase {
    private final class ListingEngineProbe: ArchiveEngine, @unchecked Sendable {
        let supportedFormats: Set<XZIPCore.ArchiveFormat> = [.zip]

        private let lock = NSLock()
        private let listStarted = DispatchSemaphore(value: 0)
        private let listCanFinish = DispatchSemaphore(value: 0)
        private var entries: [XZIPCore.ArchiveEntry]
        private var shouldBlockNextList = false
        private var calls = 0

        init(entries: [XZIPCore.ArchiveEntry]) {
            self.entries = entries
        }

        var listCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func replaceEntries(with entries: [XZIPCore.ArchiveEntry]) {
            lock.lock(); defer { lock.unlock() }
            self.entries = entries
        }

        func blockNextList() {
            lock.lock(); defer { lock.unlock() }
            shouldBlockNextList = true
        }

        func waitUntilListStarts(timeout: TimeInterval) -> Bool {
            listStarted.wait(timeout: .now() + timeout) == .success
        }

        func releaseBlockedList() {
            listCanFinish.signal()
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
            AsyncThrowingStream { $0.finish() }
        }

        func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] {
            let (snapshot, shouldBlock) = snapshotForList()
            if shouldBlock {
                listStarted.signal()
                waitForListRelease()
            }
            return snapshot
        }

        func list(
            archive: URL,
            password: String?,
            limit: Int
        ) async throws -> ArchiveListingResult {
            let entries = try await list(archive: archive, password: password)
            return ArchiveListingResult(
                entries: Array(entries.prefix(limit)),
                truncated: entries.count > limit
            )
        }

        func test(archive: URL, password: String?) async throws -> Bool { true }

        private func snapshotForList() -> ([XZIPCore.ArchiveEntry], Bool) {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            let shouldBlock = shouldBlockNextList
            shouldBlockNextList = false
            return (entries, shouldBlock)
        }

        private func waitForListRelease() {
            listCanFinish.wait()
        }
    }

    private struct EngineFactoryProbe: ArchiveEngineProviding {
        let engine: ListingEngineProbe

        func engine(for format: XZIPCore.ArchiveFormat) throws -> any ArchiveEngine { engine }
        func engine(forArchive url: URL) throws -> any ArchiveEngine { engine }
    }

    private struct EditorProbe: ArchiveEditing {
        let engine: ListingEngineProbe

        func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
        func addViaRepack(
            files: [URL],
            to archive: URL,
            onStep: @escaping @Sendable (RepackStep) -> Void
        ) async throws {}
        func delete(entries: [String], from archive: URL, password: String?) async throws {
            engine.replaceEntries(with: [])
        }
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
    }

    private struct PasswordStoreProbe: PasswordStoring {
        func save(password: String, for key: String) throws {}
        func password(for key: String) throws -> String? { nil }
        func delete(for key: String) throws {}
        func allKeys() throws -> [String] { [] }
    }

    func testDeleteInvalidatesCachedListingWhenArchiveModificationDateIsUnchanged() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let engine = ListingEngineProbe(entries: [entry("file.txt")])
        let service = makeService(engine: engine, archive: archive)

        let initialEntries = try await service.list(archive: archive, password: nil)
        XCTAssertEqual(initialEntries.map(\.path), ["file.txt"])

        try await service.delete(entries: ["file.txt"], from: archive, password: nil)

        let refreshedEntries = try await service.list(archive: archive, password: nil)
        XCTAssertTrue(refreshedEntries.isEmpty)
        XCTAssertEqual(engine.listCallCount, 2)
    }

    func testMutationPreventsInFlightOldListingFromRepopulatingCache() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let engine = ListingEngineProbe(entries: [entry("file.txt")])
        let service = makeService(engine: engine, archive: archive)
        engine.blockNextList()

        let staleList = Task { try await service.list(archive: archive, password: nil) }
        let didStart = await Task.detached { engine.waitUntilListStarts(timeout: 2) }.value
        XCTAssertTrue(didStart)

        try await service.delete(entries: ["file.txt"], from: archive, password: nil)
        engine.releaseBlockedList()
        let staleEntries = try await staleList.value
        XCTAssertEqual(staleEntries.map(\.path), ["file.txt"])

        let refreshedEntries = try await service.list(archive: archive, password: nil)
        XCTAssertTrue(refreshedEntries.isEmpty)
        XCTAssertEqual(engine.listCallCount, 2)
    }

    @MainActor
    func testRefreshIgnoresOlderListingForSameArchive() async throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        let engine = ListingEngineProbe(entries: [entry("file.txt")])
        let service = makeService(engine: engine, archive: archive)
        let model = AppModel(service: service)
        let openArchive = OpenArchive(url: archive)
        model.openArchives = [openArchive]
        model.currentArchiveID = openArchive.id
        engine.blockNextList()

        let staleRefresh = model.refreshEntries()
        let didStart = await Task.detached { engine.waitUntilListStarts(timeout: 2) }.value
        XCTAssertTrue(didStart)

        try await service.delete(entries: ["file.txt"], from: archive, password: nil)
        let currentRefresh = model.refreshEntries()
        await currentRefresh.value
        XCTAssertEqual(engine.listCallCount, 2)
        XCTAssertTrue(model.archiveEntries.isEmpty)

        engine.releaseBlockedList()
        await staleRefresh.value

        XCTAssertTrue(model.archiveEntries.isEmpty)
    }

    private func makeArchive() throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try Data().write(to: archive)
        return archive
    }

    private func makeService(engine: ListingEngineProbe, archive: URL) -> ArchiveService {
        ArchiveService(
            engineFactory: EngineFactoryProbe(engine: engine),
            editor: EditorProbe(engine: engine),
            passwordStore: PasswordStoreProbe(),
            presetStore: PresetStore(fileURL: archive.appendingPathExtension("presets.json")),
            commentService: ArchiveCommentService(),
            splitJoiner: SplitArchiveJoiner()
        )
    }

    private func entry(_ path: String) -> XZIPCore.ArchiveEntry {
        XZIPCore.ArchiveEntry(
            path: path,
            uncompressedSize: 1,
            compressedSize: 1,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )
    }
}
