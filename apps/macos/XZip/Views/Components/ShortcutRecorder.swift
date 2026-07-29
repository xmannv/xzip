import SwiftUI
import AppKit

/// A click-to-record keyboard shortcut field. While focused ("recording"), it
/// captures the next key + modifier combination via a local `NSEvent` monitor
/// and reports it back. Escape cancels; the field shows the current glyph.
///
/// Design: a lightweight `NSView` subclass rather than pulling in a dependency.
/// Only one recorder records at a time (the monitor is torn down on blur).
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { self.shortcut = $0 }
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.shortcut = shortcut
        nsView.needsDisplay = true
    }

    /// Focusable button-like view that records the next chord while active.
    final class RecorderView: NSView {
        var shortcut: Shortcut?
        var onCapture: ((Shortcut) -> Void)?

        private var recording = false { didSet { needsDisplay = true } }
        // `nonisolated(unsafe)`: the event monitor token is only ever touched on
        // the main thread (start/stop/deinit all run there), but Swift 6's
        // nonisolated `deinit` can't prove the `Any?` is Sendable otherwise.
        private nonisolated(unsafe) var monitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

        override func mouseDown(with event: NSEvent) {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event)
                return nil // swallow while recording
            }
        }

        private func stop() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            // Escape cancels without changing the binding.
            if event.keyCode == 53 { stop(); return }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: EventModifiers = []
            if flags.contains(.command) { mods.insert(.command) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.control) { mods.insert(.control) }

            // Require at least one modifier for a menu shortcut, and a base char.
            guard !mods.isEmpty,
                  let chars = event.charactersIgnoringModifiers, let first = chars.first
            else { return }

            let captured = Shortcut(key: String(first), modifiers: mods)
            shortcut = captured
            onCapture?(captured)
            stop()
        }

        override func resignFirstResponder() -> Bool {
            stop()
            return super.resignFirstResponder()
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 5
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 2 : 1
            path.stroke()

            let text = recording ? "Press keys…" : (shortcut?.displayString ?? "Unset")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
                .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                      withAttributes: attrs)
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
