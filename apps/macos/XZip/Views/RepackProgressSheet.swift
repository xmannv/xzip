import SwiftUI
import XZIPCore

/// Step-by-step progress for adding files to a compressed tarball (tar.gz, …).
/// These formats can't be updated in place, so XZip repacks them; this sheet
/// explains that and shows which stage is running. Presented via
/// `.sheet(item:)` from `MainWindowView` and not dismissible by clicking away —
/// the only exits are completion or Cancel.
struct RepackProgressSheet: View {
    @Bindable var model: AppModel
    /// Snapshot from `.sheet(item:)`; only used as a fallback while the sheet
    /// is animating out after `activeRepack` goes nil.
    let initialState: RepackState

    /// Live state read straight from the model so step changes always
    /// re-render (`.sheet(item:)` alone doesn't reliably push mutations).
    private var state: RepackState { model.activeRepack ?? initialState }

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            HStack(spacing: XZIPSpace.sm) {
                FileTypeIcon(ext: (state.archiveName as NSString).pathExtension, size: 26)
                Text("Updating \(state.archiveName)")
                    .font(.headline)
            }

            Text("This format can't be edited in place, so XZip is repacking the whole archive.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: XZIPSpace.sm) {
                ForEach(RepackStep.allCases, id: \.self) { step in
                    stepRow(step)
                }
            }

            HStack {
                Text("The original archive stays untouched if anything fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(state.isCancelling ? "Cancelling…" : "Cancel") {
                    model.cancelRepack()
                }
                // Esc cancels the repack (the sheet itself can't be dismissed).
                .keyboardShortcut(.cancelAction)
                .disabled(state.isCancelling)
            }
        }
        .padding(XZIPSpace.lg)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private func stepRow(_ step: RepackStep) -> some View {
        HStack(spacing: XZIPSpace.sm) {
            if step < state.step {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(XZIPColor.accent)
            } else if step == state.step {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
            }
            Text(label(for: step))
                .foregroundStyle(step <= state.step ? .primary : .secondary)
        }
    }

    private func label(for step: RepackStep) -> String {
        switch step {
        case .decompress: String(localized: "Unpacking to .tar")
        case .addFiles: String(localized: "Adding \(state.fileCount) items")
        case .recompress: String(localized: "Recompressing")
        }
    }
}
