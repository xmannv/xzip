import SwiftUI

/// Thin bar pinned below the main-window content while operations are in
/// flight: aggregate progress + the current task, click to show the Queue
/// popover (same target as ⌘0). Renders nothing when the queue is idle.
struct ActivityStatusBar: View {
    let operations: [ArchiveOperation]
    let showQueue: () -> Void

    var body: some View {
        let active = ActivityStatus.active(in: operations)
        if !active.isEmpty {
            Button {
                showQueue()
            } label: {
                HStack(spacing: XZIPSpace.sm) {
                    ProgressView(value: ActivityStatus.overallProgress(of: active))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 160)
                    if active.count == 1, let op = active.first {
                        Text(op.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(op.currentItem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(active.count) operations running")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Show Queue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, XZIPSpace.md)
                .padding(.vertical, XZIPSpace.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
