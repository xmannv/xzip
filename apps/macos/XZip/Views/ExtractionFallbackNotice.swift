import SwiftUI

/// Passive strip shown while safe extraction is unavailable.
///
/// Extraction remains blocked until the transactional runtime finishes crash
/// recovery and becomes available, because no backend may mutate the final
/// destination directly.
///
/// Deliberately modelled on `ActivityStatusBar`: same `.background(.bar)` and
/// top `Divider`, and it renders nothing when there is nothing to report.
struct ExtractionFallbackNotice: View {
    let reason: String?
    let retry: () -> Void
    let dismiss: () -> Void

    @State private var isShowingDetail = false

    var body: some View {
        if let reason {
            HStack(spacing: XZIPSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(XZIPColor.warning)
                    .accessibilityHidden(true)
                Text("Safe extraction is unavailable")
                    .font(.caption)
                    .lineLimit(1)
                Text("No files will be changed until protected extraction is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: XZIPSpace.sm)
                Button("Details") { isShowingDetail = true }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("extraction-fallback-details")
                Button("Try Again", action: retry)
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("extraction-fallback-retry")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss extraction warning")
                .accessibilityIdentifier("extraction-fallback-dismiss")
            }
            .padding(.horizontal, XZIPSpace.md)
            .padding(.vertical, XZIPSpace.sm)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            // The underlying reason is a developer-facing description, so it is
            // kept out of the bar itself and shown only on request.
            .alert("Safe extraction is unavailable", isPresented: $isShowingDetail) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    """
                    The transactional extraction stack couldn’t start. Extraction \
                    is blocked so no backend can modify the final destination \
                    without rollback and crash-recovery protection.

                    \(reason)
                    """
                )
            }
        }
    }
}
