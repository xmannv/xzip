import XCTest
@testable import XZip

/// Regression tests for stable system-default Place identity: the
/// startup-location setting stores a Place id, so ids must survive relaunch.
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

    func testSystemDefaultIDsAreStableAcrossLoads() {
        let first = PlacesStore(defaults: defaults).load()
        let second = PlacesStore(defaults: defaults).load()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}
