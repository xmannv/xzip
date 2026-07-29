import Foundation
import Security

/// Storage shared between the main app and its sandboxed extensions
/// (FinderSync, QuickLook, Share) via an App Group container.
///
/// The main app is not sandboxed but the extensions are, so they can't see the
/// app's `UserDefaults.standard`. An App Group gives both sides one suite to
/// read/write. The group id must be registered on the Apple Developer portal
/// and listed in each target's `.entitlements` under
/// `com.apple.security.application-groups`.
///
/// The concrete identifier is `group.com.codetay.xzip`, registered on the Apple
/// Developer portal and embedded verbatim in each target's provisioning profile.
/// App Group identifiers are not application identifiers or keychain access groups:
/// prepending a Team ID produces a different group, which the profile does not
/// authorize and macOS signing validation rejects.
public enum XZIPAppGroup {
    /// Why the App Group is unusable, when it is.
    ///
    /// Worth distinguishing: an unsigned local build legitimately has no
    /// entitlement, whereas unreadable signing information means something is
    /// wrong with the build itself.
    public enum Unavailable: Error, Equatable, Sendable {
        /// The process's own signing information could not be read.
        case signingInformationUnreadable(OSStatus)
        /// Signed, but with no `com.apple.security.application-groups` entry for
        /// this app. Normal for the unsigned/ad-hoc local builds, where the
        /// extensions cannot run anyway.
        case entitlementMissing
    }

    /// The concrete App Group identifier registered in Apple Developer.
    public static let groupSuffix = "group.com.codetay.xzip"

    /// The shared App Group identifier, read from this process's own signed
    /// entitlements.
    ///
    /// Reading rather than blindly returning `groupSuffix` keeps local/ad-hoc
    /// builds fail-closed: an absent or mismatched entitlement does not silently
    /// fall back to standard defaults or an unrelated container. The signed value
    /// must equal the concrete registered identifier exactly.
    ///
    /// Resolved once: it cannot change while the process runs.
    public static let identifier: Result<String, Unavailable> = resolveIdentifier()

    /// The identifier, or nil when the App Group is unavailable.
    public static var id: String? {
        try? identifier.get()
    }

    /// Whether the Finder context menu extension should show its menu.
    public static let finderMenuKey = "showFinderContextMenu"

    /// The shared defaults suite, or nil if the group is unavailable (e.g. the
    /// entitlement isn't present in an ad-hoc build).
    public static var defaults: UserDefaults? {
        guard let id else { return nil }
        return UserDefaults(suiteName: id)
    }

    /// The shared App Group container, or nil if unavailable.
    public static var containerURL: URL? {
        guard let id else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Picks this app's group out of the signed entitlement.
    ///
    /// Exposed for tests so the selection rule can be checked without a signed
    /// bundle; `resolveIdentifier` supplies the real entitlement.
    static func selectGroup(from groups: [String]) -> String? {
        // Exact match rather than `first`: an app may legitimately carry several
        // groups, and a Team-prefixed near-match names a different container.
        groups.first { $0 == groupSuffix }
    }

    private static func resolveIdentifier() -> Result<String, Unavailable> {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            return .failure(.signingInformationUnreadable(status))
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return .failure(.signingInformationUnreadable(status))
        }

        var info: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess,
              let signing = info as? [String: Any]
        else {
            return .failure(.signingInformationUnreadable(status))
        }

        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String]
        guard let resolved = selectGroup(from: groups ?? []) else {
            return .failure(.entitlementMissing)
        }
        return .success(resolved)
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

    /// Drop the staging folders holding `urls`, once the app is done reading them.
    ///
    /// `stage` copies the user's file into the container, so until this runs there
    /// is a second copy of possibly sensitive data sitting in a folder they cannot
    /// see. Waiting for `pruneSharedInbox` means waiting for the next launch *and*
    /// for the copy to age past a day.
    ///
    /// Only removes a folder that is exactly `SharedInbox/<one component>`, the
    /// shape `stage` creates. Anything else is ignored: this deletes directories,
    /// and a caller passing a path that merely looks staged must not be able to
    /// take a real folder with it. Paths are standardized first, so `..` cannot be
    /// used to climb out and still satisfy the check.
    public static func releaseStaged(_ urls: [URL]) {
        guard let inbox = sharedInboxURL else { return }
        for folder in stagedFolders(in: inbox, holding: urls) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The staging folders under `inbox` that hold `urls`.
    ///
    /// Separated from the deletion so the containment rule can be tested: the real
    /// `inbox` is nil unless the process is signed with the entitlement, and this
    /// is the part that decides which directories get removed.
    ///
    /// Accepts only `inbox/<one component>/<name>`, the shape `stage` writes.
    /// Compared on `path` rather than by `URL` equality, which would be thrown off
    /// by a trailing slash, and standardized so `..` cannot climb out and still
    /// look contained.
    static func stagedFolders(in inbox: URL, holding urls: [URL]) -> Set<URL> {
        let inboxPath = inbox.standardizedFileURL.path
        var folders: Set<URL> = []
        for url in urls {
            let folder = url.standardizedFileURL.deletingLastPathComponent()
            // Rejects `inbox/file` too: its parent is the container, not the
            // inbox, so the inbox itself can never be the folder removed.
            guard folder.deletingLastPathComponent().path == inboxPath else { continue }
            folders.insert(folder)
        }
        return folders
    }

    /// Best-effort removal of staged inbox entries older than `maxAge` seconds.
    /// Called at app launch to catch anything `releaseStaged` missed, e.g. when a
    /// compression failed and the sources were kept so Retry could work.
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
