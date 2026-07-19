import SwiftUI

/// Non-blocking file conflict resolution (mockup 3b). Driven by a pre-scan
/// `ConflictPrompt`: shows the existing file vs the incoming one, the number of
/// remaining conflicts, and an "Apply to all" toggle. The chosen policy applies
/// to the whole batch while the queue keeps running.
struct ConflictDialog: View {
    let prompt: ConflictPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\u{201C}\(prompt.firstConflict)\u{201D} already exists")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // EXISTING vs FROM ARCHIVE comparison cards.
            HStack(spacing: XZIPSpace.md) {
                comparisonCard(
                    title: String(localized: "EXISTING"),
                    size: prompt.existingSize,
                    modified: prompt.existingModified,
                    highlighted: false)
                comparisonCard(
                    title: String(localized: "FROM ARCHIVE"),
                    size: nil,
                    modified: nil,
                    highlighted: true)
            }

            HStack {
                Button("Skip") { resolve(.skip) }
                Button("Keep Both") { resolve(.keepBoth) }
                Spacer()
                Button("Replace", role: .destructive) { resolve(.replace) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(XZIPSpace.sheetPadding)
        .frame(width: 520)
    }

    @ViewBuilder
    private func comparisonCard(
        title: String, size: Int64?, modified: Date?, highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: XZIPSpace.sm) {
            // No "— NEWER" suffix: ConflictPrompt carries no archive-side mtime,
            // so claiming the incoming file is newer would be false (and lead the
            // user to overwrite a locally-newer file). The accent color/border
            // already marks this as the incoming "from archive" card.
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(highlighted ? XZIPColor.accent : .secondary)
            HStack(spacing: XZIPSpace.sm) {
                FileTypeIcon(ext: (prompt.firstConflict as NSString).pathExtension, size: 24)
                Text(prompt.firstConflict).font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(sizeLine(size: size, modified: modified))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(XZIPSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(XZIPColor.contentBackground, in: RoundedRectangle(cornerRadius: XZIPRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: XZIPRadius.card)
                .stroke(highlighted ? XZIPColor.accent : XZIPColor.separator,
                        lineWidth: highlighted ? 2 : 1)
        }
    }

    private func sizeLine(size: Int64?, modified: Date?) -> String {
        var parts: [String] = []
        if let size { parts.append(size.xzipFileSize) }
        if let modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? String(localized: "In archive") : parts.joined(separator: " · ")
    }

    /// The chosen policy applies to the whole extraction batch (a single 7zz
    /// invocation uses one overwrite mode), so the copy states that plainly
    /// rather than implying per-file prompting the engine can't do.
    private var subtitle: String {
        prompt.totalConflicts > 1
            ? String(localized: "Your choice applies to all \(prompt.totalConflicts) conflicts in this extraction.")
            : String(localized: "Choose how to handle it.")
    }

    private func resolve(_ policy: ConflictPolicy) {
        // A single extraction runs one overwrite policy for the whole batch.
        prompt.resolve(policy, true)
        dismiss()
    }
}
