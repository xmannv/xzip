import AppKit

/// Presents the native macOS share sheet (`NSSharingServicePicker`) for a set
/// of file URLs, anchored to the app's key window.
///
/// Design: a plain helper rather than a SwiftUI wrapper. Context-menu actions
/// call `present(_:)` directly; the picker anchors to the current mouse
/// location in the key window, matching where the user right-clicked.
@MainActor
enum SharePicker {
    private static var selectionHandlers: [ObjectIdentifier: SelectionHandler] = [:]

    static func present(
        _ urls: [URL],
        onCancelled: @escaping @MainActor () -> Void = {}
    ) {
        guard !urls.isEmpty,
              let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            onCancelled()
            return
        }

        let picker = NSSharingServicePicker(items: urls)
        let pickerID = ObjectIdentifier(picker)
        let handler = SelectionHandler(
            onCancelled: onCancelled,
            onFinished: { selectionHandlers[pickerID] = nil }
        )
        selectionHandlers[pickerID] = handler
        picker.delegate = handler

        // Anchor a 1pt rect at the current cursor location (in view coords).
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = contentView.convert(mouseInWindow, from: nil)
        let anchor = NSRect(origin: pointInView, size: CGSize(width: 1, height: 1))

        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    final class SelectionHandler: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate, @unchecked Sendable {
        private let onCancelled: @MainActor () -> Void
        private let onFinished: @MainActor () -> Void
        private var isFinished = false

        init(
            onCancelled: @escaping @MainActor () -> Void,
            onFinished: @escaping @MainActor () -> Void = {}
        ) {
            self.onCancelled = onCancelled
            self.onFinished = onFinished
        }

        nonisolated func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            delegateFor sharingService: NSSharingService
        ) -> NSSharingServiceDelegate? {
            self
        }

        nonisolated func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            guard service == nil else { return }
            MainActor.assumeIsolated {
                finish(cancelled: true)
            }
        }

        nonisolated func sharingService(
            _ sharingService: NSSharingService,
            didShareItems items: [Any]
        ) {
            MainActor.assumeIsolated {
                finish(cancelled: false)
            }
        }

        nonisolated func sharingService(
            _ sharingService: NSSharingService,
            didFailToShareItems items: [Any],
            error: Error
        ) {
            MainActor.assumeIsolated {
                finish(cancelled: true)
            }
        }

        @MainActor
        private func finish(cancelled: Bool) {
            guard !isFinished else { return }
            isFinished = true
            if cancelled {
                onCancelled()
            }
            onFinished()
        }
    }
}
