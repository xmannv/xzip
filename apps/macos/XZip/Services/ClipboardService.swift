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
    private static let clearDelay: TimeInterval = 30

    static let secretPasteboardOptions: NSPasteboard.ContentsOptions =
        .currentHostOnly

    /// Copy `secret` to the pasteboard. If `autoClear` is true, schedule a wipe
    /// after 30s (only if the value is unchanged).
    static func copySecret(_ secret: String, autoClear: Bool) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: secretPasteboardOptions)
        // Hint to clipboard managers that this is sensitive.
        pb.setString(secret, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        guard autoClear else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) {
            // Only clear if the pasteboard still holds our secret.
            if NSPasteboard.general.string(forType: .string) == secret {
                NSPasteboard.general.clearContents()
            }
        }
    }
}
