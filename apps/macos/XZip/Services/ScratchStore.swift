import Foundation
import os

/// Owns the temp directories holding entries extracted out of an archive for
/// Quick Look, drag-out, Open With and Share.
///
/// These files are decrypted plaintext when the archive is encrypted, and nothing
/// used to remove them: every preview and every drag minted a fresh
/// `xzip-ql-<uuid>` or `xzip-drag-<uuid>` directory that stayed for as long as the
/// system's temp reaper allowed, which is days.
///
/// Why not delete each file as soon as its consumer is done: for drag-out and
/// Share the URL goes onto the pasteboard, and the receiving app may not read it
/// until well after the gesture ends — Finder copies lazily. Deleting eagerly
/// there would break the drop. So the lifetime is the session, with one
/// exception: Quick Look previews only one file at a time, so starting a new
/// preview releases the previous one.
///
/// Everything lives under a single per-session root, which makes both cleanups
/// one `removeItem` rather than bookkeeping over scattered directories.
@MainActor
final class ScratchStore {

    /// Prefix shared by every session root, so a previous run's leftovers are
    /// recognisable at launch.
    static let rootPrefix = "xzip-scratch-"

    private let parent: URL
    private let logger = Logger(subsystem: "com.codetay.xzip", category: "scratch")
    private lazy var root: URL = parent
        .appendingPathComponent("\(Self.rootPrefix)\(UUID().uuidString)", isDirectory: true)
    private var previousPreview: URL?
    private var exportDirectories: Set<URL> = []

    /// - Parameter parent: where session roots are created. Injectable so tests do
    ///   not write into the real temp directory.
    init(parent: URL = FileManager.default.temporaryDirectory) {
        self.parent = parent
    }

    /// A fresh directory for a Quick Look preview, releasing the previous one.
    ///
    /// Safe because Quick Look shows a single file: by the time a new preview is
    /// requested the panel has moved on, so the old plaintext has no reader.
    func makePreviewDirectory() -> URL? {
        if let previousPreview {
            remove(previousPreview)
        }
        let directory = makeDirectory(named: "preview")
        previousPreview = directory
        return directory
    }

    /// A fresh directory for drag-out / Open With / Share.
    ///
    /// Kept until the session ends: the URL is handed to another process, which
    /// may read it at any point after.
    func makeExportDirectory() -> URL? {
        guard let directory = makeDirectory(named: "export") else { return nil }
        exportDirectories.insert(directory.standardizedFileURL)
        return directory
    }

    /// Discard a provisional export that was never handed to a consumer.
    func discardExportDirectory(_ directory: URL) {
        let standardized = directory.standardizedFileURL
        guard exportDirectories.remove(standardized) != nil else { return }
        remove(standardized)
    }

    /// Find the owned export root containing a nested extracted file and discard
    /// the whole export, not merely that file's immediate parent directory.
    func discardExport(containing fileURL: URL) {
        let filePath = fileURL.standardizedFileURL.path
        guard let directory = exportDirectories.first(where: {
            filePath.hasPrefix($0.path + "/")
        }) else { return }
        discardExportDirectory(directory)
    }

    /// Hands the session's directories to the caller for deletion elsewhere, and
    /// forgets them.
    ///
    /// Exists so quitting can delete this tree off the main thread: `removeAll`
    /// does the work inline, and a recursive delete over a large extracted tree
    /// stalls the main thread long enough for AppKit to show a beachball. The
    /// store stops tracking what it returns, so the later `removeAll` backstop in
    /// `applicationWillTerminate` finds nothing to repeat.
    ///
    /// Returns an empty array when nothing was ever minted — `root` is lazy, and
    /// touching it would create the directory just to delete it.
    func takeRootsForTermination() -> [URL] {
        defer {
            previousPreview = nil
            exportDirectories.removeAll()
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let taken = root
        // Re-point `root` so anything minted during the quit lands somewhere the
        // caller is not already deleting.
        root = parent.appendingPathComponent(
            "\(Self.rootPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        return [taken]
    }

    /// Remove everything this session created. Called on quit.
    func removeAll() {
        // `root` is lazy, so touching it here would create the directory just to
        // delete it. Nothing was ever minted if it does not exist.
        guard FileManager.default.fileExists(atPath: root.path) else {
            previousPreview = nil
            exportDirectories.removeAll()
            return
        }
        remove(root)
        previousPreview = nil
        exportDirectories.removeAll()
    }

    /// Remove session roots left behind by earlier runs that crashed or were
    /// force-quit, so plaintext does not accumulate across launches.
    ///
    /// Skips this session's own root, which is in use.
    func pruneStaleRoots() {
        for stale in Self.staleRoots(in: parent, excluding: root) {
            remove(stale)
        }
    }

    /// The session roots under `parent` that belong to an earlier run.
    ///
    /// Separated out so the matching rule is testable: this deletes directories,
    /// and the prefix must not be allowed to match something the user owns.
    static func staleRoots(in parent: URL, excluding current: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let currentPath = current.standardizedFileURL.path
        return contents.filter { candidate in
            // Exact prefix on the last component only: a directory called
            // `my-xzip-scratch-notes` elsewhere in the name must not match.
            guard candidate.lastPathComponent.hasPrefix(rootPrefix),
                  candidate.lastPathComponent != rootPrefix,
                  candidate.standardizedFileURL.path != currentPath,
                  (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?
                      .isDirectory == true
            else { return false }
            return true
        }
    }

    private func makeDirectory(named kind: String) -> URL? {
        let directory = root.appendingPathComponent(
            "\(kind)-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            return directory
        } catch {
            // Returning nil rather than a path that does not exist: the caller
            // would otherwise extract into nowhere and report a confusing failure.
            logger.error("Could not create scratch directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func remove(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Already gone (temp reaper, or a previous removeAll). Not a problem.
        } catch {
            // Best effort: a failure here leaves plaintext behind, so it is worth
            // recording, but there is nothing to ask the user to do about it. The
            // path is private — it embeds an entry name from the user's archive.
            logger.error(
                "Could not remove scratch directory \(directory.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
