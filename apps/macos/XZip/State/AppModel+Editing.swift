import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore
import XZIPDomain

extension AppModel {
    // MARK: - Archive editing (add / delete / rename entries)

    /// Add files into the currently open archive, then refresh the listing.
    func addFilesToArchive(_ files: [URL]) {
        guard let url = currentArchive?.url, !files.isEmpty else { return }
        // Route by CONTENT (magic bytes), matching the read path: a RAR named
        // `.zip` must not take the native-append branch that 7zz would reject.
        let format = service.detectedFormat(for: url)
        if let format, format.supportsAppending {
            let pwd = credential(for: url)
            // One mutation at a time per archive: a second drop, or a
            // delete/rename while this runs, would start a second 7zz rewrite of
            // the same file and race the temp-then-swap, silently losing a
            // change. `ArchiveService` takes the turn itself; this path only
            // chooses the policy — a drop is user-driven, so being told to retry
            // beats queueing work the user may no longer want.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.service.add(
                        files: files, to: url, password: pwd, admission: .refuseIfBusy)
                    self.refreshEntries()
                    self.infoMessage = String(localized: "Added \(files.count) items.")
                } catch is ArchiveMutationGate.ArchiveBusyError {
                    self.reportArchiveBusy()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
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
        // Double-submit guard, and it must be `repackArchive` rather than
        // `mutationGate.isMutating`: the gate is now claimed inside the async
        // `addViaRepack`, so `isMutating` still reads false for a turn after this
        // method returns. This method has side effects before that claim (it
        // raises the progress sheet), so a second drop landing in that window
        // would pass the check, overwrite the sheet state, then have its own
        // claim refused — and its teardown would dismiss the sheet belonging to
        // the repack that is still running, leaving `cancelRepack` with no
        // target. `repackArchive` is set below in this same turn, so no such
        // window exists.
        guard repackArchive == nil else {
            reportArchiveBusy()
            return
        }
        repackArchive = url
        activeRepack = RepackState(archiveName: url.lastPathComponent, fileCount: files.count)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.addViaRepack(
                    files: files, to: url, admission: .refuseIfBusy
                ) { step in
                    Task { @MainActor in self.activeRepack?.step = step }
                }
                self.refreshEntries()
                self.infoMessage = String(localized: "Added \(files.count) items.")
            } catch is CancellationError {
                self.infoMessage = String(localized: "Update cancelled — archive unchanged.")
            } catch let busy as ArchiveMutationGate.ArchiveBusyError {
                // Lost the race with another mutation admitted between the
                // pre-check and the claim; the sheet is torn down below, so this
                // message has to wait for the dismissal like the errors do.
                let message = busy.localizedDescription
                DispatchQueue.main.async { self.errorMessage = message }
            } catch {
                // Present the error only after the progress sheet is gone: a
                // window shows one sheet at a time, so setting `errorMessage`
                // in the same update that dismisses the sheet can race and
                // swallow the error dialog.
                let message = error.localizedDescription
                DispatchQueue.main.async { self.errorMessage = message }
            }
            self.activeRepack = nil
            self.repackArchive = nil
        }
    }

    /// Cancel button in the repack sheet: kills the running 7zz step; the
    /// original archive is untouched (only the final swap mutates it).
    func cancelRepack() {
        activeRepack?.isCancelling = true
        if let url = repackArchive { mutationGate.cancel(archive: url) }
    }

    /// Delete the selected entries from the currently open archive.
    func deleteSelectedEntries() {
        guard let url = currentArchive?.url, !selectedArchiveEntryIDs.isEmpty else { return }
        // Entry IDs are the in-archive paths. A selected folder row may be a
        // synthesized directory (archives without directory records still show
        // folders in the browser); deleting just its path matches no real entry,
        // so expand each folder to all descendant entries actually present.
        let selected = archiveEntries.filter { selectedArchiveEntryIDs.contains($0.id) }
        var pathSet = Set<String>()
        let selectedPrefixes = selected
            .filter { $0.kind == .folder }
            .map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        for entry in selected { pathSet.insert(entry.path) }
        if !selectedPrefixes.isEmpty {
            // Sort both sides once and sweep them together instead of rescanning
            // every entry for each selected folder: selecting many folders in a
            // large archive made that quadratic (100k entries × 1k folders).
            // Sorted order means all descendants of a prefix form one contiguous
            // run, so each entry is visited a bounded number of times.
            let sortedPrefixes = selectedPrefixes.sorted()
            let sortedPaths = archiveEntries.map(\.path).sorted()
            var index = 0
            for prefix in sortedPrefixes {
                // Skip past entries that sort before this prefix; they can only
                // belong to an earlier prefix, which already consumed them.
                while index < sortedPaths.count, sortedPaths[index] < prefix {
                    index += 1
                }
                var scan = index
                while scan < sortedPaths.count, sortedPaths[scan].hasPrefix(prefix) {
                    pathSet.insert(sortedPaths[scan])
                    scan += 1
                }
            }
        }
        let paths = Array(pathSet)
        let pwd = credential(for: url)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.delete(
                    entries: paths, from: url, password: pwd, admission: .refuseIfBusy)
                self.selectedArchiveEntryIDs.removeAll()
                self.refreshEntries()
            } catch is ArchiveMutationGate.ArchiveBusyError {
                self.reportArchiveBusy()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Rename a single entry within the currently open archive.
    func renameEntry(_ entryPath: String, to newName: String) {
        guard let url = currentArchive?.url else { return }
        let validated: String
        do {
            validated = try ArchiveComponentValidator.validate(newName)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Preserve the parent directory, replace only the last component.
        let parent = (entryPath as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? validated : "\(parent)/\(validated)"
        let pwd = credential(for: url)
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.rename(
                    pairs: pairs, in: url, password: pwd, admission: .refuseIfBusy)
                self.refreshEntries()
            } catch is ArchiveMutationGate.ArchiveBusyError {
                self.reportArchiveBusy()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
