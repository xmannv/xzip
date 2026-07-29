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

    // MARK: - rows / sort
    //
    // This is what the archive table displays. It moved out of the view so it can
    // run off the main actor, which means the ordering rules are now checked here
    // rather than being implicit in a `sorted(using:)` call.

    private func sized(
        _ path: String,
        bytes: Int64 = 100,
        modified: TimeInterval = 0,
        kind: XZip.ArchiveEntryKind = .file
    ) -> XZip.ArchiveEntry {
        XZip.ArchiveEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            originalSize: bytes,
            compressedSize: bytes / 2,
            modifiedAt: Date(timeIntervalSince1970: modified))
    }

    private func names(
        _ entries: [XZip.ArchiveEntry],
        search: String = "",
        folder: String = "",
        key: ArchiveBrowsing.SortKey = .name,
        ascending: Bool = true,
        foldersFirst: Bool = false
    ) -> [String] {
        ArchiveBrowsing.rows(
            entries,
            search: search,
            currentFolderPath: folder,
            key: key,
            ascending: ascending,
            foldersFirst: foldersFirst
        ).map(\.name)
    }

    func testRowsAreScopedToTheCurrentFolderWhenNotSearching() {
        let entries = [sized("a/one.txt"), sized("a/two.txt"), sized("b/three.txt")]
        XCTAssertEqual(names(entries, folder: "a"), ["one.txt", "two.txt"])
    }

    /// Searching deliberately ignores the current folder: the results header says
    /// "including subfolders", and a match the user cannot see would be useless.
    func testSearchingLooksPastTheCurrentFolder() {
        let entries = [sized("a/report.txt"), sized("b/report-2.txt"), sized("a/other.txt")]
        XCTAssertEqual(
            names(entries, search: "report", folder: "a"),
            ["report-2.txt", "report.txt"]
        )
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(names([sized("README.md")], search: "readme"), ["README.md"])
    }

    func testSortsByNameInBothDirections() {
        let entries = [sized("b.txt"), sized("a.txt"), sized("c.txt")]
        XCTAssertEqual(names(entries), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(names(entries, ascending: false), ["c.txt", "b.txt", "a.txt"])
    }

    func testSortsBySize() {
        let entries = [sized("big", bytes: 900), sized("small", bytes: 1)]
        XCTAssertEqual(names(entries, key: .size), ["small", "big"])
        XCTAssertEqual(names(entries, key: .size, ascending: false), ["big", "small"])
    }

    func testSortsByModifiedDate() {
        let entries = [sized("new", modified: 5000), sized("old", modified: 10)]
        XCTAssertEqual(names(entries, key: .modified), ["old", "new"])
    }

    /// Equal sizes fall back to name, so the order does not wobble between runs.
    func testEqualSizesBreakTheTieOnName() {
        let entries = [sized("b", bytes: 50), sized("a", bytes: 50), sized("c", bytes: 50)]
        XCTAssertEqual(names(entries, key: .size), ["a", "b", "c"])
    }

    /// Entries with the same name and size — which an archive can hold, at
    /// different paths — get a deterministic order from the `path` tiebreaker.
    ///
    /// Without that final unique key these rows would compare equal, and
    /// `sorted(by:)` guarantees nothing about how it arranges equal elements: the
    /// display order would be at the mercy of the standard library and could differ
    /// between runs on the same archive.
    func testSameNameEntriesAreOrderedByPath() {
        let entries = [
            sized("c/same.txt", bytes: 42),
            sized("a/same.txt", bytes: 42),
            sized("b/same.txt", bytes: 42)
        ]
        let paths = ArchiveBrowsing.rows(
            entries,
            search: "",
            currentFolderPath: "",
            key: .size,
            ascending: true,
            foldersFirst: false
        ).map(\.path)

        XCTAssertEqual(paths, ["a/same.txt", "b/same.txt", "c/same.txt"])
    }

    /// The same input reversed: descending must be the exact mirror, with nothing
    /// dropped or duplicated.
    ///
    /// Compared on `path`, not name — every one of these entries is called
    /// `same.txt`, so a name comparison would hold for any arrangement at all and
    /// assert nothing.
    func testSameNameEntriesReverseCleanly() {
        let entries = (1...12).map { sized("dir\($0)/same.txt", bytes: 42, modified: 99) }
        let paths = { (ascending: Bool) in
            ArchiveBrowsing.rows(
                entries,
                search: "",
                currentFolderPath: "",
                key: .size,
                ascending: ascending,
                foldersFirst: false
            ).map(\.path)
        }

        XCTAssertEqual(paths(true).count, 12)
        XCTAssertEqual(paths(false), paths(true).reversed())
    }

    /// Folders stay on top whichever way the column points, matching Finder and
    /// `FolderBrowsing.sort`.
    func testFoldersAreHoistedInBothDirections() {
        let entries = [sized("zeta.txt"), sized("alpha", kind: .folder), sized("beta.txt")]
        XCTAssertEqual(
            names(entries, foldersFirst: true),
            ["alpha", "beta.txt", "zeta.txt"]
        )
        XCTAssertEqual(
            names(entries, ascending: false, foldersFirst: true),
            ["alpha", "zeta.txt", "beta.txt"]
        )
    }

    func testFoldersSortInlineWhenHoistingIsOff() {
        let entries = [sized("zeta.txt"), sized("mid", kind: .folder), sized("alpha.txt")]
        XCTAssertEqual(names(entries), ["alpha.txt", "mid", "zeta.txt"])
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
            workspace: URL,
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

        try await service.delete(
            entries: ["file.txt"], from: archive, password: nil, admission: .refuseIfBusy)

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

        try await service.delete(
            entries: ["file.txt"], from: archive, password: nil, admission: .refuseIfBusy)
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

        try await service.delete(
            entries: ["file.txt"], from: archive, password: nil, admission: .refuseIfBusy)
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
