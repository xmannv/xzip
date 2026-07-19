import SwiftUI

/// Breadcrumb path bar + quick "Extract to" destinations (mockup 1b).
///
/// The breadcrumb reflects the folder currently browsed inside the archive and
/// lets the user jump back up. The bottom row offers one-click extraction to
/// Downloads / Desktop / the archive's folder, a "Choose…" panel, and shows the
/// current selection count.
struct PathBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            extractToBar
        }
    }

    // MARK: - Breadcrumb (mockup 1b top)

    private var breadcrumb: some View {
        HStack(spacing: XZIPSpace.xs) {
            BreadcrumbTrail(items: breadcrumbItems)
            Spacer()
        }
        .padding(.horizontal, XZIPSpace.lg)
        .padding(.vertical, XZIPSpace.sm)
    }

    /// Map the in-archive path into trail items. Every crumb here is a virtual
    /// path *inside* the zip (the archive file itself, or a folder within it),
    /// not a real on-disk location, so NONE get a Copy Path menu
    /// (`copyValue: nil`). Copy Path is reserved for the Places folder browser,
    /// whose crumbs are real filesystem folders.
    private var breadcrumbItems: [BreadcrumbItem] {
        let crumbs = model.breadcrumbs
        return crumbs.enumerated().map { index, crumb in
            BreadcrumbItem(
                id: index,
                label: crumb.name,
                isCurrent: index == crumbs.count - 1,
                copyValue: nil,
                navigate: { model.navigateToFolder(crumb.path) })
        }
    }

    // MARK: - Extract-to quick destinations (mockup 1b bottom)

    private var extractToBar: some View {
        HStack(spacing: XZIPSpace.sm) {
            Text("Extract to:")
                .font(.caption)
                .foregroundStyle(.secondary)

            destinationChip("Downloads", url: .downloadsDirectory)
            destinationChip("Desktop", url: FileManager.default
                .urls(for: .desktopDirectory, in: .userDomainMask).first)
            destinationChip("Same folder", url: model.currentArchive?.url.deletingLastPathComponent())

            Button("Choose…") { chooseAndExtract() }
                .buttonStyle(.link)
                .font(.caption)

            Spacer()

            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, XZIPSpace.lg)
        .padding(.vertical, XZIPSpace.sm)
    }

    @ViewBuilder
    private func destinationChip(_ title: LocalizedStringKey, url: URL?) -> some View {
        Button {
            guard let url, let archive = model.currentArchive?.url else { return }
            model.startExtraction(archive: archive, destination: url)
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, XZIPSpace.md)
                .padding(.vertical, XZIPSpace.xs)
                .background(XZIPColor.contentBackground,
                            in: Capsule())
                .overlay(Capsule().stroke(XZIPColor.separator))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    private var selectionSummary: String {
        let count = model.selectedArchiveEntryIDs.count
        guard count > 0 else { return String(localized: "\(model.visibleEntries.count) items") }
        let bytes = ByteCountMath.sum(
            model.archiveEntries.lazy
                .filter { model.selectedArchiveEntryIDs.contains($0.id) }
                .map(\.originalSize)
        )
        return String(localized: "\(count) selected · \(bytes.xzipFileSize)")
    }

    private func chooseAndExtract() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract"
        if panel.runModal() == .OK, let url = panel.url, let archive = model.currentArchive?.url {
            model.startExtraction(archive: archive, destination: url)
        }
    }
}
