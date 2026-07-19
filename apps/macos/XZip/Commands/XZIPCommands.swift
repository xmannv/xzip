import SwiftUI
import AppKit

/// Menu bar commands + keyboard shortcuts.
///
/// Shortcuts are user-customizable: each is stored in `UserDefaults` under its
/// `ShortcutAction.defaultsKey` and read here via `@AppStorage`, so editing one
/// in Settings → Shortcuts rebinds the menu command live (SwiftUI re-evaluates
/// this `Commands` body when the backing default changes).
struct XZIPCommands: Commands {
    let model: AppModel
    /// Shows the Queue popover in the main window's toolbar.
    let openQueue: () -> Void

    // Raw JSON strings for each rebindable shortcut. Defaults come from the
    // action's factory shortcut so first launch matches the intended layout.
    @AppStorage(ShortcutAction.newArchive.defaultsKey)    private var newArchiveRaw    = ShortcutAction.newArchive.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.openArchive.defaultsKey)   private var openArchiveRaw   = ShortcutAction.openArchive.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.extractAll.defaultsKey)    private var extractAllRaw    = ShortcutAction.extractAll.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.testArchive.defaultsKey)   private var testArchiveRaw   = ShortcutAction.testArchive.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.reopenClosed.defaultsKey)  private var reopenClosedRaw  = ShortcutAction.reopenClosed.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.showQueue.defaultsKey)     private var showQueueRaw     = ShortcutAction.showQueue.defaultShortcut.rawValue
    @AppStorage(ShortcutAction.toggleSidebar.defaultsKey) private var toggleSidebarRaw = ShortcutAction.toggleSidebar.defaultShortcut.rawValue
    /// Shared with Settings → General; toggling here updates both live.
    @AppStorage(XZIPDefaults.foldersFirst) private var foldersFirst = true
    /// Shared with Settings → General; the same key keeps both pickers in sync.
    @AppStorage(XZIPDefaults.appLanguage) private var appLanguage = AppLanguage.system

    /// Present only while the main window is key (set via `focusedSceneValue`
    /// in `MainWindowView`), so ⌘W can close in-window context there while
    /// auxiliary windows (Queue, Settings) still close normally.
    @FocusedValue(\.mainWindowModel) private var focusedModel

    private func shortcut(_ raw: String, _ action: ShortcutAction) -> KeyboardShortcut {
        (Shortcut(rawValue: raw) ?? action.defaultShortcut).keyboardShortcut
    }

    /// Persists the new language immediately, then offers a relaunch — the
    /// switch only fully applies (menu bar, window chrome) after a relaunch.
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { appLanguage },
            set: { newValue in
                guard newValue != appLanguage else { return }
                appLanguage = newValue
                newValue.apply()
                promptRelaunch()
            }
        )
    }

    private func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch to apply the new language.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            AppLanguage.relaunch()
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Archive…") { model.beginCompress(with: []) }
                .keyboardShortcut(shortcut(newArchiveRaw, .newArchive))

            Button("Open Archive…") { openArchivePanel() }
                .keyboardShortcut(shortcut(openArchiveRaw, .openArchive))

            Menu("Open Recent") {
                let recents = model.recentDocuments
                if recents.isEmpty {
                    Button("No Recent Archives") {}.disabled(true)
                } else {
                    ForEach(recents, id: \.self) { url in
                        Button(url.lastPathComponent) { model.openArchive(url) }
                    }
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                }
            }
        }

        // ⌘W closes the current context, not the whole window: folder browsing
        // first, then the frontmost archive (back to the drop zones). Only when
        // nothing is open — or another window is key — does it close the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close") { closeKeyContext() }
                .keyboardShortcut("w", modifiers: .command)
            // Replacing .saveItem drops the system-provided "Close All";
            // restore it with its standard shortcut.
            Button("Close All") {
                for window in NSApp.windows where window.isVisible && !window.isSheet {
                    window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
        }

        CommandMenu("Archive") {
            Button("Extract") { extractAll() }
                .keyboardShortcut(shortcut(extractAllRaw, .extractAll))
                .disabled(!model.hasOpenArchive)
            Button("Test Archive") { model.testCurrentArchive() }
                .keyboardShortcut(shortcut(testArchiveRaw, .testArchive))
                .disabled(!model.hasOpenArchive)
            Divider()
            Button("Reopen Closed Archive") { model.reopenLastClosed() }
                .keyboardShortcut(shortcut(reopenClosedRaw, .reopenClosed))
                .disabled(!model.canReopenClosed)
            Button("Show Queue") { openQueue() }
                .keyboardShortcut(shortcut(showQueueRaw, .showQueue))
        }

        CommandGroup(after: .toolbar) {
            Toggle("Show Folders on Top", isOn: $foldersFirst)
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut(shortcut(toggleSidebarRaw, .toggleSidebar))
            Divider()
            Menu("Language") {
                Picker("Language", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private func closeKeyContext() {
        // A modal sheet (compress, password, repack progress…) owns the window:
        // yanking the archive/folder context out from under it — or closing the
        // window — would leave the sheet orphaned. ⌘W is a no-op until it ends.
        if let key = NSApp.keyWindow, key.isSheet || key.attachedSheet != nil { return }
        if let model = focusedModel {
            if model.browsingFolder != nil {
                model.browsingFolder = nil
                return
            }
            if let id = model.currentArchiveID {
                model.closeArchive(id)
                return
            }
        }
        NSApp.keyWindow?.performClose(nil)
    }

    private func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openArchive(url)
        }
    }

    private func extractAll() {
        guard let archive = model.currentArchive?.url else { return }
        let destination = archive.deletingLastPathComponent()
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
        model.startExtraction(archive: archive, destination: destination)
    }
}

/// Focused-value plumbing for the ⌘W override: `MainWindowView` publishes its
/// model while its window is key; `XZIPCommands` reads it to decide whether ⌘W
/// closes an archive or the window itself.
private struct MainWindowModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var mainWindowModel: AppModel? {
        get { self[MainWindowModelKey.self] }
        set { self[MainWindowModelKey.self] = newValue }
    }
}
