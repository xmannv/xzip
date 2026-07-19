import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

extension AppModel {
    // MARK: - New item (folder / file) + Extract to (toolbar)

    /// Whether a "New Folder / New File" action makes sense right now: either a
    /// folder is being browsed, or an archive is open.
    // New File/Folder stays native-only: creating an item inside a compressed
    // tarball would need a full repack per keystroke-sized change.
    var canMakeNewItem: Bool { browsingFolder != nil || currentArchiveAppendsNatively }

    /// Whether files can be added into the currently open archive (drop into
    /// the browser, toolbar Add). Native formats (ZIP/7Z/TAR) append in place;
    /// compressed tarballs (tar.gz, …) go through the repack pipeline. False
    /// for read-only formats (RAR, DMG) and single-stream gz/bz2/xz/zst.
    var canModifyCurrentArchive: Bool {
        guard let url = currentArchive?.url else { return false }
        // Native append (ZIP/7Z/TAR) is content-detected (see
        // currentArchiveAppendsNatively); the tar-wrapper path (.tar.gz …) has no
        // content signature (a tar inside gzip looks like plain gzip), so it
        // stays filename-based.
        return currentArchiveAppendsNatively
            || ArchiveFormat.tarWrapper(fromFilename: url.lastPathComponent) != nil
    }


    /// Whether the archive-comment feature applies to the current archive. ZIP
    /// supports read + edit (via `zip`/`unzip`); RAR is read-only (via 7zz).
    /// Other formats have no archive comment, so the toolbar button is disabled.
    var canCommentCurrentArchive: Bool {
        guard let url = currentArchive?.url,
              let format = ArchiveFormat.infer(fromFilename: url.lastPathComponent) else { return false }
        return format == .zip || format == .rar
    }

    /// True when 7zz can `a` straight into the open archive (ZIP/7Z/TAR), decided
    /// by CONTENT (magic bytes) so a mislabeled archive (a RAR named `.zip`) is
    /// judged by what it is — matching how the read path routes engines — instead
    /// of offering an edit 7zz rejects and Edit & Save Back would then discard.
    private var currentArchiveAppendsNatively: Bool {
        guard let url = currentArchive?.url else { return false }
        return service.detectedFormat(for: url)?.supportsAppending == true
    }

    /// Whether "Extract to" applies right now (an archive is open).
    var canExtractCurrent: Bool { hasOpenArchive }

    /// Present the name-entry sheet for a new folder or file.
    func beginNewItem(_ kind: NewItemRequest.Kind) {
        guard canMakeNewItem else { return }
        newItemRequest = NewItemRequest(kind: kind)
    }

    /// Create the new item once the user confirms a name. Dispatches by mode:
    /// on-disk when browsing a Place, inside the archive when one is open.
    func createNewItem(kind: NewItemRequest.Kind, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if browsingFolder != nil {
            createOnDisk(kind: kind, name: trimmed)
        } else if hasOpenArchive {
            createInArchive(kind: kind, name: trimmed)
        }
    }

    /// Create a real folder/file inside the currently browsed folder.
    private func createOnDisk(kind: NewItemRequest.Kind, name: String) {
        guard let folder = browsingFolder else { return }
        let existing = Set(folderItems.map(\.name))
        let unique = FolderBrowsing.uniqueName(desired: name, existing: existing)
        let target = folder.appendingPathComponent(unique)
        do {
            switch kind {
            case .folder:
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false)
            case .file:
                try Data().write(to: target, options: .withoutOverwriting)
            }
            refreshFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Create an empty folder or file inside the open archive at the current path.
    private func createInArchive(kind: NewItemRequest.Kind, name: String) {
        guard let url = currentArchive?.url else { return }
        let pwd = password.isEmpty ? nil : password
        let folderPath = currentFolderPath
        Task {
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                // Stage the new item under a temp tree mirroring the current
                // in-archive path, then add it relative to that temp root so 7zz
                // stores it at `currentFolderPath/name` instead of the root.
                let relativePath = folderPath.isEmpty ? name : "\(folderPath)/\(name)"
                let item = stage.appendingPathComponent(relativePath, isDirectory: kind == .folder)
                try FileManager.default.createDirectory(
                    at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
                if kind == .folder {
                    try FileManager.default.createDirectory(
                        at: item, withIntermediateDirectories: true)
                } else {
                    try Data().write(to: item)
                }
                try await service.add(files: [item], to: url, password: pwd, workingDirectory: stage)
                self.refreshEntries()
                self.infoMessage = String(localized: "Created \(name).")
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Extract the current open archive to a chosen destination (toolbar
    /// "Extract to" → a Place or a folder chosen via panel).
    func extractCurrentArchive(to destination: URL) {
        guard let archive = currentArchive?.url else { return }
        // Toolbar "Extract to" always extracts the whole archive.
        startExtraction(archive: archive, destination: destination)
    }

    /// Handle a Finder "Extract …" command: open the first selected archive in
    /// the browser and actually extract it to the chosen location (Here /
    /// Downloads). `withPassword` prompts for a password first, then extracts.
    func extractFromFinder(
        paths: [String], destination: AppCommand.ExtractDestination?, withPassword: Bool
    ) {
        // Ignore fabricated paths: any local app can open an `xzip://` URL.
        guard let first = paths.first,
              FileManager.default.fileExists(atPath: first) else { return }
        let archive = URL(fileURLWithPath: first)
        handlePossibleSplitArchive(archive)
        openArchive(archive)
        guard let destination else { return } // nil = open only

        let base = archive.deletingPathExtension().lastPathComponent
        let target: URL
        switch destination {
        case .here:
            target = archive.deletingLastPathComponent().appendingPathComponent(base)
        case .downloads:
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? archive.deletingLastPathComponent()
            target = downloads.appendingPathComponent(base)
        }

        if withPassword {
            // Prompt for the password, then extract to `target` once it's entered.
            pendingExtractionRetry = (url: archive, action: { [weak self] in
                // Relist first: the initial open failed for lack of a password and
                // left the browser empty. Now that the prompt has set it, refresh
                // so the archive's contents actually appear.
                self?.refreshEntries()
                self?.extractCurrentArchive(to: target)
            })
            isPasswordPromptPresented = true
        } else {
            extractCurrentArchive(to: target)
        }
    }
}
