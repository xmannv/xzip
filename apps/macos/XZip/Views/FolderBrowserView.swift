import SwiftUI
import UniformTypeIdentifiers

/// The Places folder browser (mockup 2a, BetterZip-style): a Finder-like view of
/// a favorite folder on disk. Double-click descends into folders, opens archives
/// in the archive browser, or hands other files to the default app. A toolbar
/// row offers Back / Up navigation and "Compress" for the current selection.
struct FolderBrowserView: View {
    @Bindable var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\FileItem.name)]
    @AppStorage(XZIPDefaults.foldersFirst) private var foldersFirst = true
    /// Item currently previewed via Quick Look (Space). File items are real
    /// on-disk URLs, so no extraction is needed.
    @State private var quickLookURL: URL?
    /// File-type filter applied on top of the folder listing (session-only,
    /// like Finder — not persisted).
    @State private var typeFilter: FolderBrowsing.FileTypeFilter = .all

    private var items: [FileItem] {
        var base = typeFilter == .all
            ? model.folderItems
            : model.folderItems.filter { typeFilter.matches($0) }
        // Mirror the archive browser: the toolbar search field narrows the
        // listing to matching names (current folder only).
        if !model.searchText.isEmpty {
            base = base.filter { $0.name.localizedCaseInsensitiveContains(model.searchText) }
        }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            itemsTable
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Dropping files onto the browser seeds a compression of them.
            guard !urls.isEmpty else { return false }
            model.compressionInputs = urls.map { InputItem(url: $0) }
            model.isCompressSheetPresented = true
            return true
        }
        // Re-sort in place when the folders-first preference changes.
        .onChange(of: foldersFirst) { _, _ in model.refreshFolder() }
    }

    // MARK: - Navigation bar (Back / Up + path + Compress)

    private var navigationBar: some View {
        HStack(spacing: XZIPSpace.sm) {
            Button {
                model.folderGoBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canFolderGoBack)
            .help("Back")

            Button {
                model.folderGoUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Enclosing folder")

            folderBreadcrumbs

            Spacer()

            filterMenu

            Button {
                model.compressFolderSelection()
            } label: {
                Label("Compress", systemImage: "archivebox")
            }
            .help(model.selectedFolderItemIDs.isEmpty
                  ? "Compress all items in this folder"
                  : "Compress the selected items")
        }
        .padding(.horizontal, XZIPSpace.lg)
        .padding(.vertical, XZIPSpace.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// File-type filter menu. The icon fills and tints when a filter other
    /// than "All Files" is active so the narrowed listing is noticeable.
    private var filterMenu: some View {
        Menu {
            Picker("File Type", selection: $typeFilter) {
                ForEach(FolderBrowsing.FileTypeFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: typeFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(typeFilter == .all ? Color.primary : Color.accentColor)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by file type")
    }

    /// Clickable breadcrumb trail (Place root → current folder). The last crumb
    /// is the current folder and isn't tappable. Scrolls if the trail is long.
    private var folderBreadcrumbs: some View {
        BreadcrumbTrail(items: breadcrumbItems, font: .headline)
    }

    /// Map the on-disk Place trail into breadcrumb items. Every crumb is a real
    /// folder, so all get a Copy Path menu (`copyValue` = the filesystem path).
    private var breadcrumbItems: [BreadcrumbItem] {
        let crumbs = model.folderBreadcrumbs
        return crumbs.enumerated().map { index, url in
            BreadcrumbItem(
                id: index,
                label: url.lastPathComponent,
                isCurrent: index == crumbs.count - 1,
                copyValue: url.path,
                navigate: { model.navigateToDiskFolder(url) })
        }
    }

    // MARK: - Items table (4-column, Finder-style)

    private var itemsTable: some View {
        Table(items, selection: $model.selectedFolderItemIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: XZIPSpace.sm) {
                    NativeFileIcon(url: item.url, isFolder: item.isDirectory)
                    Text(item.name)
                    if FolderBrowsing.isArchive(item) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Open this archive")
                    }
                }
            }
            TableColumn("Size", value: \.sizeBytes) { item in
                Text(item.isDirectory ? "--" : item.sizeBytes.xzipFileSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Kind", value: \.ext) { item in
                Text(LocalizedStringKey(item.isDirectory ? "Folder" : (item.ext.isEmpty ? "File" : item.ext.uppercased())))
                    .foregroundStyle(.secondary)
            }
            .width(120)
            TableColumn("Modified", value: \.modifiedAt) { item in
                Text(item.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .quickLookPreview($quickLookURL)
        // Persistent Space shortcut for Quick Look. Uses `.onKeyPress` at the
        // container level (same proven pattern as ArchiveBrowserView): a
        // `.keyboardShortcut` on a context-menu button only registers while the
        // menu is open, so Space previously did nothing.
        .onKeyPress(.space) {
            quickLookSelection()
            return .handled
        }
        // `contextMenu(forSelectionType:)` reliably handles BOTH right-click
        // menus and double-click (primaryAction) on a SwiftUI Table, unlike a
        // per-row `.onTapGesture` which the Table intercepts.
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            rowContextMenu(for: resolve(ids))
        } primaryAction: { ids in
            // Double-click: open a single item; open the first of a multi-set.
            if let item = resolve(ids).first { model.openFileItem(item) }
        }
        .onChange(of: sortOrder) { _, newValue in
            // Bridge the Table's sort UI (column + direction) onto the model.
            if let key = newValue.first {
                let ascending = key.order == .forward
                switch key.keyPath {
                case \FileItem.name: model.setFolderSort(.name, ascending: ascending)
                case \FileItem.sizeBytes: model.setFolderSort(.size, ascending: ascending)
                case \FileItem.ext: model.setFolderSort(.kind, ascending: ascending)
                case \FileItem.modifiedAt: model.setFolderSort(.modified, ascending: ascending)
                default: break
                }
            }
        }
        // Drop hidden items from the selection when the filter narrows, so
        // actions like Compress never operate on rows the user can't see.
        .onChange(of: typeFilter) { _, _ in
            model.selectedFolderItemIDs.formIntersection(Set(items.map(\.id)))
        }
        .overlay {
            if items.isEmpty && !model.folderItems.isEmpty {
                ContentUnavailableView(
                    "No \(typeFilter.label)",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No items of this type in this folder."))
            }
        }
    }

    /// Resolve a set of selection IDs back into `FileItem`s, preserving the
    /// current display order.
    private func resolve(_ ids: Set<FileItem.ID>) -> [FileItem] {
        items.filter { ids.contains($0.id) }
    }

    /// Quick Look the first non-folder in the current selection (Space key).
    private func quickLookSelection() {
        if let file = resolve(model.selectedFolderItemIDs).first(where: { !$0.isDirectory }) {
            quickLookURL = file.url
        }
    }

    // MARK: - Row context menu (right-click)

    @ViewBuilder
    private func rowContextMenu(for selection: [FileItem]) -> some View {
        if selection.isEmpty {
            // Right-click on empty space: act on the whole folder.
            Button("Compress All…") { model.compressItems(model.folderItems) }
        } else if selection.count == 1, let item = selection.first {
            singleItemMenu(for: item)
        } else {
            Button("Compress \(selection.count) Items…") { model.compressItems(selection) }
            Divider()
            Button("Share \(selection.count) Items…") { SharePicker.present(selection.map(\.url)) }
            Button("Copy Paths") { copyPaths(selection) }
            Button("Reveal in Finder") { model.revealInFinder(selection) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(selection) }
        }
    }

    @ViewBuilder
    private func singleItemMenu(for item: FileItem) -> some View {
        if !item.isDirectory {
            Button("Quick Look") { quickLookURL = item.url }
        }
        if item.isDirectory {
            Button("Open") { model.openFileItem(item) }
            Button("Compress…") { model.compressItems([item]) }
        } else if FolderBrowsing.isArchive(item) {
            Button("Open") { model.openFileItem(item) }
            Button("Extract Here") {
                model.extractItem(item, to: model.browsingFolder)
            }
            Button("Extract…") { model.extractItem(item, to: nil) }
            Divider()
            Button("Compress…") { model.compressItems([item]) }
        } else {
            Button("Open with Default App") { model.openFileItem(item) }
            Menu("Open With") {
                ForEach(OpenWithService.apps(for: item.url)) { app in
                    Button {
                        OpenWithService.open(item.url, withApplicationAt: app.url)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
                Divider()
                Button("Other…") { OpenWithService.chooseAppAndOpen(item.url) }
            }
            Button("Compress…") { model.compressItems([item]) }
        }
        Divider()
        Button("Share…") { SharePicker.present([item.url]) }
        Button("Copy Path") { copyPaths([item]) }
        Button("Reveal in Finder") { model.revealInFinder([item]) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.moveToTrash([item]) }
    }

    /// Copy the on-disk path(s) of the given items, one per line.
    private func copyPaths(_ items: [FileItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: XZIPSpace.xs) {
            let folders = items.filter(\.isDirectory).count
            let files = items.count - folders
            Text("\(folders) folders")
            Text("·")
            Text("\(files) files")
            if !model.selectedFolderItemIDs.isEmpty {
                Text("·")
                Text("\(model.selectedFolderItemIDs.count) selected")
            }
            if typeFilter != .all {
                Text("·")
                Text("filtered from \(model.folderItems.count)")
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
}
