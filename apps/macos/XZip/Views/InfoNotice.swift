import SwiftUI

/// Transient strip for `AppModel.infoMessage`: an operation that completed or was
/// deliberately abandoned, where nothing failed and there is nothing to decide.
///
/// A dialog would be wrong for this — it demands a click to acknowledge news the
/// user already expects. But the message does have to appear somewhere: without a
/// surface, "cancelled, nothing changed" is indistinguishable from the app quietly
/// dropping the request.
///
/// Modelled on `ExtractionFallbackNotice`: same `.background(.bar)`, same top
/// `Divider`, and it renders nothing when there is nothing to say.
struct InfoNotice: View {
    let message: String?
    let dismiss: () -> Void

    /// How long the strip stays up before clearing itself.
    ///
    /// Long enough to read a sentence, short enough not to linger over the next
    /// thing the user does. The timer is keyed on the message below, so a second
    /// message restarts it rather than inheriting the first one's remaining time.
    private static let visibleDuration = Duration.seconds(6)

    var body: some View {
        if let message {
            HStack(spacing: XZIPSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: XZIPSpace.sm)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss message")
                .accessibilityIdentifier("info-notice-dismiss")
            }
            .padding(.horizontal, XZIPSpace.md)
            .padding(.vertical, XZIPSpace.sm)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            // Announced so the outcome reaches VoiceOver users too: this strip is
            // the only report that a cancelled operation left everything alone.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("info-notice")
            // `id:` restarts the task when the message changes, so consecutive
            // messages each get their full time instead of the second one being
            // cut short by the first one's timer.
            .task(id: message) {
                do {
                    try await Task.sleep(for: Self.visibleDuration)
                } catch {
                    // Cancelled because the message changed or the view went
                    // away; whoever replaced it owns the new timer.
                    return
                }
                dismiss()
            }
        }
    }
}
