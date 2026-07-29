import Foundation

/// Applies the "Quarantine apps extracted from archives" preference to freshly
/// extracted files.
///
/// Design: archives created on the same Mac don't normally carry the
/// `com.apple.quarantine` xattr, so extracted executables can bypass
/// Gatekeeper's first-run check. When the preference is ON we *add* the flag to
/// extracted apps/executables so macOS vets them on first launch; when OFF we
/// *remove* any existing flag so they open without the "downloaded from the
/// internet" prompt. Runs off the main actor since it walks the file tree and
/// touches xattrs via POSIX APIs.
enum QuarantineService {
    /// The quarantine value macOS writes: flags;timestamp;agent;UUID. We use a
    /// minimal, well-formed value (type 0081 = "other downloaded file").
    private static func quarantineValue() -> String {
        let ts = String(format: "%08x", UInt32(Date().timeIntervalSince1970))
        return "0081;\(ts);XZip;\(UUID().uuidString)"
    }

    /// Apply the preference to everything under `root`, returning only once the
    /// whole tree has been processed. Callers await this before revealing or
    /// opening the extracted files, so a launchable item can't be opened in the
    /// window before its quarantine flag is set. `keepQuarantine == true` adds
    /// the flag to apps/executables; `false` strips it from every item.
    static func apply(keepQuarantine: Bool, at root: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                applyOne(keepQuarantine: keepQuarantine, url: root)
                if let items = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey, .isSymbolicLinkKey],
                    options: []) {
                    for case let url as URL in items {
                        applyOne(keepQuarantine: keepQuarantine, url: url)
                    }
                }
                continuation.resume()
            }
        }
    }

    private static let key = "com.apple.quarantine"

    private static func applyOne(keepQuarantine: Bool, url: URL) {
        let values = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isExecutableKey])
        // Never operate through a symlink: a malicious archive can ship a symlink
        // pointing outside the extraction tree, and following it would let us
        // add/strip quarantine on an arbitrary file elsewhere on disk. All xattr
        // calls also pass XATTR_NOFOLLOW as defense in depth.
        if values?.isSymbolicLink == true { return }
        if keepQuarantine {
            // Quarantine EVERY regular file (not directories, not symlinks). An
            // allowlist of "launchable" extensions plus the executable bit misses
            // real launch vectors: Mach-O binaries and dylibs without the exec
            // bit, .jar, .terminal/.inetloc/.webloc/.fileloc, .applescript, etc.
            // Flagging all extracted files is safe — a non-executable file's
            // quarantine record produces no launch prompt — and correctly says
            // "these came from a downloaded archive" so Gatekeeper vets whatever
            // turns out to be launchable.
            let isDirectory = values?.isDirectory ?? false
            guard !isDirectory else { return }
            // Don't clobber an existing quarantine record.
            guard getxattrValue(url) == nil else { return }
            let value = quarantineValue()
            _ = value.withCString { cstr in
                setxattr(url.path, key, cstr, strlen(cstr), 0, XATTR_NOFOLLOW)
            }
        } else {
            _ = removexattr(url.path, key, XATTR_NOFOLLOW)
        }
    }

    /// Return the current quarantine xattr value, or nil if unset.
    private static func getxattrValue(_ url: URL) -> String? {
        let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes {
            getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW)
        }
        guard result > 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
