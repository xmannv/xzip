import Foundation
import AppKit
import XZIPCore

/// Implements the "Edit & Save Back" flow from mockup 5a: extract one entry to a
/// temp location, open it in the user's default app, watch the file for saves,
/// and write each change back into the archive.
///
/// Design: an `@Observable` coordinator owned by `AppModel`. It brackets a
/// `DispatchSource` file-system watcher per edited file; when the watched file
/// changes, it re-adds the file to the archive via `ArchiveService`. Sessions
/// are torn down explicitly (or on deinit) so no watchers leak.
@MainActor
@Observable
final class EditSaveBackService {
    /// A live editing session for one extracted entry.
    private final class Session {
        let entryPath: String
        let archive: URL
        let tempFileURL: URL
        let tempRootURL: URL
        var source: DispatchSourceFileSystemObject?
        var fileDescriptor: Int32 = -1
        /// Coalesces overlapping save-backs: a write that arrives while a save is
        /// in flight sets `needsResave` instead of spawning a second concurrent
        /// `7zz a` pass over the same archive.
        var isSaving = false
        var needsResave = false

        init(entryPath: String, archive: URL, tempFileURL: URL, tempRootURL: URL) {
            self.entryPath = entryPath
            self.archive = archive
            self.tempFileURL = tempFileURL
            self.tempRootURL = tempRootURL
        }

        /// Self-contained teardown: cancels the watcher and removes the temp
        /// tree. Runs when the owning `sessions` dictionary releases this
        /// session, so the service needs no (nonisolated) deinit of its own.
        deinit {
            source?.cancel()
            try? FileManager.default.removeItem(at: tempRootURL)
        }
    }

    private let service: ArchiveService
    private var sessions: [String: Session] = [:]

    /// Entry paths that currently have an active edit session (for UI badges).
    private(set) var activeEntryPaths: Set<String> = []

    /// Surfaces a save-back failure to the UI (set by `AppModel`). Without this a
    /// failed write-back was only logged, so the user believed their edit was
    /// saved when it silently was not.
    @ObservationIgnored var onError: ((String) -> Void)?

    init(service: ArchiveService) {
        self.service = service
    }

    /// Whether the given archive supports write-back. Only formats 7zz can UPDATE
    /// in place qualify — the single-stream codecs (`.gz`/`.xz`/`.zst`, including
    /// `.tar.gz`) report E_NOTIMPL on `7zz a`, so offering Edit & Save Back for
    /// them would fail the write-back and lose the user's edits.
    static func canEdit(archive: URL) -> Bool {
        // Detect by CONTENT (magic bytes), not the filename: offering Edit & Save
        // Back for a file 7zz can't UPDATE (a RAR named `.zip`, or a single-stream
        // codec) would fail the write-back and silently lose the user's edits.
        guard let format = ArchiveFormatDetector.detect(fileAt: archive) else {
            return false
        }
        return format.supportsAppending
    }

    /// Begin an edit session: extract `entryPath` from `archive`, open it, and
    /// start watching for writes.
    func beginEditing(entryPath: String, in archive: URL, password: String?) async throws {
        // Tear down any existing session for this entry first so re-editing does
        // not leak the previous file-system watcher (and its retained closures).
        if sessions[entryPath] != nil { endEditing(entryPath: entryPath) }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        var sessionOwnsTempRoot = false
        defer {
            if !sessionOwnsTempRoot {
                try? FileManager.default.removeItem(at: tempRoot)
            }
        }

        let options = ExtractionOptions(password: password, selectedEntries: [entryPath], overwrite: true)
        let stream = try service.extract(archive: archive, destination: tempRoot, options: options)
        for try await _ in stream { /* drain progress */ }

        // `7zz x` preserves the entry's full path, so it lands at
        // tempRoot/<entryPath>, not tempRoot/<basename>.
        let relativePath = entryPath.hasPrefix("/") ? String(entryPath.dropFirst()) : entryPath
        let tempFile = tempRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: tempFile.path) else {
            throw ArchiveEngineError.engineFailure("Could not extract the file for editing.")
        }

        let session = Session(
            entryPath: entryPath, archive: archive,
            tempFileURL: tempFile, tempRootURL: tempRoot)
        startWatching(session, archive: archive, password: password)
        sessions[entryPath] = session
        activeEntryPaths.insert(entryPath)
        sessionOwnsTempRoot = true

        NSWorkspace.shared.open(tempFile)
    }

    /// Stop an edit session and clean up its watcher + temp files.
    func endEditing(entryPath: String) {
        guard let session = sessions[entryPath] else { return }
        session.source?.cancel()
        try? FileManager.default.removeItem(at: session.tempRootURL)
        sessions[entryPath] = nil
        activeEntryPaths.remove(entryPath)
    }

    func endAll() {
        for key in sessions.keys { endEditing(entryPath: key) }
    }

    /// End every edit session belonging to `archive` (called when the archive is
    /// closed or moved to Trash, so a later save never writes into a stale or
    /// trashed file).
    func endEditing(forArchive archive: URL) {
        let standardized = archive.standardizedFileURL
        for (key, session) in sessions where session.archive.standardizedFileURL == standardized {
            endEditing(entryPath: key)
        }
    }

    // MARK: - File watching

    private func startWatching(_ session: Session, archive: URL, password: String?) {
        let fd = open(session.tempFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        session.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        session.source = source

        // Capture `session` weakly: the source is owned BY the session, so a
        // strong capture here forms a session → source → handler → session cycle
        // that keeps the session (and its temp files) alive forever, so the
        // deinit teardown never runs.
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Editor did an atomic save (rename). Re-arm on the new inode.
                source.cancel()
                self.rearm(session, archive: archive, password: password)
                return
            }
            Task { await self.saveBack(session, archive: archive, password: password) }
        }
        // Capture the descriptor by value (not `session`) so cancelling the
        // watcher doesn't keep the session alive.
        source.setCancelHandler {
            if fd >= 0 { close(fd) }
        }
        source.resume()
    }

    /// Re-arm the watcher after an atomic save replaced the file.
    private func rearm(_ session: Session, archive: URL, password: String?) {
        // Give the editor a moment to finish writing the replacement file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.sessions[session.entryPath] != nil else { return }
            if FileManager.default.fileExists(atPath: session.tempFileURL.path) {
                self.startWatching(session, archive: archive, password: password)
                Task { await self.saveBack(session, archive: archive, password: password) }
            }
        }
    }

    /// Write the edited temp file back into the archive at its original path.
    private func saveBack(_ session: Session, archive: URL, password: String?) async {
        // Coalesce rapid successive writes: only one save runs at a time, and a
        // write that lands mid-save schedules exactly one more pass afterwards.
        if session.isSaving { session.needsResave = true; return }
        session.isSaving = true
        defer { session.isSaving = false }
        repeat {
            session.needsResave = false
            do {
                // Run from the temp root with the entry's relative path so 7zz
                // writes the file back in place, not at the archive root.
                let relativePath = session.entryPath.hasPrefix("/")
                    ? String(session.entryPath.dropFirst()) : session.entryPath
                try await service.update(
                    entry: relativePath, from: session.tempRootURL,
                    in: archive, password: password)
            } catch {
                // Surface the failure so the user isn't misled into thinking the
                // edit was saved (the pencil badge stays until they stop editing).
                let message = String(
                    localized: "Couldn’t save “\(session.entryPath)” back into the archive: \(error.localizedDescription)")
                NSLog("XZip Edit&SaveBack failed: \(error.localizedDescription)")
                onError?(message)
            }
        } while session.needsResave
    }

}
