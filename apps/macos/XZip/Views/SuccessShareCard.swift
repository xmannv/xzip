import SwiftUI

/// Post-compression success card with a native share sheet (mockup 4c). Shows
/// the created archive's name/size and offers Mail, Messages, AirDrop, and
/// Copy-path via `ShareLink` / the system share picker.
struct SuccessShareCard: View {
    let info: ShareArchiveInfo
    @Environment(\.dismiss) private var dismiss

    private var archiveURL: URL { info.url }

    var body: some View {
        VStack(spacing: XZIPSpace.lg) {
            ZStack {
                Circle().fill(XZIPColor.success.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(XZIPColor.success)
            }

            VStack(spacing: XZIPSpace.xs) {
                Text("\(archiveURL.lastPathComponent) created").font(.headline)
                Text(detailLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: XZIPSpace.md) {
                ShareLink(item: archiveURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(archiveURL.path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 420)
    }

    /// "46.1 MB · 52% smaller · AES-256 · <folder>" (mockup 4c subtitle).
    private var detailLine: String {
        var parts = [info.sizeBytes.xzipFileSize]
        if let saved = info.savedPercent, saved > 0 {
            parts.append(String(localized: "\(saved)% smaller"))
        }
        if info.isEncrypted { parts.append(String(localized: "Encrypted")) }
        parts.append(archiveURL.deletingLastPathComponent().lastPathComponent)
        return parts.joined(separator: " · ")
    }
}
