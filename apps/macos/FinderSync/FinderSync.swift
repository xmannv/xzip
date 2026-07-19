import Cocoa
import FinderSync
import XZIPCore

/// Finder toolbar/context-menu extension.
///
/// Design: the extension stays thin. It only builds an `AppCommand` from the
/// user's Finder selection and hands off to the main app via the `xzip://` URL
/// scheme (all heavy lifting — engines, queue — lives in the app + XZIPCore).
/// This keeps the extension lightweight and within its sandbox limits.
class FinderSync: FIFinderSync {

    override init() {
        super.init()
        // Monitor the whole filesystem so the menu appears everywhere the user
        // right-clicks. NOTE: this extension is sandboxed, so NSHomeDirectory()
        // resolves to the extension's *container*, not the real home — using it
        // here would scope the menu to a path the user never browses, hiding it
        // entirely. "/" covers every location (Desktop, Documents, Downloads…).
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/")
        ]
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "XZip")
        // Respect the "Show XZip in Finder context menu" preference, shared from
        // the app via the App Group. When off, return an empty menu.
        guard XZIPAppGroup.showsFinderMenu else { return menu }

        // Top-level "XZip ▸" item with a submenu, matching mockup 1h.
        let root = NSMenuItem(title: "XZip", action: nil, keyEquivalent: "")
        root.image = menuIcon()
        let submenu = NSMenu(title: "XZip")

        let selection = selectedItems()
        let archives = selection.filter { ArchiveFormat.infer(fromFilename: $0.lastPathComponent) != nil }

        // Compress actions (mockup 1h).
        let defaultName = selection.count == 1
            ? selection[0].deletingPathExtension().lastPathComponent
            : (selection.first?.deletingLastPathComponent().lastPathComponent ?? "Archive")
        // No ellipsis = one-shot (compress immediately to .zip with defaults);
        // ellipsis = opens the options dialog in the app.
        submenu.addItem(makeItem("Compress to \u{201C}\(defaultName).zip\u{201D}", #selector(compressQuick(_:))))
        submenu.addItem(makeItem("Compress to 7Z…", #selector(compressTo7z(_:))))
        submenu.addItem(makeItem("Compress with Options…", #selector(compressSelected(_:))))

        // Extract actions, only for archive selections.
        if !archives.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(makeItem("Extract Here", #selector(extractHere(_:))))
            submenu.addItem(makeItem("Extract to Downloads", #selector(extractToDownloads(_:))))
            submenu.addItem(makeItem("Extract with Password…", #selector(extractWithPassword(_:))))
        }

        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    /// The "XZip" menu icon, manually tinted to the current appearance.
    ///
    /// A FinderSync extension runs in its own process and doesn't reliably
    /// propagate Finder's `effectiveAppearance`, so a plain `isTemplate` image
    /// renders as a solid black glyph in Dark Mode. We instead read the system
    /// appearance directly from the global `AppleInterfaceStyle` default (the
    /// reliable cross-process signal: "Dark" when Dark Mode is on) and draw the
    /// symbol in an explicit contrasting colour. `menu(for:)` is invoked fresh
    /// on every right-click, so the icon re-tints when the user switches modes.
    private func menuIcon() -> NSImage? {
        guard let base = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "XZip") else {
            return nil
        }
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let tint: NSColor = isDark ? .white : .black
        // Colour the symbol directly via a palette configuration. This is the
        // supported way to recolour an SF Symbol and, unlike a manual
        // lockFocus/sourceAtop draw, doesn't depend on the extension process
        // resolving the system appearance.
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        return base.withSymbolConfiguration(config)
    }

    /// Build a menu item targeting this extension instance.
    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    /// One-shot: compress straight to a .zip with saved defaults, no dialog.
    @objc private func compressQuick(_ sender: AnyObject?) {
        let paths = selectedItems().map(\.path)
        guard !paths.isEmpty else { return }
        open(.compress(paths: paths, presetID: nil, quick: true, format: nil))
    }

    /// Open the compress options dialog pre-set to 7-Zip, so the "Compress to
    /// 7Z…" label actually produces a 7z archive.
    @objc private func compressTo7z(_ sender: AnyObject?) {
        let paths = selectedItems().map(\.path)
        guard !paths.isEmpty else { return }
        open(.compress(paths: paths, presetID: nil, quick: false, format: ArchiveFormat.sevenZip.rawValue))
    }

    /// Open the app's compress options dialog for the selection (saved default).
    @objc private func compressSelected(_ sender: AnyObject?) {
        let paths = selectedItems().map(\.path)
        guard !paths.isEmpty else { return }
        open(.compress(paths: paths, presetID: nil, quick: false, format: nil))
    }

    private func archivePaths() -> [String] {
        selectedItems()
            .filter { ArchiveFormat.infer(fromFilename: $0.lastPathComponent) != nil }
            .map(\.path)
    }

    @objc private func extractHere(_ sender: AnyObject?) {
        let paths = archivePaths()
        guard !paths.isEmpty else { return }
        open(.extract(paths: paths, destination: .here, withPassword: false))
    }

    @objc private func extractToDownloads(_ sender: AnyObject?) {
        let paths = archivePaths()
        guard !paths.isEmpty else { return }
        open(.extract(paths: paths, destination: .downloads, withPassword: false))
    }

    @objc private func extractWithPassword(_ sender: AnyObject?) {
        let paths = archivePaths()
        guard !paths.isEmpty else { return }
        open(.extract(paths: paths, destination: .here, withPassword: true))
    }

    // MARK: - Helpers

    private func selectedItems() -> [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    /// Route a command to the main app through the custom URL scheme.
    private func open(_ command: AppCommand) {
        guard let url = command.url else { return }
        NSWorkspace.shared.open(url)
    }
}
