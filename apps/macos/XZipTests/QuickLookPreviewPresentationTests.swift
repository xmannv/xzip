import XCTest
@testable import XZip

final class QuickLookPreviewPresentationTests: XCTestCase {
    func testTruncatedCountUsesPlusSuffix() {
        XCTAssertEqual(
            QuickLookPreviewPresentation.itemCountText(count: 5_000, truncated: true),
            "5,000+"
        )
    }

    func testCompleteCountIsExact() {
        XCTAssertEqual(
            QuickLookPreviewPresentation.itemCountText(count: 42, truncated: false),
            "42"
        )
    }
}
