import XCTest
@testable import XZip

/// Unit tests for the "open at launch" preference resolution.
final class StartupLocationTests: XCTestCase {
    private func place(named name: String = "Downloads") -> Place {
        Place(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), symbol: "folder")
    }

    func testNilOrEmptyStoredIDMeansStartScreen() {
        XCTAssertNil(StartupLocation.resolve(storedID: nil, places: [place()]))
        XCTAssertNil(StartupLocation.resolve(storedID: "", places: [place()]))
    }

    func testValidStoredIDResolvesMatchingPlace() {
        let target = place(named: "Desktop")
        let resolved = StartupLocation.resolve(
            storedID: target.id.uuidString,
            places: [place(), target]
        )
        XCTAssertEqual(resolved?.id, target.id)
    }

    func testUnknownStoredIDMeansStartScreen() {
        XCTAssertNil(StartupLocation.resolve(storedID: UUID().uuidString, places: [place()]))
    }

    func testMalformedStoredIDMeansStartScreen() {
        XCTAssertNil(StartupLocation.resolve(storedID: "not-a-uuid", places: [place()]))
    }
}
