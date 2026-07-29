import Foundation

/// Credentials for archives the user has unlocked this session, one entry per
/// archive.
///
/// This replaces a single shared `AppModel.password` field that served every
/// archive at once. That field leaked in a way no amount of clearing could fix:
/// extracting an archive that is *not* the one on screen (a Finder Quick Action,
/// the Services menu) never goes through `openArchive`, so the archive being
/// extracted silently received whatever credential the viewed archive held.
///
/// Keyed by standardized path, matching `AppModel.vaultKey(for:)`, so a URL that
/// differs only in symlinks or `..` components resolves to the same entry.
///
/// Deliberately NOT `Observable`: a credential is not view state. Keeping it out
/// of the observation graph means no view can bind to it, and mutating one does
/// not invalidate unrelated views.
@MainActor
final class ArchiveCredentials {
    struct Lease: Equatable {
        fileprivate let key: String
        fileprivate let generation: UInt64
        let password: String
    }

    private struct Entry {
        var password: String
        var generation: UInt64
        var leaseCount = 0
        var discardWhenUnused = false
    }

    private var byArchive: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0

    func credential(for archive: URL) -> String? {
        byArchive[Self.key(archive)]?.password
    }

    func hasCredential(for archive: URL) -> Bool {
        byArchive[Self.key(archive)] != nil
    }

    func store(_ password: String, for archive: URL) {
        let key = Self.key(archive)
        guard !password.isEmpty else {
            byArchive[key] = nil
            return
        }
        nextGeneration &+= 1
        byArchive[key] = Entry(password: password, generation: nextGeneration)
    }

    /// Pins exactly the credential generation an extraction starts with.
    func acquire(for archive: URL) -> Lease? {
        let key = Self.key(archive)
        guard var entry = byArchive[key] else { return nil }
        entry.leaseCount += 1
        byArchive[key] = entry
        return Lease(key: key, generation: entry.generation, password: entry.password)
    }

    /// Releases one operation's generation. A stale completion cannot affect a
    /// replacement password because generation mismatch is a no-op. Concurrent
    /// operations keep the entry alive until the final lease exits.
    func release(_ lease: Lease, discardWhenUnused: Bool) {
        guard var entry = byArchive[lease.key], entry.generation == lease.generation else { return }
        entry.leaseCount = max(0, entry.leaseCount - 1)
        entry.discardWhenUnused = entry.discardWhenUnused || discardWhenUnused
        if entry.leaseCount == 0, entry.discardWhenUnused {
            byArchive[lease.key] = nil
        } else {
            byArchive[lease.key] = entry
        }
    }

    func discard(for archive: URL) {
        byArchive[Self.key(archive)] = nil
    }

    /// Drops the credential only while it still holds `password`.
    ///
    /// Used when the backend proves a password wrong. The match is what makes it
    /// safe to call from a late-arriving failure: by then the user may already
    /// have submitted a replacement, and that newer credential must survive.
    func discard(for archive: URL, ifMatching password: String) {
        let key = Self.key(archive)
        guard byArchive[key]?.password == password else { return }
        byArchive[key] = nil
    }

    func discardAll() {
        byArchive.removeAll()
    }

    var count: Int { byArchive.count }

    private static func key(_ archive: URL) -> String {
        archive.standardizedFileURL.path
    }
}
