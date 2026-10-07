import AppKit
import SwiftUI

/// Calls `action` when Space is pressed in this view's window and no text field
/// is being edited. SwiftUI's `onKeyPress` never sees the key from a `Table`
/// (AppKit owns the focus, and loses it entirely after navigating into a
/// subfolder), so it is caught here instead.
struct SpaceKeyHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.attach(to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var action: () -> Void = {}
        private var monitor: Any?

        func attach(to view: NSView) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window,
                      event.window === window,
                      event.keyCode == 49,  // Space
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      window.isKeyWindow,
                      // A field editor (search box, rename sheet) must keep its Space.
                      !(window.firstResponder is NSText)
                else { return event }
                self.action()
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { detach() }
    }
}
