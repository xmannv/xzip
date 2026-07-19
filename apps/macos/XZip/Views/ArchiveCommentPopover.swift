import SwiftUI

/// Archive comment editor popover (mockup 4a). Reads the existing ZIP/RAR
/// comment and, for ZIP archives, lets the user edit and save it back.
struct ArchiveCommentPopover: View {
    @Bindable var model: AppModel
    let archiveURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var isLoading = true
    private var canEdit: Bool { model.service.canEditComment(for: archiveURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.md) {
            Text("ARCHIVE COMMENT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 72)
            } else {
                TextEditor(text: $comment)
                    .font(.body)
                    .frame(width: 320, height: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: XZIPRadius.card)
                            .stroke(XZIPColor.separator)
                    }
                    .disabled(!canEdit)
            }

            HStack {
                Text(canEdit
                     ? "Supports ZIP · shown when the recipient opens the archive"
                     : "Read-only for this format")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if canEdit {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(XZIPSpace.lg)
        .frame(width: 360)
        .task { await load() }
    }

    private func load() async {
        comment = (try? await model.service.readComment(for: archiveURL)) ?? ""
        isLoading = false
    }

    private func save() {
        Task {
            do {
                try await model.service.writeComment(comment, to: archiveURL)
                dismiss()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
