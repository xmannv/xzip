import AppKit
import XCTest
@testable import XZip

/// Tests for `ClipboardService`, which copies saved passwords and wipes them
/// again after a delay.
///
/// Every test uses a **private** pasteboard, never `NSPasteboard.general`: a test
/// run must not overwrite or clear whatever the developer has on their clipboard.
final class ClipboardServiceTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("xzip.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - Write path

    func testCopySecretPutsTheSecretOnThePasteboard() {
        ClipboardService.copySecret("s3cret", autoClear: false, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")
    }

    func testCopySecretMarksTheItemConcealed() {
        ClipboardService.copySecret("s3cret", autoClear: false, pasteboard: pasteboard)

        // Clipboard managers look for this type to decide not to persist an item.
        // Losing it would mean saved passwords quietly land in clipboard history.
        XCTAssertNotNil(
            pasteboard.string(
                forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
            "the secret must be flagged so clipboard managers skip it")
    }

    func testCopySecretReplacesAPreviousSecret() {
        ClipboardService.copySecret("first", autoClear: false, pasteboard: pasteboard)
        ClipboardService.copySecret("second", autoClear: false, pasteboard: pasteboard)

        XCTAssertEqual(
            pasteboard.string(forType: .string), "second",
            "a second copy must not leave the earlier password readable")
    }

    func testSecretPasteboardOptionsAreCurrentHostOnly() {
        // Keeps the password off other Macs sharing the same Universal Clipboard.
        XCTAssertEqual(ClipboardService.secretPasteboardOptions, .currentHostOnly)
    }

    // MARK: - Auto-clear

    func testAutoClearWipesTheSecretAfterTheDelay() async throws {
        ClipboardService.copySecret(
            "s3cret", autoClear: true, pasteboard: pasteboard, clearAfter: 0.05)
        XCTAssertEqual(pasteboard.string(forType: .string), "s3cret")

        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(
            pasteboard.string(forType: .string),
            "the password must not stay on the pasteboard past the delay")
    }

    func testAutoClearOffLeavesTheSecretInPlace() async throws {
        ClipboardService.copySecret(
            "s3cret", autoClear: false, pasteboard: pasteboard, clearAfter: 0.05)

        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            pasteboard.string(forType: .string), "s3cret",
            "with the preference off, XZip must not touch the clipboard again")
    }

    func testAutoClearLeavesAValueTheUserCopiedAfterwards() async throws {
        ClipboardService.copySecret(
            "s3cret", autoClear: true, pasteboard: pasteboard, clearAfter: 0.05)

        // Stands in for the user copying something else before the wipe lands.
        pasteboard.clearContents()
        pasteboard.setString("user's own text", forType: .string)

        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            pasteboard.string(forType: .string), "user's own text",
            "the scheduled wipe must only clear the secret it wrote")
    }

    func testDefaultClearDelayIsThirtySeconds() {
        // The Settings copy promises 30 seconds; this pins the two together.
        XCTAssertEqual(ClipboardService.clearDelay, 30)
    }
}
