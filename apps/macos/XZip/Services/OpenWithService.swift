import AppKit
import UniformTypeIdentifiers

/// Bridges to macOS "Open With" behaviour: enumerate the apps registered to
/// handle a file type, open a file with a chosen app, or let the user pick an
/// app from a panel — mirroring Finder's Open With submenu.
@MainActor
enum OpenWithService {
    /// An app capable of opening a given file, for menu display.
    struct App: Identifiable, Hashable {
        let url: URL
        let name: String
        let icon: NSImage
        var id: URL { url }
    }

    /// Apps registered to open `fileURL` (a real on-disk file), default first.
    static func apps(for fileURL: URL) -> [App] {
        let workspace = NSWorkspace.shared
        var urls = workspace.urlsForApplications(toOpen: fileURL)
        let defaultURL = workspace.urlForApplication(toOpen: fileURL)
        return decorate(urls: &urls, defaultURL: defaultURL)
    }

    /// Apps registered for a file extension. Used for archive entries, which
    /// have no on-disk URL until extracted.
    static func apps(forExtension ext: String) -> [App] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        let workspace = NSWorkspace.shared
        var urls = workspace.urlsForApplications(toOpen: type)
        let defaultURL = workspace.urlForApplication(toOpen: type)
        return decorate(urls: &urls, defaultURL: defaultURL)
    }

    /// Shared: dedup, hoist the default app, and attach display name + icon.
    private static func decorate(urls: inout [URL], defaultURL: URL?) -> [App] {
        let workspace = NSWorkspace.shared
        if let defaultURL {
            urls.removeAll { $0 == defaultURL }
            urls.insert(defaultURL, at: 0)
        }
        var seen = Set<String>()
        return urls.compactMap { url in
            guard seen.insert(url.path).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            let icon = workspace.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return App(url: url, name: name, icon: icon)
        }
    }

    typealias OpenPerformer = (@escaping @Sendable (Bool) -> Void) -> Void

    /// Open `fileURL` with the application at `appURL`, reporting whether AppKit
    /// accepted the request rather than assuming a submitted request succeeded.
    static func open(
        _ fileURL: URL,
        withApplicationAt appURL: URL,
        perform: OpenPerformer? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = {
                continuation.resume(returning: $0)
            }
            if let perform {
                perform(finish)
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: appURL,
                configuration: config
            ) { _, error in
                finish(error == nil)
            }
        }
    }

    /// Prompt the user to choose an application (Finder's "Other…"), then open.
    @discardableResult
    static func chooseAppAndOpen(_ fileURL: URL) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let appURL = panel.url else {
            return false
        }
        return await open(fileURL, withApplicationAt: appURL)
    }
}
