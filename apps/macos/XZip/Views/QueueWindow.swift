import SwiftUI
import AppKit

/// The Operations queue, shown as a popover anchored to the toolbar queue
/// button (replaces the old separate Queue window; mockup 1f/3e). Lists
/// running, waiting, failed (with Retry), and completed (with Reveal)
/// operations.
struct QueuePopover: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.operations.isEmpty {
                emptyState
            } else {
                // ScrollView (not List) so the popover hugs its content:
                // few operations -> short popover, many -> caps at 420 and
                // scrolls. A List always claims the full frame height.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.operations) { op in
                            QueueRow(op: op, model: model)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Text("Queue").font(.headline)
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary)
            if model.operations.contains(where: { $0.state == .running }) {
                Button("Pause All") { model.pauseAllOperations() }
                    .controlSize(.small)
            }
            if model.operations.contains(where: { $0.state == .completed || $0.state == .cancelled }) {
                Button("Clear Done") { model.clearFinishedOperations() }
                    .controlSize(.small)
            }
        }
        .padding(XZIPSpace.md)
    }

    private var emptyState: some View {
        VStack(spacing: XZIPSpace.md) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No operations")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var summary: String {
        let running = model.operations.filter { $0.state == .running }.count
        let waiting = model.operations.filter { $0.state == .queued }.count
        return String(localized: "\(running) running · \(waiting) waiting")
    }
}

/// A single operation row with progress, and state-specific trailing controls.
private struct QueueRow: View {
    let op: ArchiveOperation
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.sm) {
            HStack(spacing: XZIPSpace.sm) {
                FileTypeIcon(ext: iconExt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.title).lineLimit(1)
                    // ETA / progress detail (mockup 3e "38 s left").
                    if op.state == .running, !op.currentItem.isEmpty {
                        Text(op.currentItem)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing
            }
            if op.state == .running {
                ProgressView(value: op.progress)
                    .progressViewStyle(.linear)
            }
            // Inline error banner with transcript (mockup 3e).
            if op.state == .failed, !op.detail.isEmpty {
                Text(op.detail)
                    .font(.caption)
                    .foregroundStyle(XZIPColor.danger)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, XZIPSpace.xs)
        .padding(.horizontal, XZIPSpace.md)
        .background(op.state == .failed
                    ? XZIPColor.danger.opacity(0.07)
                    : Color.clear)
    }

    /// Show the failure detail in an alert (mockup 3e "Show transcript").
    private func showTranscript() {
        let alert = NSAlert()
        alert.messageText = op.title
        alert.informativeText = op.detail.isEmpty ? "No details available." : op.detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    @ViewBuilder
    private var trailing: some View {
        switch op.state {
        case .running:
            // Labeled "Stop", not "Pause": there is no process suspend (SIGSTOP)
            // — this terminates 7zz and Restart re-runs from the beginning, so
            // "Pause/Resume" would falsely imply the progress is kept.
            Button("Stop") { model.pauseOperation(op.id) }
                .controlSize(.small)
                .help("Stop this operation. Its progress is discarded; Restart re-runs it from the beginning.")
            Button {
                model.cancel(op.id)
            } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Cancel this operation")
        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button("Retry") { model.retryOperation(op.id) }
                .controlSize(.small)
            Button("Show transcript") { showTranscript() }
                .controlSize(.small)
                .buttonStyle(.link)
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(XZIPColor.success)
            Button("Reveal") { model.revealOutput(for: op.id) }
                .controlSize(.small)
        case .paused:
            Button("Restart") { model.retryOperation(op.id) }
                .controlSize(.small)
                .help("Restart this operation from the beginning.")
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var iconExt: String {
        switch op.kind {
        case .compress: return "zip"
        case .extract: return "zip"
        case .test: return "zip"
        }
    }
}
