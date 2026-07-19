import SwiftUI

/// The single main window (mockup 1a/1c/2a): a `NavigationSplitView` whose
/// Places sidebar is hidden by default, a toolbar showing the current archive
/// identity + primary actions, and either the archive browser or the empty
/// state drop zone as the detail content.
struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            PlacesSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            Group {
                // Priority: folder-browsing (a Place was clicked) > open archive
                // > empty drop zone.
                if model.browsingFolder != nil {
                    FolderBrowserView(model: model)
                } else if model.hasOpenArchive {
                    ArchiveBrowserView(model: model)
                } else {
                    EmptyStateView(model: model)
                }
            }
            .frame(minWidth: 640, minHeight: 420)
            // Inline activity bar (visible only while operations run) so a
            // compress/extract started from a sheet is never silent.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActivityStatusBar(operations: model.operations) {
                    model.isQueuePopoverPresented = true
                }
            }
        }
        // Selecting an open archive in the sidebar leaves folder-browsing mode.
        .onChange(of: model.currentArchiveID) { _, newValue in
            if newValue != nil { model.browsingFolder = nil }
        }
        // When an archive is open, the rich principal toolbar header (icon +
        // name + subtitle, mockup 1a) is the single source of the title, so we
        // blank the inline navigation title to avoid showing the name twice.
        .navigationTitle(model.currentArchive == nil ? "XZip" : "")
        .toolbar {
            principalContent
            // Explicit search item instead of `.searchable`: SwiftUI always
            // pins the searchable field at the toolbar's trailing end (and
            // DefaultToolbarItem(kind: .search) does not reorder it in this
            // two-toolbar setup), so an NSSearchField item is the only way to
            // keep the queue button as the trailing-most item. Both live
            // outside the customizable "main" set on purpose: the queue button
            // is the popover's anchor (⌘0, status bar, compress auto-open) and
            // must not be hideable.
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $model.searchText)
                    .frame(width: 230)
            }
            ToolbarItem(placement: .primaryAction) {
                QueueToolbarButton(model: model)
            }
        }
        .toolbar(id: "main") { toolbarContent }
        .sheet(isPresented: $model.isCompressSheetPresented) {
            CompressSheet(model: model)
        }
        .sheet(isPresented: $model.isPasswordPromptPresented) {
            PasswordPromptSheet(model: model)
        }
        .sheet(item: $model.pendingSplitDetection) { detection in
            JoinPartsSheet(model: model, detection: detection)
        }
        .sheet(item: $model.pendingConflict) { prompt in
            ConflictDialog(prompt: prompt)
        }
        .sheet(item: $model.shareArchive) { info in
            SuccessShareCard(info: info)
        }
        .sheet(item: $model.activeRepack) { state in
            RepackProgressSheet(model: model, initialState: state)
        }
        .sheet(item: $model.newItemRequest) { request in
            NewItemSheet(request: request) { name in
                model.createNewItem(kind: request.kind, name: name)
            }
        }
        // Custom sheet instead of `.alert`: backend errors can be long
        // multi-line tool output, which stretched the alert vertically —
        // the sheet caps the message height and scrolls instead.
        .sheet(isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            ErrorDialog(message: model.errorMessage ?? "") { model.errorMessage = nil }
        }
        // Let the menu bar's ⌘W know this window is key (see XZIPCommands).
        .focusedSceneValue(\.mainWindowModel, model)
        // Apply the "When XZip opens" preference. Runs after onAppear (which
        // flushes any cold-launch file opens into the model), so the guard in
        // applyStartupLocation sees an opened archive and correctly no-ops.
        .task { model.applyStartupLocation() }
    }

    // NOTE: NavigationSplitView already provides its own sidebar-toggle button
    // (standard "Toggle Sidebar", ⌃⌘S), so we don't add a custom one.

    /// The archive identity header (icon + name + subtitle, mockup 1a). Kept in
    /// a plain toolbar because principal items are not user-customizable.
    @ToolbarContentBuilder
    private var principalContent: some ToolbarContent {
        if let archive = model.currentArchive {
            // macOS 26 (Liquid Glass) wraps every toolbar item in a rounded
            // glass "capsule"; for this text-only identity header that reads as
            // an unwanted white pill, so opt it out of the shared background.
            if #available(macOS 26.0, *) {
                archiveHeaderItem(archive)
                    .sharedBackgroundVisibility(.hidden)
            } else {
                archiveHeaderItem(archive)
            }
        }
    }

    /// The archive identity header item. `.navigation` places it on the leading
    /// edge (after the sidebar toggle) so the identity is left-aligned, not
    /// centered like `.principal` would render it.
    private func archiveHeaderItem(_ archive: OpenArchive) -> some CustomizableToolbarContent {
        ToolbarItem(id: "archiveHeader", placement: .navigation) {
            HStack(spacing: XZIPSpace.sm) {
                FileTypeIcon(ext: (archive.name as NSString).pathExtension, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(archive.name).font(.headline)
                    Text(subtitle(for: archive))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, XZIPSpace.sm)
        }
    }

    /// The customizable action items. With `.toolbar(id:)` + `ToolbarItem(id:)`,
    /// macOS lets the user reorder / show / hide these via "Customize Toolbar…"
    /// and persists the layout. Because the item set must be static, each item
    /// enables/disables by context instead of appearing/disappearing.
    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        // Keep the item in the (static) customizable set at all times — moving a
        // ToolbarItem in/out of the set with an OUTER `if` corrupts the saved
        // toolbar layout. Render it empty at the start screen so it's hidden (not
        // a grayed-out copy), per this view's static-set invariant.
        ToolbarItem(id: "start", placement: .navigation) {
            if model.browsingFolder != nil || model.hasOpenArchive {
                Button {
                    model.goToStart()
                } label: {
                    Label("Start", systemImage: "square.grid.2x2")
                        .imageScale(.large)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .help("Back to the drop zones")
            }
        }

        ToolbarItem(id: "add", placement: .primaryAction) {
            Button {
                addFiles()
            } label: { Label("Add", systemImage: "plus").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Add files to this archive")
            .disabled(!model.canModifyCurrentArchive)
        }

        ToolbarItem(id: "newFolder", placement: .primaryAction) {
            Button {
                model.beginNewItem(.folder)
            } label: { Label("New Folder", systemImage: "folder.badge.plus").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Create a new folder")
            .disabled(!model.canMakeNewItem)
        }

        ToolbarItem(id: "newFile", placement: .primaryAction) {
            Button {
                model.beginNewItem(.file)
            } label: { Label("New File", systemImage: "doc.badge.plus").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Create a new file")
            .disabled(!model.canMakeNewItem)
        }

        ToolbarItem(id: "extract", placement: .primaryAction) {
            Button {
                extractAll()
            } label: { Label("Extract", systemImage: "arrow.down.circle").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Extract all contents")
            .disabled(!model.canExtractCurrent)
        }

        ToolbarItem(id: "extractTo", placement: .primaryAction) {
            Menu {
                ForEach(model.places) { place in
                    Button {
                        model.extractCurrentArchive(to: place.url)
                    } label: { Label(place.name, systemImage: place.symbol) }
                }
                Divider()
                Button("Choose…") { chooseExtractDestination() }
            } label: {
                Label("Extract to", systemImage: "arrow.down.forward.square").padding(.horizontal, 4)
            }
            .menuStyle(.borderlessButton)
            .help("Extract to a specific destination")
            .disabled(!model.canExtractCurrent)
        }

        ToolbarItem(id: "test", placement: .primaryAction) {
            Button {
                model.testCurrentArchive()
            } label: { Label("Test", systemImage: "checkmark.shield").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Test archive integrity")
            .disabled(!model.hasOpenArchive)
        }

        ToolbarItem(id: "comment", placement: .primaryAction) {
            Button {
                if let url = model.currentArchive?.url {
                    model.commentTarget = CommentTarget(url: url)
                }
            } label: { Label("Comment", systemImage: "text.bubble").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("View the archive comment (editing: ZIP only)")
            .disabled(!model.canCommentCurrentArchive)
            .popover(item: $model.commentTarget) { target in
                ArchiveCommentPopover(model: model, archiveURL: target.url)
            }
        }

        ToolbarItem(id: "share", placement: .primaryAction) {
            Button {
                if let url = model.currentArchive?.url {
                    SharePicker.present([url])
                }
            } label: { Label("Share", systemImage: "square.and.arrow.up").padding(.horizontal, 4) }
            .buttonStyle(.plain)
            .help("Share this archive")
            .disabled(!model.hasOpenArchive)
        }

    }

    private func subtitle(for archive: OpenArchive) -> String {
        var parts = [
            String(localized: "\(archive.itemCount) items"),
            model.archiveTotalCompressedSize.xzipFileSize
        ]
        if archive.isEncrypted { parts.append(String(localized: "Encrypted")) }
        return parts.joined(separator: " · ")
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.addFilesToArchive(panel.urls)
        }
    }

    private func extractAll() {
        guard let archive = model.currentArchive?.url else { return }
        let destination = archive.deletingLastPathComponent()
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
        model.startExtraction(archive: archive, destination: destination)
    }

    /// Prompt for a destination folder, then extract the current archive there
    /// (toolbar "Extract to" → "Choose…").
    private func chooseExtractDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract"
        if panel.runModal() == .OK, let url = panel.url {
            model.extractCurrentArchive(to: url)
        }
    }
}

/// Error dialog shown for `AppModel.errorMessage`. The message area hugs short
/// texts but caps its height and becomes scrollable for long multi-line errors
/// (e.g. raw 7z output), keeping the dialog compact.
/// The toolbar queue button and its popover anchor: a plain icon when idle,
/// a Safari-Downloads-style progress ring with the active count while
/// operations run. A standalone view so Observation re-renders the label
/// whenever `model.operations` changes, independent of the toolbar host.
/// The toolbar search field, replacing `.searchable` so it can sit at an
/// explicit position (right before the queue button) instead of SwiftUI's
/// forced trailing-end placement. Styled after the system search capsule:
/// magnifier, clear button, and a contrasting rounded background so it
/// reads as a field against the toolbar material.
private struct ToolbarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.body)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct QueueToolbarButton: View {
    @Bindable var model: AppModel

    var body: some View {
        let active = ActivityStatus.active(in: model.operations)
        Button {
            model.isQueuePopoverPresented.toggle()
        } label: {
            Group {
                if active.isEmpty {
                    Label("Queue", systemImage: "list.bullet.circle")
                } else {
                    ZStack {
                        Circle()
                            .stroke(.quaternary, lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: ActivityStatus.batchProgress(of: model.operations))
                            .stroke(XZIPColor.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(active.count)")
                            .font(.caption2.monospacedDigit())
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Queue: \(active.count) operations running")
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help("Show the operations queue")
        .popover(isPresented: $model.isQueuePopoverPresented, arrowEdge: .bottom) {
            QueuePopover(model: model)
        }
    }
}

private struct ErrorDialog: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: XZIPSpace.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
            Text("Something went wrong")
                .font(.headline)
            ViewThatFits(in: .vertical) {
                messageText
                ScrollView { messageText }
            }
            .frame(maxHeight: 220)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(XZIPSpace.lg)
        .frame(width: 400)
        .onExitCommand { dismiss() }
    }

    private var messageText: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
