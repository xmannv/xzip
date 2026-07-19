import SwiftUI
import XZIPCore

/// Split-archive join sheet (mockup 4b): shown when the user opens one part of a
/// multi-volume set. Lists the detected parts (and any missing ones) and offers
/// to join them, optionally opening the result afterward.
struct JoinPartsSheet: View {
    @Bindable var model: AppModel
    let detection: SplitArchiveJoiner.DetectionResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            HStack(spacing: XZIPSpace.md) {
                FileTypeIcon(ext: (detection.baseName as NSString).pathExtension, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split archive detected").font(.headline)
                    Text("You opened one part of \u{201C}\(detection.baseName)\u{201D}. "
                         + "\(detection.foundParts.count) part(s) were found in the same folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            partsList

            if !detection.missingParts.isEmpty {
                Label(
                    "Missing part(s): \(detection.missingParts.map(String.init).joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(XZIPColor.warning)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join Only") { join(open: false) }
                    .disabled(!detection.isComplete)
                Button("Join & Open") { join(open: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!detection.isComplete)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 460)
    }

    private var partsList: some View {
        VStack(spacing: 0) {
            ForEach(detection.foundParts, id: \.self) { part in
                HStack(spacing: XZIPSpace.sm) {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    Text(part.lastPathComponent)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(XZIPColor.success)
                }
                .padding(.vertical, XZIPSpace.sm)
                .padding(.horizontal, XZIPSpace.md)
                Divider()
            }
        }
        .background(RoundedRectangle(cornerRadius: XZIPRadius.card).fill(Color.secondary.opacity(0.06)))
    }

    private func join(open: Bool) {
        let destination = detection.foundParts[0]
            .deletingLastPathComponent()
            .appendingPathComponent(detection.baseName)
        model.joinSplitParts(detection.foundParts, to: destination, openAfter: open)
        dismiss()
    }
}
