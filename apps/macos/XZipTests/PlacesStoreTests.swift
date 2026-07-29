import XCTest
@testable import XZip

/// Tests for `PlacesStore`, which persists the user's favorite destinations as
/// bookmarks in `UserDefaults`.
///
/// A private suite is used throughout so a test run never reads or writes the
/// real app's preferences.
final class PlacesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "PlacesStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Defaults

    /// Regression test for stable system-default Place identity: the
    /// startup-location setting stores a Place id, so ids must survive relaunch.
    func testSystemDefaultIDsAreStableAcrossLoads() {
        let first = PlacesStore(defaults: defaults).load()
        let second = PlacesStore(defaults: defaults).load()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Round trip

    func testSavedPlacesComeBackOnTheNextLoad() throws {
        let folder = try makeFolder()
        let store = PlacesStore(defaults: defaults)

        let saved = store.add(url: folder, name: "Project", symbol: "hammer", to: [])

        // A fresh store stands in for the next launch: only what actually reached
        // `UserDefaults` can survive.
        let reloaded = PlacesStore(defaults: defaults).load()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, saved.first?.id, "identity must survive a reload")
        XCTAssertEqual(reloaded.first?.name, "Project")
        XCTAssertEqual(reloaded.first?.symbol, "hammer")
        XCTAssertEqual(
            reloaded.first?.url.standardizedFileURL,
            folder.standardizedFileURL,
            "the bookmark must resolve back to the same folder")
    }

    func testSavedOrderIsPreserved() throws {
        let first = try makeFolder()
        let second = try makeFolder()
        let store = PlacesStore(defaults: defaults)

        var places = store.add(url: first, name: "First", to: [])
        places = store.add(url: second, name: "Second", to: places)

        // Places are drag-reorderable, so the stored order is user intent.
        XCTAssertEqual(PlacesStore(defaults: defaults).load().map(\.name), ["First", "Second"])

        store.save(places.reversed())
        XCTAssertEqual(PlacesStore(defaults: defaults).load().map(\.name), ["Second", "First"])
    }

    func testRemovedPlaceDoesNotComeBack() throws {
        let folder = try makeFolder()
        let store = PlacesStore(defaults: defaults)
        let places = store.add(url: folder, name: "Project", to: [])

        let remaining = store.remove(places[0], from: places)

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(PlacesStore(defaults: defaults).load().isEmpty)
    }

    func testABookmarkFollowsARenamedFolder() throws {
        let folder = try makeFolder()
        _ = PlacesStore(defaults: defaults).add(url: folder, name: "Project", to: [])

        let renamed = folder.deletingLastPathComponent()
            .appendingPathComponent("renamed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        addTeardownBlock { try? FileManager.default.removeItem(at: renamed) }

        // This is why bookmarks are stored instead of paths: it is the same
        // folder, so the place has to follow it.
        XCTAssertEqual(
            PlacesStore(defaults: defaults).load().first?.url.standardizedFileURL,
            renamed.standardizedFileURL)
    }

    // MARK: - Failures are surfaced

    func testAnUnbookmarkablePlaceIsReportedRatherThanDroppedSilently() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let reported = Reported()
        let store = PlacesStore(
            defaults: defaults,
            onFailure: { message in reported.record(message) }
        )

        _ = store.add(url: missing, name: "Gone", to: [])

        // The old implementation dropped this with a `compactMap`, so the place
        // vanished from the sidebar with nothing to explain why.
        XCTAssertFalse(
            reported.messages.isEmpty,
            "a place that cannot be persisted must be reported to the user")
    }

    func testSavingAValidPlaceReportsNothing() throws {
        let folder = try makeFolder()
        let reported = Reported()
        let store = PlacesStore(
            defaults: defaults,
            onFailure: { message in reported.record(message) }
        )

        _ = store.add(url: folder, name: "Project", to: [])

        XCTAssertTrue(reported.messages.isEmpty, "a successful save must stay quiet")
    }

    // MARK: - Helpers

    /// Thread-safe because `onFailure` is `@Sendable` and may be invoked from
    /// whichever context performed the save.
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var messages: [String] { lock.withLock { stored } }
        func record(_ message: String) { lock.withLock { stored.append(message) } }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
