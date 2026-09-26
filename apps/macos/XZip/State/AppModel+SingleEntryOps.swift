import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore
import XZIPDomain

extension AppModel {
    // MARK: - Single-entry operations

    /// Core: extract `entries` into `destination` in one 7zz pass and return the
    /// extracted file URLs (`7zz x` preserves each entry's full path, so a nested
    /// entry lands at destination/<relative path>, not destination/<basename>).
    /// A failure surfaces via `errorMessage` — the three call sites below used to
    /// each reimplement this pipeline with inconsistent error handling (Quick Look
    /// showed an error, drag-out and Share failed silently).
    private func extractFiles(_ entries: [ArchiveEntry], to destination: URL) async -> [URL] {
        guard let archive = currentArchive?.url, !entries.isEmpty else { return [] }
        let pwd = credential(for: archive)
        let options = ExtractionOptions(
            password: pwd, selectedEntries: entries.map(\.path), overwrite: true)
        do {
            let stream = try service.extract(archive: archive, destination: destination, options: options)
            for try await _ in stream {}
            // Quarantine as soon as the bytes exist, before any URL is handed
            // back. Doing it per exit path missed three of the four (drag-out,
            // Open With, Share all returned unflagged files), and the flag must
            // be in place before the user can launch what was extracted.
            await QuarantineService.apply(
                keepQuarantine: XZIPDefaults.quarantinesApps, at: destination)
            return entries.compactMap { entry in
                // Resolve through containment rather than plain path appending:
                // an archive controls its own entry names, so `../` or an
                // absolute-looking path would otherwise resolve outside
                // `destination` and hand the caller (Quick Look, drag-out,
                // Share) a file the user never asked to expose.
                //
                // The parent walk and the leaf are resolved separately so the
                // result keeps file (not directory) semantics — these URLs go on
                // the drag pasteboard and into Share sheets.
                let relative = ArchiveBrowsing.relativePath(entry) as NSString
                guard let parent = try? ArchivePathContainment.descendantDirectoryURL(
                    root: destination,
                    relativePath: relative.deletingLastPathComponent
                ),
                let url = try? ArchivePathContainment.childURL(
                    parent: parent,
                    component: relative.lastPathComponent
                ) else { return nil }
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } catch let error as ArchiveEngineError {
            switch error {
            case .wrongPassword, .passwordRequired:
                // Ask for the password instead of reporting a generic failure.
                // This path (drag-out, Quick Look, Share, Open With) went
                // straight to `service.extract`, bypassing the prompt/retry layer
                // that "Extract to…" gets from `preflightExtraction` — so an
                // archive whose listing needs no password (ZIP, `7z a -p`) failed
                // here with no way for the user to supply one.
                //
                // No retry closure is armed: the drag session is already over and
                // the `NSItemProvider` promise has been failed, so re-running this
                // extraction would deliver files nobody is waiting for. The user
                // repeats the gesture once the credential is in place.
                if case .wrongPassword = error {
                    invalidateSavedPasswordIfMatching(pwd, for: archive)
                    if let pwd {
                        credentials.discard(for: archive, ifMatching: pwd)
                    }
                }
                presentPasswordPrompt(
                    for: archive,
                    validationContext: .extraction,
                    error: error
                )
            default:
                errorMessage = error.localizedDescription
            }
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Extract a single entry for Quick Look, calling `onReady` with the extracted
    /// file URL when done.
    ///
    /// The directory comes from `scratch`, which releases the previous preview:
    /// these files are decrypted plaintext for an encrypted archive, and every
    /// preview used to leave one behind for the temp reaper to deal with.
    func extractEntryForPreview(
        _ entry: ArchiveEntry,
        onReady: @escaping (URL) -> Void
    ) async {
        guard let destination = scratch.makePreviewDirectory() else {
            errorMessage = String(localized: "Couldn’t prepare a preview location.")
            return
        }
        if let fileURL = await extractFiles([entry], to: destination).first {
            onReady(fileURL)
        }
    }

    /// Extract a nested-archive entry (a .dmg/.zip inside the current archive)
    /// to a scratch export dir and open it in the archive browser.
    ///
    /// The export directory lives until the session ends: the URL stays
    /// registered in the sidebar, and re-listing or extracting from it (e.g. a
    /// DMG re-attaching via hdiutil) needs the file to still be there. The URL
    /// is deliberately not recorded as a recent document — it is a temp path
    /// that stops existing on quit.
    ///
    /// Repeated opens of the same entry reuse the first extraction rather than
    /// minting a second sidebar row for identical temp copies. The memo is
    /// invalidated by the outer archive's mtime: a repack (add/delete/rename)
    /// swaps the file, so a changed timestamp means the extracted copy is stale.
    func openEntryAsArchive(_ entry: ArchiveEntry) async {
        guard ArchiveBrowsing.isArchive(entry),
              let archive = currentArchive?.url else { return }
        let key = "\(archive.path)\n\(entry.path)"
        let archiveModifiedAt = (try? archive.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let memoized = nestedEntryExportURLs[key] {
            if memoized.archiveModifiedAt == archiveModifiedAt {
                openArchive(memoized.url, registersRecentDocument: false)
                return
            }
            // Stale copy: the entry's bytes changed under it. Close the open
            // row so the sidebar doesn't keep browsing the old contents, and
            // free the temp file before re-extracting. `closeArchive` records
            // it in `recentlyClosed`, but that path is about to be deleted, so
            // drop it again — ⇧⌘T must never offer a guaranteed-dead URL.
            if let stale = openArchives.first(where: { $0.url == memoized.url }) {
                closeArchive(stale.id)
                recentlyClosed.removeAll { $0 == memoized.url }
            }
            discardScratchExport(containing: memoized.url)
            nestedEntryExportURLs[key] = nil
        }
        // The memo is written only after extraction, so a second double-click
        // while a slow extract is still running would slip past the check above
        // and extract a second copy. The first task opens the archive anyway;
        // dropping the duplicate gesture loses nothing.
        guard nestedEntryOpensInFlight.insert(key).inserted else { return }
        defer { nestedEntryOpensInFlight.remove(key) }
        if let url = await extractEntryToTemp(entry) {
            nestedEntryExportURLs[key] = (url, archiveModifiedAt)
            openArchive(url, registersRecentDocument: false)
        }
    }

    /// Extract a single entry to a scratch dir and return its file URL.
    /// Used by drag-out to Finder (mockup 3c "kéo ngược file ra Finder").
    ///
    /// A folder arrives as the folder itself, tree intact: dragging `Docs/` to the
    /// Desktop has to deliver `Docs/`, not the files inside it. `extractFiles`
    /// reports one URL per extracted file, so the folder's own directory is
    /// recovered from one of them.
    func extractEntryToTemp(_ entry: ArchiveEntry) async -> URL? {
        let exported = await extractEntriesToTemp([entry])
        guard !exported.isEmpty else { return nil }
        guard isFolder(entry) else { return exported.first }
        return folderExportURL(for: entry, among: exported)
    }

    /// Replaces each selected folder with the file entries beneath it.
    ///
    /// Folders were previously dropped outright, so dragging one out extracted
    /// nothing and the drop failed. Expanding to descendants rather than passing
    /// the folder's own path to 7zz is what makes this work for every archive: a
    /// folder row may be synthesized by `ModelMapping.uiEntries(from:)` for a
    /// directory the archive never recorded, and selecting a path with no entry
    /// behind it matches nothing.
    ///
    /// Nested files are matched by path prefix, mirroring `deleteSelectedEntries`.
    private func expandFoldersToFileEntries(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        let folders = entries.filter { isFolder($0) }
        guard !folders.isEmpty else { return entries }

        let prefixes = folders.map { folder -> String in
            let path = folder.path
            return path.hasSuffix("/") ? path : path + "/"
        }
        var result = entries.filter { !isFolder($0) }
        var seen = Set(result.map(\.path))
        for candidate in archiveEntries where !isFolder(candidate) {
            guard !seen.contains(candidate.path),
                  prefixes.contains(where: { candidate.path.hasPrefix($0) })
            else { continue }
            seen.insert(candidate.path)
            result.append(candidate)
        }
        return result
    }

    /// The extracted directory corresponding to a dragged folder entry.
    ///
    /// Walks an exported file up to the directory named by `entry`, comparing the
    /// component count rather than testing `hasDirectoryPath` — that only inspects
    /// the URL string and reads false for a path built by
    /// `deletingLastPathComponent()`.
    private func folderExportURL(for entry: ArchiveEntry, among exported: [URL]) -> URL? {
        let leaf = (ArchiveBrowsing.relativePath(entry) as NSString).lastPathComponent
        guard !leaf.isEmpty else { return nil }
        for file in exported {
            // Walk up to the nearest ancestor named after the folder. Counting
            // components instead would mix two frames of reference: the entry's
            // depth is relative to the archive root, while a URL's
            // `pathComponents` count starts at the filesystem root.
            //
            // `hasDirectoryPath` is deliberately not used to confirm the hit — it
            // only inspects the URL string, and reads false for a path produced by
            // `deletingLastPathComponent()`. The filesystem is asked instead.
            var candidate = file.deletingLastPathComponent()
            while candidate.pathComponents.count > 1 {
                if candidate.lastPathComponent == leaf {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: candidate.path,
                        isDirectory: &isDirectory
                    )
                    if exists, isDirectory.boolValue { return candidate }
                }
                candidate = candidate.deletingLastPathComponent()
            }
        }
        return nil
    }

    func discardScratchExport(containing fileURL: URL) {
        scratch.discardExport(containing: fileURL)
    }

    /// Extract several entries to one scratch directory in a SINGLE 7zz pass and
    /// return the extracted file URLs. Used by Share / Open-With on a multi
    /// selection so it doesn't spawn (and re-list the whole archive for) one
    /// process per entry.
    ///
    /// Export directories live until the app quits, unlike previews: these URLs go
    /// onto the drag pasteboard or into a Share sheet, and the receiving app may
    /// read them long after the gesture finishes.
    func extractEntriesToTemp(_ entries: [ArchiveEntry]) async -> [URL] {
        let files = expandFoldersToFileEntries(entries)
        guard !files.isEmpty else { return [] }
        guard let destination = scratch.makeExportDirectory() else {
            errorMessage = String(localized: "Couldn’t prepare a temporary location.")
            return []
        }
        let exported = await extractFiles(files, to: destination)
        guard !Task.isCancelled, !exported.isEmpty else {
            scratch.discardExportDirectory(destination)
            return []
        }
        return exported
    }

    /// Start an Edit & Save Back session for the given entry (mockup 5a).
    func beginEditSaveBack(_ entry: ArchiveEntry) {
        guard let archive = currentArchive?.url else { return }
        // The session snapshots this credential for the lifetime of the edit
        // (see EditSaveBackService.startWatching): save-back must still work if
        // the user closes the archive while the external editor is open, so it
        // deliberately does not re-read the store later.
        let pwd = credential(for: archive)
        Task {
            do {
                try await editSaveBack.beginEditing(entryPath: entry.path, in: archive, password: pwd)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Detect whether `url` is one part of a split archive; if so, present Join.
    func handlePossibleSplitArchive(_ url: URL) {
        do {
            if let detection = try service.detectSplit(part: url) {
                pendingSplitDetection = detection
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Join detected split parts into a single archive, tracking progress in the
    /// queue; optionally open the joined archive when done (mockup 4b).
    func joinSplitParts(_ parts: [URL], to destination: URL, openAfter: Bool) {
        let op = ArchiveOperation(
            title: String(localized: "Joining \(destination.lastPathComponent)"),
            kind: .compress, state: .running, progress: 0,
            currentItem: String(localized: "Starting…"),
            detail: String(localized: "\(parts.count) parts"))
        // Open the joined archive only once the join actually finishes (via the
        // operation's completion hook), instead of racing a fixed 300ms sleep
        // that opens a still-being-written file for multi-GB joins.
        run(op, outputURL: destination, onComplete: { [weak self] url in
            guard openAfter, let self, let url else { return }
            self.openArchive(url)
        }) { [service] in
            service.joinSplit(parts: parts, destination: destination)
        }
    }

    /// Stage `urls` as compression inputs and present the compress sheet
    /// (empty-state drop zone / New Archive flow, mockup 1d → 1e).
    func beginCompress(with urls: [URL], format: CompressionFormat? = nil) {
        clearCompressionInputs()
        addInputs(urls)
        // Reset the draft to saved defaults each time the sheet opens; a caller
        // (e.g. Finder "Compress to 7Z…") may pin a specific starting format so
        // the sheet actually matches the menu item's promise.
        selectedFormat = format ?? XZIPDefaults.format
        selectedLevel = XZIPDefaults.level
        excludeMacNoise = XZIPDefaults.excludesMacNoise
        encryptionEnabled = false
        compressionPassword = ""
        splitArchiveEnabled = false
        isCompressSheetPresented = true
    }

    /// One-shot compress from the Finder "Compress to X.zip" item: no dialog,
    /// straight to a .zip using the saved defaults (level, exclude-noise,
    /// timestamps). Mirrors the state `beginCompress` sets, then kicks off the
    /// job directly instead of presenting the sheet.
    func quickCompress(with urls: [URL]) {
        clearCompressionInputs()
        addInputs(urls)
        selectedFormat = .zip
        selectedLevel = XZIPDefaults.level
        excludeMacNoise = XZIPDefaults.excludesMacNoise
        encryptionEnabled = false
        compressionPassword = ""
        splitArchiveEnabled = false
        isCompressSheetPresented = false
        startCompression(quiet: true)
    }

    var selectedPreset: ArchivePreset? {
        get { presets.first(where: { $0.id == selectedPresetID }) }
        set {
            guard let newValue,
                  let index = presets.firstIndex(where: { $0.id == newValue.id }) else { return }
            presets[index] = newValue
        }
    }

    func addInputs(_ urls: [URL]) {
        let existing = Set(compressionInputs.map(\.url))
        let additions = urls
            .filter { !existing.contains($0) }
            .map { InputItem(url: $0) }
        compressionInputs.append(contentsOf: additions)
    }

    func removeInput(_ item: InputItem) {
        compressionInputs.removeAll { $0.id == item.id }
    }

    func clearCompressionInputs() {
        compressionInputs.removeAll()
    }

    /// Generate a strong random password (delegates to the Core generator).
    func generatePassword() -> String {
        PasswordGenerator.generate()
    }
}
