import Foundation
import AppKit

/// Copies sensitive text (saved passwords) to the pasteboard and optionally
/// clears it after a delay, honouring the "Clear clipboard 30 seconds after
/// copying a password" preference.
///
/// Design: macOS has no "expiring pasteboard" API, so we snapshot the value we
/// wrote and only clear if the pasteboard still holds it after the delay — this
/// avoids wiping something the user copied in the meantime. Marking the item as
/// `org.nspasteboard.ConcealedType` also asks clipboard managers not to store it.
enum ClipboardService {
    static let clearDelay: TimeInterval = 30

    static let secretPasteboardOptions: NSPasteboard.ContentsOptions =
        .currentHostOnly

    /// Copy `secret` to the pasteboard. If `autoClear` is true, schedule a wipe
    /// after 30s (only if the value is unchanged).
    ///
    /// `pasteboard` and `clearAfter` exist so the behaviour can be tested: a test
    /// that asserted on `secretPasteboardOptions` alone would keep passing even if
    /// the write or the wipe broke. Both default to production values, so callers
    /// are unaffected — and tests use a private pasteboard so a test run never
    /// touches what the user has copied.
    static func copySecret(
        _ secret: String,
        autoClear: Bool,
        pasteboard: NSPasteboard = .general,
        clearAfter delay: TimeInterval = clearDelay
    ) {
        pasteboard.prepareForNewContents(with: secretPasteboardOptions)
        // Hint to clipboard managers that this is sensitive.
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        guard autoClear else { return }
        // Carry the pasteboard's *name* into the delayed closure, not the object:
        // `NSPasteboard` is not `Sendable`, and re-resolving by name yields the
        // same pasteboard.
        let name = pasteboard.name
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Only clear if the pasteboard still holds our secret, so a value the
            // user copied in the meantime survives.
            let pasteboard = NSPasteboard(name: name)
            if pasteboard.string(forType: .string) == secret {
                pasteboard.clearContents()
            }
        }
    }
}
