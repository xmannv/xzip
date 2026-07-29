import SwiftUI

/// The hidden-by-default sidebar (mockup 2a): an Open Archives section listing
/// every open archive with an item-count badge, plus a Places section of
/// favorite extraction destinations addressable via ⌘1–⌘9.
struct PlacesSidebarView: View {
    @Bindable var model: AppModel

    /// Unified selection so BOTH sections participate in the List's native
    /// single-click selection. Places were previously `Button`s, which on macOS
    /// need the List focused first — so the first click after re-showing the
    /// sidebar only focused the List and a second click was required to load.
    private enum SidebarItem: Hashable {
        case start
        case archive(UUID)
        case place(URL)
    }

    var body: some View {
        // Route selection through `openArchive`/`browseFolder` rather than
        // binding a raw id: the file list reloads from `refreshEntries()`
        // (keyed off the current archive), so simply flipping the id would
        // switch the highlight without swapping the entries.
        List(selection: Binding<SidebarItem?>(
            get: {
                if let id = model.currentArchiveID { return .archive(id) }
                if let folder = model.browsingFolder {
                    if model.places.contains(where: { $0.url == folder }) {
                        return .place(folder)
                    }
                    // Browsing a folder that isn't a Place: no row to highlight.
                    return nil
                }
                return .start
            },
            set: { newValue in
                switch newValue {
                case .start:
                    model.goToStart()
                case .archive(let id):
                    if let archive = model.openArchives.first(where: { $0.id == id }) {
                        model.openArchive(archive.url)
                    }
                case .place(let url):
                    model.browseFolder(url)
                case nil:
                    model.currentArchiveID = nil
                }
            }
        )) {
            // "Start", not "Home": next to Places (real folders) a "Home" row
            // would read as the user's ~ folder.
            Label("Start", systemImage: "square.grid.2x2")
                .tag(SidebarItem.start)
                .help("Go to the drop zones")

            Section("Open Archives") {
                ForEach(model.openArchives) { archive in
                    Label {
                        HStack {
                            Text(archive.name).lineLimit(1)
                            Spacer()
                            if archive.isEncrypted {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(archive.itemCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    } icon: {
                        FileTypeIcon(ext: (archive.name as NSString).pathExtension)
                    }
                    .tag(SidebarItem.archive(archive.id))
                    .contextMenu {
                        Button("Share…") { SharePicker.present([archive.url]) }
                        Button("Copy Path") { copyPath(archive.url) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                        }
                        Divider()
                        Button("Close") { model.closeArchive(archive.id) }
                    }
                }
            }

            Section("Places") {
                ForEach(model.places) { place in
                    // A selectable row (`.tag`) rather than a Button: single
                    // click selects and loads even when the List isn't focused.
                    Label(place.name, systemImage: place.symbol)
                        .tag(SidebarItem.place(place.url))
                        .help("Browse \(place.name)")
                        .dropDestination(for: URL.self) { _, _ in
                            // Extract the CURRENT browser selection to this Place
                            // (matching the entry context menu). Never extract the
                            // whole open archive here just because something was
                            // dropped — that wrong-target overwrite was the bug.
                            // Ignore a drop when there is nothing selected.
                            guard model.hasOpenArchive,
                                  !model.selectedArchiveEntryIDs.isEmpty else { return false }
                            model.extractToPlace(
                                place, selectedEntries: Array(model.selectedArchiveEntryIDs))
                            return true
                        }
                        .contextMenu {
                            Button("Copy Path") { copyPath(place.url) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([place.url])
                            }
                            Divider()
                            Button("Remove from Places", role: .destructive) {
                                model.removePlace(place)
                            }
                        }
                }
                .onMove { source, destination in
                    model.movePlaces(from: source, to: destination)
                }
                Button {
                    chooseFolder()
                } label: {
                    Label("Add Place…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            model.addPlace(url: url)
        }
    }

    /// Copy an open archive's on-disk path to the pasteboard.
    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
