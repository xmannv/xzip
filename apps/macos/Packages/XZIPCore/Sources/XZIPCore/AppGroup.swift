import Foundation

/// Storage shared between the main app and its sandboxed extensions
/// (FinderSync, QuickLook, Share) via an App Group container.
///
/// The main app is not sandboxed but the extensions are, so they can't see the
/// app's `UserDefaults.standard`. An App Group gives both sides one suite to
/// read/write. The group id must be registered on the Apple Developer portal
/// and listed in each target's `.entitlements` under
/// `com.apple.security.application-groups`.
public enum XZIPAppGroup {
    /// The shared App Group identifier. Keep in sync with the entitlements.
    public static let id = "group.com.codetay.xzip"

    /// Whether the Finder context menu extension should show its menu.
    public static let finderMenuKey = "showFinderContextMenu"

    /// The shared defaults suite, or nil if the group is unavailable (e.g. the
    /// entitlement isn't present in an ad-hoc build).
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }

    /// The shared App Group container, or nil if unavailable.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Sub-folder inside the container where the Share extension stages files for
    /// the main app to pick up (the extension's own tmp/Inbox is reclaimed the
    /// moment it completes its request).
    public static var sharedInboxURL: URL? {
        containerURL?.appendingPathComponent("SharedInbox", isDirectory: true)
    }

    /// Copy `source` into a fresh folder under the shared inbox and return the
    /// staged URL, so the file survives after the extension finishes. Returns nil
    /// if the group container is unavailable or the copy fails.
    public static func stage(_ source: URL) -> URL? {
        guard let inbox = sharedInboxURL else { return nil }
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Best-effort removal of staged inbox entries older than `maxAge` seconds.
    /// Called at app launch so shared files the app has already consumed don't
    /// accumulate in the container.
    public static func pruneSharedInbox(olderThan maxAge: TimeInterval = 24 * 60 * 60) {
        guard let inbox = sharedInboxURL else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > maxAge {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Whether the Finder menu is enabled. Defaults to true when unset so the
    /// extension shows its menu until the user explicitly turns it off.
    public static var showsFinderMenu: Bool {
        guard let defaults, defaults.object(forKey: finderMenuKey) != nil else {
            return true
        }
        return defaults.bool(forKey: finderMenuKey)
    }
}
