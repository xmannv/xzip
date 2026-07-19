import AppKit

/// Presents the native macOS share sheet (`NSSharingServicePicker`) for a set
/// of file URLs, anchored to the app's key window.
///
/// Design: a plain helper rather than a SwiftUI wrapper. Context-menu actions
/// call `present(_:)` directly; the picker anchors to the current mouse
/// location in the key window, matching where the user right-clicked.
enum SharePicker {
    @MainActor
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty,
              let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let picker = NSSharingServicePicker(items: urls)

        // Anchor a 1pt rect at the current cursor location (in view coords).
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = contentView.convert(mouseInWindow, from: nil)
        let anchor = NSRect(origin: pointInView, size: CGSize(width: 1, height: 1))

        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }
}
