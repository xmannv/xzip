import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

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
        let pwd = password.isEmpty ? nil : password
        let options = ExtractionOptions(
            password: pwd, selectedEntries: entries.map(\.path), overwrite: true)
        do {
            let stream = try service.extract(archive: archive, destination: destination, options: options)
            for try await _ in stream {}
            return entries.compactMap {
                let url = destination.appendingPathComponent(ArchiveBrowsing.relativePath($0))
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// A fresh temp directory for drag-out / Share extractions.
    private func makeDragTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-drag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extract a single entry into `destination` (for Quick Look), calling
    /// `onReady` with the extracted file URL when done.
    func extractEntryForPreview(
        _ entry: ArchiveEntry,
        to destination: URL,
        onReady: @escaping (URL) -> Void
    ) async {
        if let fileURL = await extractFiles([entry], to: destination).first {
            onReady(fileURL)
        }
    }

    /// Extract a single entry to a unique temp dir and return its file URL.
    /// Used by drag-out to Finder (mockup 3c "kéo ngược file ra Finder").
    func extractEntryToTemp(_ entry: ArchiveEntry) async -> URL? {
        await extractFiles([entry], to: makeDragTempDir()).first
    }

    /// Extract several entries to one temp directory in a SINGLE 7zz pass and
    /// return the extracted file URLs. Used by Share / Open-With on a multi
    /// selection so it doesn't spawn (and re-list the whole archive for) one
    /// process per entry.
    func extractEntriesToTemp(_ entries: [ArchiveEntry]) async -> [URL] {
        await extractFiles(entries.filter { !isFolder($0) }, to: makeDragTempDir())
    }

    /// Start an Edit & Save Back session for the given entry (mockup 5a).
    func beginEditSaveBack(_ entry: ArchiveEntry) {
        guard let archive = currentArchive?.url else { return }
        let pwd = password.isEmpty ? nil : password
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
        if let detection = service.detectSplit(part: url) {
            pendingSplitDetection = detection
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
        password = ""
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
        password = ""
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
