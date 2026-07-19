import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

extension AppModel {
    // MARK: - Archive editing (add / delete / rename entries)

    /// Add files into the currently open archive, then refresh the listing.
    func addFilesToArchive(_ files: [URL]) {
        guard let url = currentArchive?.url, !files.isEmpty else { return }
        // One archive mutation at a time (see mutationTask): a second drop, or a
        // delete/rename while this runs, would start a second 7zz rewrite of the
        // same file and race the temp-then-swap, silently losing a change.
        guard mutationTask == nil else {
            errorMessage = String(localized: "Another change to this archive is still in progress. Please wait for it to finish.")
            return
        }
        // Route by CONTENT (magic bytes), matching the read path: a RAR named
        // `.zip` must not take the native-append branch that 7zz would reject.
        let format = service.detectedFormat(for: url)
        if let format, format.supportsAppending {
            let pwd = password.isEmpty ? nil : password
            mutationTask = Task {
                do {
                    try await service.add(files: files, to: url, password: pwd)
                    self.refreshEntries()
                    self.infoMessage = String(localized: "Added \(files.count) items.")
                } catch {
                    self.errorMessage = error.localizedDescription
                }
                self.mutationTask = nil
            }
        } else if ArchiveFormat.tarWrapper(fromFilename: url.lastPathComponent) != nil {
            repackAdd(files, into: url)
        } else {
            // Friendly gate instead of 7zz's raw "E_NOTIMPL" system error.
            errorMessage = String(localized: "Files can't be added to this archive format. Only ZIP, 7Z, TAR, and compressed tarballs (tar.gz, tar.xz, …) support adding files.")
        }
    }

    /// Add files to a compressed tarball via the repack pipeline, driving the
    /// step-by-step progress sheet (`activeRepack`).
    private func repackAdd(_ files: [URL], into url: URL) {
        activeRepack = RepackState(archiveName: url.lastPathComponent, fileCount: files.count)
        mutationTask = Task {
            do {
                try await service.addViaRepack(files: files, to: url) { step in
                    Task { @MainActor in self.activeRepack?.step = step }
                }
                self.refreshEntries()
                self.infoMessage = String(localized: "Added \(files.count) items.")
            } catch is CancellationError {
                self.infoMessage = String(localized: "Update cancelled — archive unchanged.")
            } catch {
                // Present the error only after the progress sheet is gone: a
                // window shows one sheet at a time, so setting `errorMessage`
                // in the same update that dismisses the sheet can race and
                // swallow the error dialog.
                let message = error.localizedDescription
                DispatchQueue.main.async { self.errorMessage = message }
            }
            self.activeRepack = nil
            self.mutationTask = nil
        }
    }

    /// Cancel button in the repack sheet: kills the running 7zz step; the
    /// original archive is untouched (only the final swap mutates it).
    func cancelRepack() {
        activeRepack?.isCancelling = true
        mutationTask?.cancel()
    }

    /// Delete the selected entries from the currently open archive.
    func deleteSelectedEntries() {
        guard let url = currentArchive?.url, !selectedArchiveEntryIDs.isEmpty else { return }
        guard mutationTask == nil else {
            errorMessage = String(localized: "Another change to this archive is still in progress. Please wait for it to finish.")
            return
        }
        // Entry IDs are the in-archive paths. A selected folder row may be a
        // synthesized directory (archives without directory records still show
        // folders in the browser); deleting just its path matches no real entry,
        // so expand each folder to all descendant entries actually present.
        let selected = archiveEntries.filter { selectedArchiveEntryIDs.contains($0.id) }
        var pathSet = Set<String>()
        for entry in selected {
            if entry.kind == .folder {
                let prefix = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
                pathSet.insert(entry.path)
                for child in archiveEntries where child.path.hasPrefix(prefix) {
                    pathSet.insert(child.path)
                }
            } else {
                pathSet.insert(entry.path)
            }
        }
        let paths = Array(pathSet)
        let pwd = password.isEmpty ? nil : password
        mutationTask = Task {
            do {
                try await service.delete(entries: paths, from: url, password: pwd)
                self.selectedArchiveEntryIDs.removeAll()
                self.refreshEntries()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.mutationTask = nil
        }
    }

    /// Rename a single entry within the currently open archive.
    func renameEntry(_ entryPath: String, to newName: String) {
        guard let url = currentArchive?.url, !newName.isEmpty else { return }
        guard mutationTask == nil else {
            errorMessage = String(localized: "Another change to this archive is still in progress. Please wait for it to finish.")
            return
        }
        // Preserve the parent directory, replace only the last component.
        let parent = (entryPath as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
        let pwd = password.isEmpty ? nil : password
        // Renaming a folder must move every descendant too, otherwise the
        // children are orphaned under the old prefix (a synthesized folder row
        // has no entry of its own to rename). 7zz ignores pairs whose source
        // does not exist, so including the folder path itself is harmless.
        let isDirectory = archiveEntries.first { $0.path == entryPath }?.kind == .folder
        let pairs: [(entry: String, newName: String)]
        if isDirectory {
            let oldPrefix = entryPath.hasSuffix("/") ? entryPath : entryPath + "/"
            let newPrefix = newPath.hasSuffix("/") ? newPath : newPath + "/"
            var result: [(entry: String, newName: String)] = [(entryPath, newPath)]
            for child in archiveEntries where child.path.hasPrefix(oldPrefix) {
                result.append((child.path, newPrefix + child.path.dropFirst(oldPrefix.count)))
            }
            pairs = result
        } else {
            pairs = [(entryPath, newPath)]
        }
        mutationTask = Task {
            do {
                try await service.rename(pairs: pairs, in: url, password: pwd)
                self.refreshEntries()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.mutationTask = nil
        }
    }
}
