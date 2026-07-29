import AppKit
import XCTest
@testable import XZip

final class FixedTableRowHeightTests: XCTestCase {
    @MainActor
    func testConfigureDisablesAutomaticRowHeights() {
        let tableView = NSTableView()
        tableView.usesAutomaticRowHeights = true
        tableView.rowSizeStyle = .medium
        tableView.rowHeight = 40

        FixedTableRowHeight.configure(tableView, rowHeight: 24)

        XCTAssertFalse(tableView.usesAutomaticRowHeights)
        XCTAssertEqual(tableView.rowSizeStyle, .custom)
        XCTAssertEqual(tableView.rowHeight, 24)
    }

    @MainActor
    func testMatchingTableUsesMarkerPositionInsteadOfFirstTableInWindow() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sidebarScrollView = makeTableScrollView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        let folderScrollView = makeTableScrollView(frame: NSRect(x: 150, y: 0, width: 450, height: 400))
        contentView.addSubview(sidebarScrollView)
        contentView.addSubview(folderScrollView)
        let window = NSWindow(contentRect: contentView.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = contentView

        let match = FixedTableRowHeight.matchingTableView(
            in: contentView,
            at: NSPoint(x: 375, y: 200)
        )

        XCTAssertIdentical(match, folderScrollView.documentView as? NSTableView)
    }

    @MainActor
    private func makeTableScrollView(frame: NSRect) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = NSTableView(frame: scrollView.bounds)
        return scrollView
    }
}
