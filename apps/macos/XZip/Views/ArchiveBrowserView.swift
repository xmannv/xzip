import SwiftUI
import UniformTypeIdentifiers
import QuickLook

/// The main archive contents browser: a Finder-style 4-column table of entries
/// with a status bar, drag-out/drop-in, Quick Look on Space, and the full
/// row context menu from mockup 5a.
struct ArchiveBrowserView: View {
    @Bindable var model: AppModel
    /// Entry currently previewed via Quick Look (Space), if any.
    @State private var quickLookURL: URL?
    @State private var sortOrder = [KeyPathComparator(\ArchiveEntry.name)]
    @State private var renamingEntry: ArchiveEntry?
    @State private var renameText = ""
    @AppStorage(XZIPDefaults.foldersFirst) private var foldersFirst = true

    /// True while the user is searching (filters across the whole archive).
    private var isSearching: Bool { !model.searchText.isEmpty }

    /// Filtered + sorted rows shown in the table. Memoized in `@State` and
    /// refreshed only when something it depends on changes (see `entriesKey`),
    /// NOT on every body render — otherwise selecting a row or typing in search
    /// re-sorted the entire archive (O(n log n) with a localized comparator) on
    /// a 100k-entry listing.
    @State private var entries: [ArchiveEntry] = []

    private struct EntriesKey: Equatable {
        let version: Int
        let search: String
        let folder: String
        let sort: String
        let foldersFirst: Bool
    }

    /// A cheap Equatable summary of every input `entries` derives from.
    private var entriesKey: EntriesKey {
        EntriesKey(
            version: model.archiveEntriesVersion,
            search: model.searchText,
            folder: model.currentFolderPath,
            sort: String(describing: sortOrder),
            foldersFirst: foldersFirst)
    }

    private func recomputeEntries() {
        let base = isSearching
            ? model.archiveEntries.filter { $0.name.localizedCaseInsensitiveContains(model.searchText) }
            : model.visibleEntries
        let sorted = base.sorted(using: sortOrder)
        // When enabled, hoist folders above files while preserving the column
        // sort order within each group (stable partition).
        entries = foldersFirst
            ? sorted.filter { model.isFolder($0) } + sorted.filter { !model.isFolder($0) }
            : sorted
    }

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb path bar (mockup 1b) — hidden while searching.
            if !isSearching {
                PathBarView(model: model)
            } else {
                searchResultsHeader
            }

            // While the archive is being listed (e.g. a DMG that must be attached
            // via `hdiutil`) and nothing has arrived yet, show a loading state so
            // the pane is never a silent blank. Once entries arrive the table
            // replaces it, even if a background refresh is still running.
            if model.isLoadingEntries && model.archiveEntries.isEmpty {
                loadingState
            } else {
                entriesTable
            }

