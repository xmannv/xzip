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

    /// Extract a single entry to a scratch dir and return its file URL.
    /// Used by drag-out to Finder (mockup 3c "kéo ngược file ra Finder").
    func extractEntryToTemp(_ entry: ArchiveEntry) async -> URL? {
        await extractEntriesToTemp([entry]).first
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
        let files = entries.filter { !isFolder($0) }
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
