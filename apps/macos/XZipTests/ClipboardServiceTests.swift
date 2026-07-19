import AppKit
import XCTest
@testable import XZip

final class ClipboardServiceTests: XCTestCase {
    func testSecretPasteboardOptionsAreCurrentHostOnly() {
        XCTAssertEqual(
            ClipboardService.secretPasteboardOptions,
            .currentHostOnly
        )
    }
}
