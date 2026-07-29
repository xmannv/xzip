import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore
import XZIPDomain

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
        do {
            let validated = try ArchiveComponentValidator.validate(name)
            if browsingFolder != nil {
                createOnDisk(kind: kind, name: validated)
            } else if hasOpenArchive {
                createNewItemInArchive(kind: kind, name: validated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Create a real folder/file inside the currently browsed folder.
    private func createOnDisk(kind: NewItemRequest.Kind, name: String) {
        guard let folder = browsingFolder else { return }
        let existing = Set(folderItems.map(\.name))
        let unique = FolderBrowsing.uniqueName(desired: name, existing: existing)
        do {
            let validated = try ArchiveComponentValidator.validate(unique)
            let target = try ArchivePathContainment.childURL(
                parent: folder,
                component: validated
            )
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
    ///
    /// Internal rather than private because "New Folder from Selection" routes
    /// here too: that action used to carry its own copy of this staging pipeline
    /// and drifted out of sync with it (notably, it never took the archive's
    /// turn at the mutation gate).
    func createNewItemInArchive(kind: NewItemRequest.Kind, name: String) {
        guard let url = currentArchive?.url else { return }
        let pwd = credential(for: url)
        let folderPath = currentFolderPath
        Task { [weak self] in
            guard let self else { return }
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                let validated = try ArchiveComponentValidator.validate(name)
                let standardizedStage = stage.standardizedFileURL
                let destinationDirectory = try ArchivePathContainment.descendantDirectoryURL(
                    root: standardizedStage,
                    relativePath: folderPath
                )
                let item = try ArchivePathContainment.childURL(
                    parent: destinationDirectory,
                    component: validated
                )
                try FileManager.default.createDirectory(
                    at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
                if kind == .folder {
                    try FileManager.default.createDirectory(
                        at: item, withIntermediateDirectories: true)
                } else {
                    try Data().write(to: item)
                }
                // Creating an entry rewrites the archive just like
                // add / delete / rename, so it takes the same per-archive turn.
                // User-driven, so a busy archive refuses rather than queues.
                try await self.service.add(
                    files: [item],
                    to: url,
                    password: pwd,
                    workingDirectory: standardizedStage,
                    admission: .refuseIfBusy
                )
                self.refreshEntries()
                self.infoMessage = String(localized: "Created \(validated).")
            } catch is ArchiveMutationGate.ArchiveBusyError {
                self.reportArchiveBusy()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Extract the current open archive to a chosen destination (toolbar
    /// "Extract to" → a Place or a folder chosen via panel).
    func extractCurrentArchive(to destination: URL) {
        guard let archive = currentArchive?.url else { return }
        // Toolbar "Extract to" always extracts the whole archive, into a folder
        // named after it rather than loose into the chosen folder.
        startExtraction(
            archive: archive,
            destination: ExtractionDestination.folder(for: archive, in: destination)
        )
    }

    /// Handle a Finder "Extract …" command: open the first selected archive in
    /// the browser and actually extract it to the chosen location (Here /
    /// Downloads). `withPassword` prompts for a password first, then extracts.
    ///
    /// This is the boundary where a request from outside the app turns into work
    /// on the user's files, so it is also where a remembered password stops being
    /// free to spend. See `requiresPresenceToSpendSavedPassword(for:)`.
    func extractFromFinder(
        paths: [String], destination: AppCommand.ExtractDestination?, withPassword: Bool
    ) {
        // Ignore fabricated paths: any local app can open an `xzip://` URL.
        guard let first = paths.first,
              FileManager.default.fileExists(atPath: first) else { return }
        let archive = URL(fileURLWithPath: first)

        // Extracting an archive whose password we remember would hand the caller
        // plaintext it could not produce itself: the Keychain item is scoped to
        // this app's signature, but the extraction output is an ordinary file the
        // caller can read. Any local process can open an `xzip://` URL, and we
        // cannot authenticate one (no sandbox, same user), so authenticate the
        // *user* instead, before the credential is spent.
        //
        // Deliberately gates both branches. `withPassword` looks like it already
        // involves the user, but it reaches `openArchive` first, and a remembered
        // password can satisfy the listing before the prompt is ever answered.
        if requiresPresenceToSpendSavedPassword(for: archive) {
            Task { @MainActor in
                let reason = String(
                    localized: "Authenticate to extract \(archive.lastPathComponent) with its saved password"
                )
                guard await authenticator(reason) else {
                    // Not an error: declining is a legitimate answer. But it has to
                    // be visible, otherwise a Finder command appears to do nothing.
                    infoMessage = String(
                        localized: "Didn’t extract \(archive.lastPathComponent) — authentication was needed to use its saved password."
                    )
                    return
                }
                performFinderExtraction(
                    archive: archive,
                    destination: destination,
                    withPassword: withPassword,
                    allowRememberedCredential: true
                )
            }
            return
        }
        performFinderExtraction(
            archive: archive,
            destination: destination,
            withPassword: withPassword,
            allowRememberedCredential: false
        )
    }

    /// Whether this external command could decrypt data using a credential the app
    /// already has, either in this session or in the Keychain vault.
    ///
    /// User presence is checked for every external extraction. A password typed
    /// earlier proves the user knew it then; it does not authorize a later request
    /// from an unauthenticated local process. When neither source has a credential,
    /// the ordinary unencrypted Finder case stays promptless.
    private func requiresPresenceToSpendSavedPassword(for archive: URL) -> Bool {
        credential(for: archive) != nil
            || service.savedPassword(for: vaultKey(for: archive)) != nil
    }

    private func performFinderExtraction(
        archive: URL,
        destination: AppCommand.ExtractDestination?,
        withPassword: Bool,
        allowRememberedCredential: Bool
    ) {
        handlePossibleSplitArchive(archive)
        openArchive(
            archive,
            allowRememberedCredential: allowRememberedCredential
        )
        guard let destination else { return } // nil = open only

        let target: URL
        switch destination {
        case .here:
            target = ExtractionDestination.folderBesideArchive(archive)
        case .downloads:
            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? archive.deletingLastPathComponent()
            target = ExtractionDestination.folder(for: archive, in: downloads)
        }

        if withPassword {
            // Prompt for the password, then extract the captured archive to
            // `target` even if the user selects another archive meanwhile.
            presentPasswordPrompt(
                for: archive,
                validationContext: .extraction
            ) { [weak self] in
                guard let self else { return }
                // Relist only when this archive is still visible. A later archive
                // selection must not redirect either listing or extraction.
                if self.currentArchive?.url == archive {
                    self.refreshEntries()
                }
                self.startExtraction(archive: archive, destination: target)
            }
        } else {
            startExtraction(
                archive: archive,
                destination: target,
                allowRememberedCredential: allowRememberedCredential
            )
        }
    }
}