            statusBar
        }
        // Cross-fade between the loading state and the populated table.
        .animation(.easeInOut(duration: 0.2), value: model.isLoadingEntries)
        .quickLookPreview($quickLookURL)
        .onKeyPress(.space) {
            Task { await previewSelection() }
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFilesToArchive(urls)
            return true
        }
        .sheet(item: $renamingEntry) { entry in
            renameSheet(for: entry)
        }
        // Recompute the memoized rows on first appearance and whenever an input
        // actually changes — but not on unrelated re-renders (e.g. selection).
        .task(id: entriesKey) { recomputeEntries() }
    }

    // MARK: - Loading state (slow-to-list archives, e.g. DMG attach)

    /// Shown while an archive is being listed and no entries have arrived yet.
    /// A centered spinner over the content background so opening a slow archive
    /// reads as "working" rather than a blank or frozen pane.
    private var loadingState: some View {
        VStack(spacing: XZIPSpace.md) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: XZIPSpace.xs) {
                Text("Opening \u{201C}\(model.currentArchive?.name ?? "archive")\u{201D}")
                    .font(.headline)
                Text("Reading contents…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(XZIPColor.contentBackground)
        .transition(.opacity)
    }

    // MARK: - Entries table (mockup 1a 4-column)

    private var entriesTable: some View {
        // `Table(of:selection:sortOrder:){columns}rows:` lets us attach a
        // row-level `.itemProvider` for drag-out-to-Finder = extract. Row-level
        // (not per-cell) drag is the key: it coexists with the Table's native
        // selection instead of hijacking the cell's mouse-down like a per-cell
        // `.onDrag` did.
        Table(of: ArchiveEntry.self, selection: $model.selectedArchiveEntryIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: XZIPSpace.sm) {
                    NativeFileIcon(ext: entry.ext, isFolder: model.isFolder(entry))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.name)
                        // Show the in-archive path while searching (mockup 3d).
                        if isSearching {
                            Text(entry.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.editSaveBack.activeEntryPaths.contains(entry.path) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(XZIPColor.accent)
                            .help("Editing — changes save back to the archive")
                    }
                }
                // Drag-out lives at the row level (see `.itemProvider` in the
                // `rows:` block below), not on this cell — a per-cell `.onDrag`
                // used to hijack the Table's mouse-down and break click-to-select.
            }
            TableColumn("Size", value: \.originalSize) { entry in
                Text(entry.originalSize.xzipFileSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Kind") { entry in
                Text(LocalizedStringKey(entry.ext.isEmpty ? "Folder" : entry.ext.uppercased()))
                    .foregroundStyle(.secondary)
            }
            .width(140)
            TableColumn("Modified", value: \.modifiedAt) { entry in
                Text(entry.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(140)
        } rows: {
            ForEach(entries) { entry in
                // Dragging a row to Finder extracts that entry: `dragProvider`
                // returns a file promise that unpacks the entry to a temp URL.
                // Dragging one of several selected rows drags the whole
                // selection, matching Finder behaviour.
                TableRow(entry)
                    .itemProvider { dragProvider(for: entry) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // A per-cell `.onTapGesture(count: 2)` swallows the Table's single-click
        // selection. Using the Table's own selection-based context menu handles
        // right-click AND double-click (primaryAction) without breaking clicks.
        .contextMenu(forSelectionType: ArchiveEntry.ID.self) { ids in
            let selected = resolve(ids)
            if !selected.isEmpty { rowContextMenu(for: selected) }
        } primaryAction: { ids in
            if let entry = resolve(ids).first { handleDoubleClick(entry) }
        }
    }

    /// Resolve selection IDs back into entries, preserving display order.
    private func resolve(_ ids: Set<ArchiveEntry.ID>) -> [ArchiveEntry] {
        // Resolve against the raw list, not the sorted/partitioned `entries`, so
        // a right-click or double-click doesn't re-sort the whole archive.
        model.archiveEntries.filter { ids.contains($0.id) }
    }

    // MARK: - Search results header (mockup 3d)

    private var searchResultsHeader: some View {
        HStack {
            Text("\(entries.count) results for \u{201C}\(model.searchText)\u{201D} — including subfolders")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, XZIPSpace.lg)
        .padding(.vertical, XZIPSpace.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Double-click + drag-out

    /// Descend into folders; preview files (mockup 1b navigation).
    private func handleDoubleClick(_ entry: ArchiveEntry) {
        if model.isFolder(entry) {
            let rel = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
            model.navigateToFolder(rel)
        } else {
            Task { await preview(entry) }
        }
    }

    /// Provide a file promise by extracting the entry to temp, so it can be
    /// dragged out to Finder = extract that single file (mockup 3c).
    private func dragProvider(for entry: ArchiveEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all
        ) { completion in
            Task {
                let url = await model.extractEntryToTemp(entry)
                completion(url, false, url == nil
                           ? NSError(domain: "XZip", code: 1) : nil)
            }
            return nil
        }
        return provider
    }

    // MARK: - Status bar (mockup 1a bottom row)

    private var statusBar: some View {
        HStack(spacing: XZIPSpace.xs) {
            let encrypted = model.currentArchive?.isEncrypted ?? false
            Text("\(model.archiveEntries.count) items")
            Text("·")
            Text("\(model.archiveTotalCompressedSize.xzipFileSize) compressed")
            Text("·")
            Text("\(model.archiveTotalOriginalSize.xzipFileSize) unpacked")
            if encrypted {
                Text("·")
                // Don't claim a specific cipher: the archive may use AES or the
                // weaker legacy ZipCrypto, which we can't tell apart from listing.
                Label("Encrypted", systemImage: "lock.fill")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, XZIPSpace.lg)
        .padding(.vertical, XZIPSpace.sm)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Row context menu (mockup 5a)

    /// Context menu for the current selection. Actions that only make sense for
    /// a single item (Quick Look, Rename, Edit, Get Info) are hidden when 2+ are
    /// selected; labels reflect the selection count.
    @ViewBuilder
    private func rowContextMenu(for entries: [ArchiveEntry]) -> some View {
        let isMulti = entries.count > 1
        let primary = entries[0]
        let ids = Set(entries.map(\.id))
        // Read-only formats (RAR, and the extract-only 7zz containers) can't be
        // modified, so the edit actions are hidden entirely — matching the
        // toolbar, which disables the same operations.
        let canModify = model.canModifyCurrentArchive

        Button(isMulti ? "Extract \(entries.count) Items" : "Extract \u{201C}\(primary.name)\u{201D}") {
            extractSelected(entries)
        }

        Menu("Extract to") {
            ForEach(Array(model.places.prefix(9).enumerated()), id: \.element.id) { index, place in
                Button {
                    model.extractToPlace(place, selectedEntries: entries.map(\.path))
                } label: {
                    Label(place.name, systemImage: place.symbol)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Same folder as archive") { extractSelected(entries) }
            Button("Choose…") { chooseDestinationAndExtract(entries) }
        }

        Divider()

        if !isMulti {
            Button("Quick Look") { Task { await preview(primary) } }
                .keyboardShortcut(.space, modifiers: [])
            Menu("Open With") {
                ForEach(OpenWithService.apps(forExtension: primary.ext)) { app in
                    Button {
                        openEntry(primary, withApp: app.url)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
                Divider()
                Button("Other…") { openEntryWithChosenApp(primary) }
            }
            if EditSaveBackService.canEdit(archive: model.currentArchive?.url ?? URL(fileURLWithPath: "/")) {
                Button("Edit & Save Back…") { beginEdit(primary) }
            }
            if canModify {
                Divider()
                Button("Rename") { startRename(primary) }
            }
        }

        Button(isMulti ? "Share \(entries.count) Items…" : "Share…") { shareEntries(entries) }

        if canModify {
            Button("New Folder from Selection") { model.newFolderFromSelection() }
        }
        if !isMulti {
            Button("Get Info") { showInfo(primary) }
        }

        if canModify {
            Divider()
            Button(isMulti ? "Delete \(entries.count) Items from Archive" : "Delete from Archive", role: .destructive) {
                model.selectedArchiveEntryIDs = ids
                model.deleteSelectedEntries()
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    // MARK: - Rename sheet

    private func renameSheet(for entry: ArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: XZIPSpace.lg) {
            Text("Rename Item").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { renamingEntry = nil }
                Button("Rename") {
                    model.renameEntry(entry.path, to: renameText)
                    renamingEntry = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.isEmpty)
            }
        }
        .padding(XZIPSpace.sheetPadding)
    }

    // MARK: - Actions

    /// Extract the given entries to the archive's own folder. Empty `entries`
    /// would extract everything, but callers always pass the selection.
    private func extractSelected(_ entries: [ArchiveEntry]) {
        guard let archive = model.currentArchive?.url else { return }
        model.startExtraction(
            archive: archive,
            destination: archive.deletingLastPathComponent(),
            selectedEntries: entries.map(\.path))
    }

    private func chooseDestinationAndExtract(_ entries: [ArchiveEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract"
        if panel.runModal() == .OK, let url = panel.url, let archive = model.currentArchive?.url {
            model.startExtraction(
                archive: archive, destination: url, selectedEntries: entries.map(\.path))
        }
    }

    private func previewSelection() async {
        // Set.first is unordered — with a multi-selection it would preview a
        // random entry. Pick the first SELECTED entry in the list's own order so
        // Space always previews the same, predictable one.
        guard let entry = model.archiveEntries.first(where: {
            model.selectedArchiveEntryIDs.contains($0.id)
        }) else { return }
        await preview(entry)
    }

    /// Show the entry's metadata (name, path, size, date) in an alert. Distinct
    /// from Quick Look, which previews the file's CONTENT — "Get Info" used to
    /// just re-run Quick Look, duplicating the item above it.
    private func showInfo(_ entry: ArchiveEntry) {
        let alert = NSAlert()
        alert.messageText = entry.name
        var lines = ["Path: \(entry.path)",
                     "Kind: \(entry.kind == .folder ? "Folder" : "File")"]
        if entry.kind != .folder {
            lines.append("Size: \(entry.originalSize.xzipFileSize)")
            if entry.compressedSize > 0 {
                lines.append("Compressed: \(entry.compressedSize.xzipFileSize)")
            }
        }
        lines.append("Modified: \(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }

    /// Extract a single entry to a temp dir and show it in Quick Look.
    private func preview(_ entry: ArchiveEntry) async {
        guard model.currentArchive?.url != nil else { return }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-ql-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await model.extractEntryForPreview(entry, to: tempDir) { url in
            self.quickLookURL = url
        }
    }

    /// Extract the entry to a temp file, then open it with a specific app.
    private func openEntry(_ entry: ArchiveEntry, withApp appURL: URL) {
        Task {
            if let fileURL = await model.extractEntryToTemp(entry) {
                OpenWithService.open(fileURL, withApplicationAt: appURL)
            }
        }
    }

    /// Extract the entry to a temp file, then prompt for an app (Finder's Other…).
    private func openEntryWithChosenApp(_ entry: ArchiveEntry) {
        Task {
            if let fileURL = await model.extractEntryToTemp(entry) {
                OpenWithService.chooseAppAndOpen(fileURL)
            }
        }
    }

    /// Extract the selected entries to temp, then present the native share sheet.
    private func shareEntries(_ entries: [ArchiveEntry]) {
        Task {
            let urls = await model.extractEntriesToTemp(entries)
            SharePicker.present(urls)
        }
    }

    private func beginEdit(_ entry: ArchiveEntry) {
        model.beginEditSaveBack(entry)
    }

    private func startRename(_ entry: ArchiveEntry) {
        renameText = entry.name
        renamingEntry = entry
    }

}
