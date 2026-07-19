import SwiftUI
import AppKit
import XZIPCore

/// Receives Finder "Open With" / double-click file opens and the extension
/// `xzip://` commands via the AppKit delegate.
///
/// Why a delegate instead of the `WindowGroup`'s `.onOpenURL`: this app is
/// single-window (multiple archives live in one window's sidebar). When a
/// `file://` URL arrives through `.onOpenURL`, SwiftUI's `WindowGroup` opens a
/// *second* window for it and crashes laying out that window's customizable
/// toolbar (`AppKitToolbarStrategy.updateLocations`). Handling the open here
/// feeds the URL into the shared model, which surfaces it in the existing
/// window — no second window, no crash.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired to the shared model once the main window appears. URLs that arrive
    /// before then (a cold launch caused by opening a file) are buffered and
    /// flushed as soon as the model is set.
    var model: AppModel? {
        didSet { flushPendingURLs() }
    }
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(route)
        // If this batch left 2+ archives open, reveal the sidebar so the user
        // can see and switch between them.
        model?.revealSidebarForMultipleArchives()
    }

    private func flushPendingURLs() {
        guard model != nil, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(route)
        model?.revealSidebarForMultipleArchives()
    }

    /// Route one incoming URL: a `file://` archive to open in the browser, or an
    /// `xzip://` command posted by the Finder Sync / Share extensions.
    private func route(_ url: URL) {
        guard let model else { return }
        if url.isFileURL {
            // If the archive is one part of a split set, offer to join it first.
            model.handlePossibleSplitArchive(url)
            model.openArchive(url)
            return
        }
        guard let command = AppCommand(url: url) else { return }
        switch command {
        case let .compress(paths, _, quick, format):
            // Only act on paths that actually exist: any local app can open an
            // `xzip://` URL, so ignore fabricated paths rather than acting on
            // them. (Silent runs also never clobber — the destination is
            // uniquified in `startCompression`.)
            let urls = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            if quick {
                model.quickCompress(with: urls)
                // A one-shot Finder compress should feel like it happens "in
                // Finder": opening our URL foregrounds the app, so hand focus
                // back. The job keeps running in the background. Deferred to the
                // next runloop so it lands after the system's activation.
                DispatchQueue.main.async { NSApp.hide(nil) }
            } else {
                let uiFormat = format
                    .flatMap(ArchiveFormat.init(rawValue:))
                    .map(ModelMapping.uiFormat(from:))
                model.beginCompress(with: urls, format: uiFormat)
            }
        case let .extract(paths, destination, withPassword):
            // As with compress: any local app can open an `xzip://` URL, so
            // ignore fabricated/non-existent paths rather than acting on them.
            // (A shared one-time nonce with the Finder extension would fully
            // authenticate the caller; this at least rejects made-up paths.)
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return }
            model.extractFromFinder(paths: existing, destination: destination, withPassword: withPassword)
        }
    }
}

/// Application entry point.
///
/// Design: owns the shared `AppModel` (composition root wiring `XZIPCore` via
/// `ArchiveService`) and hosts two scenes — the main archive-browser window and
/// Settings (mockup 1g); the operations queue is a toolbar popover in the main
/// window. Keeps Sparkle auto-update; file and `xzip://` opens are routed
/// through `AppDelegate` (see its note on avoiding a second window).
@main
struct XZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @StateObject private var updater = UpdaterService()

    init() {
        // macOS shows tooltips after a long default delay (~1.5s). AppKit reads
        // this UserDefaults key (milliseconds) to time the initial tooltip, so
        // lowering it makes toolbar `.help()` tips appear promptly.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(model: model)
                .tint(XZIPColor.accent)
                .frame(minWidth: 720, minHeight: 480)
                .task { NotificationService.shared.configure() }
                // Give the delegate a handle to the model so it can route
                // file/command opens into this window.
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 960, height: 640)
        // Do NOT let this WindowGroup spawn a second window for an incoming
        // file/URL open. SwiftUI's default behaviour opens a fresh window for
        // external events, and laying out that window's customizable toolbar
        // crashes on macOS 26 (AppKitToolbarStrategy.updateLocations). This app
        // is single-window anyway — the delegate routes opens into the existing
        // window's model. An empty match set opts the group out of external
        // event handling so no extra window is created.
        .handlesExternalEvents(matching: [])
        .commands {
            XZIPCommands(model: model, openQueue: { model.isQueuePopoverPresented = true })
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            XZIPSettingsView(model: model)
                .tint(XZIPColor.accent)
        }
    }
}
