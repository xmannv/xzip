import SwiftUI
import UniformTypeIdentifiers
import XZIPCore

/// The empty state shown when no archive is open (mockup 1d): a dual drop zone —
/// left to compress dropped files, right to extract a dropped archive — plus a
/// recents list and the Dock hint.
struct EmptyStateView: View {
    @Bindable var model: AppModel
    @State private var compressTargeted = false
    @State private var extractTargeted = false
    /// Default compression format chosen inline at the drop zone (mockup 1d/3h).
    @AppStorage(XZIPDefaults.defaultFormat) private var defaultFormatRaw = CompressionFormat.zip.rawValue

    private var defaultFormat: CompressionFormat {
        CompressionFormat(rawValue: defaultFormatRaw) ?? .zip
    }

    var body: some View {
        ZStack {
            // Background drop catcher for the area outside the two zones,
            // layered BELOW them so each zone's own dropDestination keeps
            // priority while hovered.
            Color.clear
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    handleBackgroundDrop(urls)
                }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(XZIPColor.contentBackground)
    }

    private var content: some View {
        VStack(spacing: XZIPSpace.lg) {
            HStack(spacing: XZIPSpace.lg) {
                compressZone
                extractZone
            }
            // Equal-height cards: each zone stretches to the tallest sibling
            // (the compress zone carries an extra format chip) instead of
            // keeping its own intrinsic height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(XZIPSpace.lg)

            if !recents.isEmpty {
                recentsList
            }

            Spacer()

            brandBlock

            Spacer()

            Text("Tip: dragging onto the Dock icon works too — no window needed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, XZIPSpace.lg)
        }
    }


    // MARK: - Brand

    /// Brand lockup centered in the otherwise-empty area between the drop
    /// zones and the bottom tip.
    private var brandBlock: some View {
        VStack(spacing: XZIPSpace.sm) {
            // The real app icon, so the lockup always matches the brand asset.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, XZIPSpace.xs)
            Text("XZIP")
                .font(.title3.weight(.bold))
                .tracking(2)
        }
        .accessibilityElement(children: .combine)
    }

    /// Route a drop that landed outside both zones.
    private func handleBackgroundDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        var openedArchives = 0
        var handled = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            handled = true
            // Split parts (x.7z.001) infer no format but must route like the
            // Dock drop does: offer to join, then open.
            let isArchive = ArchiveFormat.infer(fromFilename: url.lastPathComponent) != nil
                || model.service.detectSplit(part: url) != nil
            if !isDirectory.boolValue, isArchive {
                model.handlePossibleSplitArchive(url)
                model.openArchive(url)
                openedArchives += 1
            } else if isDirectory.boolValue {
                model.browseFolder(url)
            } else {
                // Plain file: browse its parent folder and select it there.
                model.browseFolder(url.deletingLastPathComponent())
                model.selectedFolderItemIDs = [url]
            }
        }
        if openedArchives > 0 { model.revealSidebarForMultipleArchives() }
        return handled
    }

    // MARK: - Compress drop zone (left)

    private var compressZone: some View {
        dropZone(
            targeted: compressTargeted,
            accent: true,
            symbol: "arrow.down",
            title: "Drop files to compress",
            subtitle: "or click to browse",
            accessory: AnyView(formatChip)
        )
        .onTapGesture { chooseFilesToCompress() }
        .dropDestination(for: URL.self) { urls, _ in
            model.beginCompress(with: urls)
            return true
        } isTargeted: { compressTargeted = $0 }
    }

    /// Inline "into ZIP ▾" format picker at the compress drop zone (mockup 1d/3h).
    private var formatChip: some View {
        Menu {
            ForEach(CompressionFormat.compressChoices) { fmt in
                Button(fmt.rawValue) { defaultFormatRaw = fmt.rawValue }
            }
        } label: {
            Text("into \(defaultFormat.rawValue)")
                .font(.caption)
                .padding(.horizontal, XZIPSpace.md)
                .padding(.vertical, XZIPSpace.xs)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Extract drop zone (right)

    private var extractZone: some View {
        dropZone(
            targeted: extractTargeted,
            accent: false,
            symbol: "arrow.up",
            title: "Drop an archive to extract",
            subtitle: "ZIP · 7Z · RAR · TAR · GZ · DMG · ISO\nand more formats"
        )
        .onTapGesture { chooseArchiveToOpen() }
        .dropDestination(for: URL.self) { urls, _ in
            // Open every dropped archive, not just the first (the rest were
            // silently ignored). Non-archive drops are skipped.
            let archives = urls.filter {
                ArchiveFormat.infer(fromFilename: $0.lastPathComponent) != nil
            }
            guard !archives.isEmpty else { return false }
            for url in archives { model.openArchive(url) }
            return true
        } isTargeted: { extractTargeted = $0 }
    }

    private func dropZone(
        targeted: Bool,
        accent: Bool,
        symbol: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        accessory: AnyView? = nil
    ) -> some View {
        VStack(spacing: XZIPSpace.md) {
            ZStack {
                Circle()
                    .fill((accent ? XZIPColor.accent : Color.secondary).opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent ? XZIPColor.accent : .secondary)
            }
            Text(title).font(.headline)
            if let accessory {
                accessory
                    .background(XZIPColor.contentBackground, in: Capsule())
                    .overlay(Capsule().stroke(XZIPColor.separator))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, XZIPSpace.lg)
        .background {
            RoundedRectangle(cornerRadius: XZIPRadius.sheet, style: .continuous)
                .fill((accent ? XZIPColor.accent : Color.clear).opacity(accent ? 0.04 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: XZIPRadius.sheet, style: .continuous)
                .strokeBorder(
                    (accent ? XZIPColor.accent : Color.secondary).opacity(targeted ? 0.9 : 0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
    }

    // MARK: - Recents

    private var recents: [URL] {
        model.recentDocuments
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: XZIPSpace.sm) {
            HStack {
                Text("Recents")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear all") { model.clearRecents() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(recents.prefix(5), id: \.self) { url in
                Button {
                    model.openArchive(url)
                } label: {
                    HStack(spacing: XZIPSpace.sm) {
                        NativeFileIcon(url: url)
                        Text(url.lastPathComponent)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove") { model.removeRecent(url) }
                }
            }
        }
        .padding(.horizontal, XZIPSpace.lg * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    // MARK: - Pickers

    private func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.beginCompress(with: panel.urls)
        }
    }

    private func chooseArchiveToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openArchive(url)
        }
    }
}
