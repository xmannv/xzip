import SwiftUI
import AppKit
import XZIPCore
import os

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

    /// Field diagnostics for the two behaviours unit tests cannot reach:
    /// activation on "Open With" and the quit path. Read after a manual test via
    /// `log show --predicate 'subsystem == "com.codetay.xzip"' --info`.
    private let lifecycleLog = Logger(
        subsystem: "com.codetay.xzip",
        category: "lifecycle"
    )

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach(route)
        // If this batch left 2+ archives open, reveal the sidebar so the user
        // can see and switch between them.
        model?.revealSidebarForMultipleArchives()
        // The window may have been closed (app kept alive in the Dock): the
        // model just accepted the archive, but there is no window to show it or
        // host the password-prompt sheet, and nothing to bring frontmost.
        ensureMainWindowExists(reason: "open urls")
        activateIfOpeningFiles(urls)
    }

    /// Guarantees the main window exists when the app was launched BY a file
    /// open.
    ///
    /// The `WindowGroup` opts out of external events entirely (see the scene),
    /// which on a normal launch still yields the default window — but when the
    /// launch was CAUSED by an external event, SwiftUI treats that declined
    /// event as the window request and creates nothing: no window, no
    /// `.onAppear`, no `model`, and the buffered URLs never flush. Running the
    /// reopen path is the same "give me your default window" request a Dock
    /// click makes, and it goes through SwiftUI's ordinary window creation, not
    /// the external-event activation path that crashes in toolbar layout.
    ///
    /// Deferred one runloop pass so SwiftUI's scene bookkeeping from the launch
    /// has settled before the reopen asks it for a window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.ensureMainWindowExists(reason: "didFinishLaunching")
        }
    }

    /// Recreates the group's default window when none exists.
    ///
    /// Two states need this: a launch CAUSED by a file open (the scene declined
    /// the launching event, so SwiftUI made no window), and an `open` arriving
    /// while the app sits window-less in the Dock after its window was closed.
    /// Asking LaunchServices to "open" this already-running app is delivered as
    /// the same reopen event a Dock click produces, and SwiftUI answers it by
    /// materialising the default window through its ordinary creation path — not
    /// the external-event activation path that crashes in toolbar layout. (A
    /// hand-built kAEReopenApplication descriptor was tried and went nowhere:
    /// without a valid target PSN the send fails silently.)
    private func ensureMainWindowExists(reason: String) {
        guard NSApp.windows.first(where: { $0.canBecomeMain }) == nil else { return }
        lifecycleLog.notice("ensureMainWindowExists(\(reason, privacy: .public)): requesting reopen")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
    }

    /// Remove the entries extracted for Quick Look, drag-out and Share before the
    /// process goes away.
    ///
    /// For an encrypted archive those files are decrypted plaintext, and they used
    /// to be left for the system's temp reaper, which can take days. Not called on
    /// a force quit or a crash, so `AppModel` also prunes leftover roots at launch.
    func applicationWillTerminate(_ notification: Notification) {
        model?.scratch.removeAll()
    }

    /// Delete the session's scratch files off the main thread, then let the quit
    /// proceed.
    ///
    /// This work used to run synchronously in `applicationWillTerminate`, which
    /// blocks the main thread: a recursive `removeItem` over an extracted tree can
    /// take seconds, and AppKit renders that as a beachball, so quitting after a
    /// large drag-out looked like a hang and had to be force-quit. Dragging a
    /// folder now extracts its whole tree, which made the stall far more likely.
    ///
    /// `.terminateLater` is what keeps the security property intact: the plaintext
    /// is still removed before the process exits, rather than being left on disk
    /// for the next launch to prune. `applicationWillTerminate` remains as the
    /// backstop for quits that bypass this hook.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        lifecycleLog.notice("shouldTerminate: entered")
        // Release any file promise still registered on the drag pasteboard.
        //
        // `terminate:` posts a notification that CF answers by resolving every
        // outstanding pasteboard promise before the app dies
        // (`CFPasteboardResolveAllPromisedData`), spinning a nested run loop on
        // the main thread until each promise delivers. A drag-out leaves its
        // `NSItemProvider` promise registered even after a successful drop, and
        // fulfilling it needs the main actor (`extractEntryToTemp`) — which that
        // nested loop never services. Quitting after any drag-out therefore
        // deadlocked in `terminate:` (sampled: 100% of time under
        // CFPasteboardResolveAllPromisedData → mach_msg) and had to be
        // force-quit. The delivered files are already on disk; the leftover
        // promise is pure liability, so drop it before termination advances.
        NSPasteboard(name: .drag).clearContents()
        // NOTE: when a sheet is up, AppKit's `terminate:` gives up BEFORE ever
        // consulting this delegate (traced: no `shouldTerminate` entry on a
        // quit attempted with the password prompt attached). Sheet handling for
        // quit therefore lives in `requestQuit`, which runs before `terminate:`.
        // The cancel below only covers the AE-quit path arriving between a
        // sheet's model-side dismissal and its visual detach.
        if let model, model.isPasswordPromptPresented {
            lifecycleLog.notice("shouldTerminate: lowering password prompt")
            model.passwordPromptDidCancel()
            model.isPasswordPromptPresented = false
        }
        let roots = model?.scratch.takeRootsForTermination() ?? []
        let sheetsUp = NSApp.windows.contains { !$0.sheets.isEmpty }
        guard !roots.isEmpty || sheetsUp else {
            lifecycleLog.notice("shouldTerminate: nothing to wait for, terminateNow")
            return .terminateNow
        }
        lifecycleLog.notice("shouldTerminate: roots=\(roots.count) sheetsUp=\(sheetsUp), terminateLater")
        let deletion = DispatchGroup()
        if !roots.isEmpty {
            deletion.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for root in roots {
                    try? FileManager.default.removeItem(at: root)
                }
                deletion.leave()
            }
        }
        deletion.notify(queue: .main) { [weak self] in
            self?.replyToTerminationWhenSheetsGone(attemptsLeft: 40)
        }
        return .terminateLater
    }

    /// Lets the quit proceed once no window has a sheet attached.
    ///
    /// Polls across runloop passes because sheet dismissal is SwiftUI-animated
    /// and there is no callback for "the sheet is gone". Bounded: after ~2s the
    /// reply is sent regardless — a stuck sheet must degrade to the pre-fix
    /// behaviour (AppKit aborts the close), never to an unbounded wait, since
    /// nothing would ever resolve it.
    private func replyToTerminationWhenSheetsGone(attemptsLeft: Int) {
        let sheetsUp = NSApp.windows.contains { !$0.sheets.isEmpty }
        guard sheetsUp, attemptsLeft > 0 else {
            lifecycleLog.notice("termination reply: sheetsUp=\(sheetsUp) attemptsLeft=\(attemptsLeft)")
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.replyToTerminationWhenSheetsGone(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Quit entry point for ⌘Q, replacing the stock terminate menu action.
    ///
    /// With a sheet attached (the encrypted-archive password prompt), AppKit's
    /// own `terminate:` abandons the quit BEFORE consulting
    /// `applicationShouldTerminate` (traced on-disk: quitting with the prompt up
    /// leaves no `shouldTerminate` entry, the app just returns to its run loop —
    /// which reads as a hang and got force-quit). So the sheet has to come down
    /// before `terminate:` runs at all: cancel through the model, give SwiftUI
    /// one runloop pass to detach the sheet, then start the normal termination,
    /// which now reaches the delegate and the scratch cleanup.
    func requestQuit() {
        lifecycleLog.notice("requestQuit promptUp=\(self.model?.isPasswordPromptPresented ?? false)")
        guard let model, model.isPasswordPromptPresented else {
            NSApp.terminate(nil)
            return
        }
        model.passwordPromptDidCancel()
        model.isPasswordPromptPresented = false
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private func flushPendingURLs() {
        guard model != nil, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(route)
        model?.revealSidebarForMultipleArchives()
        activateIfOpeningFiles(urls)
    }

    /// Pull the app to the front for a Finder file open.
    ///
    /// `NSApp.activate()` alone was not enough, for three reasons:
    ///
    /// - It does not clear `NSApplication.isHidden`, and the `xzip://`
    ///   quick-compress branch below hides the app deliberately. After one quick
    ///   compress, every later "Open With" updated the window's contents behind a
    ///   still-hidden app.
    /// - App-level activation does not raise a window that is hidden or
    ///   minimized, so the window itself has to be ordered front.
    /// - Under cooperative activation (macOS 14+) a self-activation submitted
    ///   before the system's own LaunchServices activation transfer settles is
    ///   silently dropped, so this has to land on a later runloop pass — the same
    ///   deferral the `hide` below already relies on.
    ///
    /// Called once per batch rather than per URL: a multi-file open needs one
    /// activation, not one per file.
    private func activateIfOpeningFiles(_ urls: [URL]) {
        guard urls.contains(where: \.isFileURL) else { return }
        // ~2s of retries: when the main window was closed (app kept alive in the
        // Dock), the open triggers SwiftUI's reopen path and the window is
        // recreated asynchronously — activation can win the race long before the
        // window exists to be ordered front.
        raiseWindow(attemptsLeft: 40)
    }

    /// One activation attempt, repeated across runloop passes until it takes.
    ///
    /// Under cooperative activation (macOS 14+) an app cannot simply take focus:
    /// `NSApp.activate()` is a *request*, and the window server refuses it for a
    /// background app, silently. That is why plain `activate()` — with or without
    /// `ignoringOtherApps`, deferred or not — never moved XZip to the front when it
    /// was already running. The path that does work is
    /// `activate(from:options:)`: focus is TRANSFERRED from the app that asked for
    /// the open (Finder), which is entitled to give it away. A transfer is granted
    /// where a self-request is denied.
    ///
    /// The retry exists because LaunchServices delivers the open event before the
    /// requesting app has necessarily settled, so the first attempt can find no
    /// front app to take focus from. Re-checking `NSApp.isActive` each pass makes
    /// this converge rather than guess a delay: a fast hand-off costs one pass, a
    /// slow one keeps trying, and success stops the loop.
    private func raiseWindow(attemptsLeft: Int) {
        // Clears `isHidden`, which activation does not: the `xzip://`
        // quick-compress branch below hides the app deliberately, and after one
        // quick compress every later open updated the window behind a hidden app.
        NSApp.unhide(nil)

        // Prefer a transfer from whoever is frontmost (Finder for an "Open With").
        // `NSApp.activate()` remains the fallback for a cold launch, where this
        // app IS already frontmost and there is nothing to transfer from.
        let source = NSWorkspace.shared.frontmostApplication
        if let source, source != .current {
            NSRunningApplication.current.activate(from: source, options: [.activateAllWindows])
        } else {
            NSApp.activate()
        }
        lifecycleLog.notice(
            "raiseWindow attempt=\(attemptsLeft) source=\(source?.bundleIdentifier ?? "nil", privacy: .public) isActive=\(NSApp.isActive) hidden=\(NSApp.isHidden) windows=\(NSApp.windows.count)"
        )

        // Not `keyWindow`: a hidden app has no key window, which is exactly the
        // case this exists for. Deminiaturize first — an ordered-front window
        // that is still minimized stays in the Dock.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain })
            ?? NSApp.windows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // Done only when the app is active AND a real window exists to be front.
        // Checking `isActive` alone stopped too early in the closed-window case:
        // activation succeeds immediately (the app can be "active" with zero
        // windows), while the reopened window is still being built — quitting
        // the loop then left the new window behind Finder.
        let hasWindow = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
        guard attemptsLeft > 1, !(NSApp.isActive && hasWindow) else {
            lifecycleLog.notice(
                "raiseWindow done isActive=\(NSApp.isActive) hasWindow=\(hasWindow) attemptsLeft=\(attemptsLeft)"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.raiseWindow(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Route one incoming URL: a `file://` archive to open in the browser, or an
    /// `xzip://` command posted by the Finder Sync / Share extensions.
    private func route(_ url: URL) {
        guard let model else { return }
        if url.isFileURL {
            // If the archive is one part of a split set, offer to join it first.
            model.handlePossibleSplitArchive(url)
            model.openArchive(url)
            // Activation is handled once per batch by `activateIfOpeningFiles`,
            // not here: it has to be deferred to a later runloop pass, and a
            // multi-file open needs one activation rather than one per file.
            // Only real file opens activate — the `xzip://` quick-compress
            // branch below deliberately hands focus back to Finder.
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
            //
            // Existence is all this check buys, and it is not what protects the
            // sensitive case. Extraction can consume a password remembered in the
            // Keychain, which would give the caller plaintext it cannot produce
            // itself; `AppModel.extractFromFinder` gates exactly that on user
            // presence.
            //
            // A shared nonce in the App Group container would NOT authenticate the
            // caller, despite the obvious appeal: the container lives under
            // ~/Library/Group Containers, and the attacker being considered here is
            // an unsandboxed local process running as the same user, which can just
            // read it. It would only stop a sandboxed caller.
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
                // Assemble the transactional extraction stack, which runs crash
                // recovery to completion before extraction can use it. Until
                // this finishes, or if it fails, extraction stays blocked so no
                // backend receives direct final-destination authority — see
                // ExtractionRouter.prepare().
                //
                // Routed through the model rather than the router directly so a
                // failure is published to the UI instead of staying a private
                // diagnostic — see AppModel.prepareExtraction().
                .task { await model.prepareExtraction() }
                // Give the delegate a handle to the model so it can route
                // file/command opens into this window.
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 960, height: 640)
        // SwiftUI must never touch external events, in EITHER direction:
        //
        // - Default behaviour opens a fresh window per event, and laying out that
        //   second window's customizable toolbar crashes on macOS 26
        //   (AppKitToolbarStrategy.updateLocations).
        // - A view-level claim (`preferring: ["*"]`) was tried instead and it
        //   crashes too: SwiftUI routes the event through its own
        //   `activateWindowForExternalEvent`, whose layout pass dies inside the
        //   same toolbar machinery while activating the EXISTING window.
        //
        // So the group opts out entirely; the AppKit delegate is the only
        // receiver (`application(_:open:)`), and it feeds the existing window's
        // model. The one hole this leaves — a cold launch caused by a file open
        // creates no window, because the launching event was declined — is
        // plugged by `applicationDidFinishLaunching`, which requests the default
        // window explicitly (see the delegate).
        .handlesExternalEvents(matching: [])
        .commands {
            XZIPCommands(model: model, openQueue: { model.isQueuePopoverPresented = true })
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // ⌘Q must go through the delegate: AppKit's stock `terminate:`
            // silently abandons the quit while a sheet (the password prompt) is
            // attached, which read as a hang. `requestQuit` lowers the prompt
            // first, then terminates — see AppDelegate.
            CommandGroup(replacing: .appTermination) {
                Button("Quit XZip") { appDelegate.requestQuit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            XZIPSettingsView(model: model)
                .tint(XZIPColor.accent)
        }
    }
}
