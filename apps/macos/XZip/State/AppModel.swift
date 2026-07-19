import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

@MainActor
@Observable
final class AppModel {
    var searchText = ""

    // MARK: - New archive-browser UI state (design spec)

    /// Sidebar (Places) is hidden by default; toggled with ⌥⌘S (mockup 2a).
    var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Favorite extraction destinations shown in the Places section.
    var places: [Place] = []
    /// Archives currently open, shown in the Open Archives section.
    var openArchives: [OpenArchive] = []
    /// The archive whose contents are shown in the main browser.
    var currentArchiveID: OpenArchive.ID?
    /// Whether the compress sheet (mockup 1e) is presented.
    var isCompressSheetPresented = false
    /// Whether the Queue popover (anchored to the toolbar queue button,
    /// replaces the old separate Queue window) is shown.
    var isQueuePopoverPresented = false
    /// Whether the password prompt (mockup 3a) is presented.
    var isPasswordPromptPresented = false
    /// Extraction to re-run after the user supplies a password for the archive
    /// whose extract failed on a password error. URL-scoped so a stale retry
    /// never fires for a different archive; consumed by `passwordPromptDidSubmit()`.
    var pendingExtractionRetry: (url: URL, action: @MainActor () -> Void)?
    /// Split-archive detection result driving the Join sheet (mockup 4b).
    var pendingSplitDetection: SplitArchiveJoiner.DetectionResult?
    /// Archive whose comment popover is presented (mockup 4a).
    var commentTarget: CommentTarget?
    /// Info for the post-compress Share card (mockup 4c); nil hides it.
    var shareArchive: ShareArchiveInfo?
    /// Pending extraction conflict prompt (mockup 3b); nil hides it.
    var pendingConflict: ConflictPrompt?
    /// The folder currently browsed inside the archive (mockup 1b breadcrumb).
    /// Empty string = archive root. Uses POSIX-style "a/b" (no leading slash).
    var currentFolderPath: String = ""

    // MARK: - Places folder browser (mockup 2a, BetterZip-style)

    /// The favorite folder currently browsed on disk; nil = not in folder mode.
    /// When set, the detail pane shows `FolderBrowserView` instead of an archive.
    var browsingFolder: URL?
    /// Contents (files + folders) of `browsingFolder`, sorted for display.
    var folderItems: [FileItem] = []
    /// Selection within the folder browser (real file URLs).
    var selectedFolderItemIDs: Set<FileItem.ID> = []
    /// Navigation history so the folder browser can go Back / Up.
    private var folderBackStack: [URL] = []
    /// Drives the "New Folder / New File" name-entry sheet; nil hides it.
    var newItemRequest: NewItemRequest?

    var compressionInputs: [InputItem] = []

    var selectedFormat: CompressionFormat = .zip
    var selectedLevel: CompressionLevel = .balanced
    var encryptionEnabled = false
    var password = ""
    var excludeMacNoise = true
    var splitArchiveEnabled = false
    var splitSizeMB = 100
    var conflictPolicy: ConflictPolicy = .ask

    var selectedArchiveEntryIDs: Set<ArchiveEntry.ID> = []
    var archiveEntries: [ArchiveEntry] = [] {
        didSet {
            archiveEntriesVersion &+= 1
            // Compute O(n) aggregates ONCE per new listing. Status bar / toolbar
            // body renders happen for selection, hover, search, window changes;
            // reducing a 100k-entry array on every render caused needless churn.
            archiveTotalOriginalSize = ByteCountMath.sum(
                archiveEntries.lazy.map(\.originalSize)
            )
            archiveTotalCompressedSize = ByteCountMath.sum(
                archiveEntries.lazy.map(\.compressedSize)
            )
        }
    }
    private(set) var archiveTotalOriginalSize: Int64 = 0
    private(set) var archiveTotalCompressedSize: Int64 = 0
    /// Bumped whenever `archiveEntries` is replaced. Lets views detect a new
    /// listing with an O(1) integer compare instead of diffing a 100k-entry
    /// array on every render.
    private(set) var archiveEntriesVersion = 0
    /// True while `refreshEntries()` is listing an archive's contents. Drives the
    /// browser's loading state so opening a slow archive (e.g. a DMG that must be
    /// attached via `hdiutil`) shows a spinner instead of a blank pane.
    var isLoadingEntries = false
    /// Bumped on every `refreshEntries` call so a slow, superseded listing task
    /// can tell it is stale and must not clear `isLoadingEntries` for the archive
    /// that is currently loading.
    private var listingGeneration = 0
    var presets: [ArchivePreset] = []
    var operations: [ArchiveOperation] = []

    /// User-facing error surfaced from backend operations, shown as an alert.
    var errorMessage: String?
    /// Non-nil while files are being added to a compressed tarball; drives the
    /// step-by-step repack progress sheet.
    var activeRepack: RepackState?
    /// Handle for the in-flight repack so the sheet's Cancel can stop it.
    /// The single in-flight archive mutation (add / delete / rename / repack).
    /// Kept so a second mutation can't start while one runs — two concurrent 7zz
    /// rewrites of the same file would race on the temp-then-swap and silently
    /// lose a change or corrupt the archive. Cancellable (repack progress sheet).
    var mutationTask: Task<Void, Never>?
    /// Transient confirmation banner text (e.g. "Archive is intact").
    var infoMessage: String?

    var selectedPresetID: ArchivePreset.ID?

    /// Keys (archive filenames) that have a password saved in the Keychain vault.
    var vaultKeys: [String] = []

    // MARK: - Backend

    /// The backend facade. Not observed — it holds no UI state.
    @ObservationIgnored let service: ArchiveService
    /// Tracks running operation tasks so they can be cancelled by ID.
    @ObservationIgnored var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic per-operation counter. A retried operation reuses the same id
    /// with a new task; the generation lets the OLD task's teardown avoid
    /// clearing the NEW task's handle (which would leave the retry uncancellable).
    @ObservationIgnored var taskGenerations: [UUID: Int] = [:]
    /// Stores the work needed to re-run a failed operation (Retry, mockup 1f).
    /// Main-actor isolated (not `@Sendable`): only invoked from `retryOperation`.
    @ObservationIgnored var retryActions: [UUID: () -> Void] = [:]

    /// Places repository (security-scoped bookmarks).
    @ObservationIgnored let placesStore: PlacesStore
    /// Coordinates the Edit & Save Back flow (mockup 5a).
    @ObservationIgnored lazy var editSaveBack = EditSaveBackService(service: service)

    init(service: ArchiveService = .live(), placesStore: PlacesStore = PlacesStore()) {
        self.service = service
        self.placesStore = placesStore
        self.presets = service.presetStore.load().map(ModelMapping.uiPreset(from:))
        self.vaultKeys = service.vaultKeys().sorted()
        // Seed the compression draft from the user's saved defaults.
        self.selectedFormat = XZIPDefaults.format
        self.selectedLevel = XZIPDefaults.level
        self.excludeMacNoise = XZIPDefaults.excludesMacNoise
        self.conflictPolicy = XZIPDefaults.conflictPolicyValue
        self.places = placesStore.load()
        // Surface Edit & Save Back write-back failures instead of only logging.
        editSaveBack.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // Clear files the Share extension staged into the App Group container on
        // previous runs so they don't accumulate.
        XZIPAppGroup.pruneSharedInbox()
    }

    // MARK: - Open archives + sidebar

    /// The currently displayed open archive, if any.
    var currentArchive: OpenArchive? {
        openArchives.first { $0.id == currentArchiveID }
    }

    /// Whether the window is showing archive contents (vs the empty state).
    var hasOpenArchive: Bool { currentArchive != nil }

    /// Return to the start (drop-zone) screen: leave folder browsing and
    /// deselect the current archive. Open archives stay open in the sidebar.
    func goToStart() {
        browsingFolder = nil
        currentArchiveID = nil
    }

    /// Toggle the Places sidebar (⌥⌘S).
    func toggleSidebar() {
        sidebarVisibility = (sidebarVisibility == .detailOnly) ? .all : .detailOnly
    }

    /// Reveal the sidebar when 2+ archives are open so the user can see which
    /// files are open and switch between them (e.g. after opening several via
    /// "Open With XZip"). Only expands — never force-hides — so the user can
    /// still collapse it afterwards.
    func revealSidebarForMultipleArchives() {
        if openArchives.count >= 2 {
            sidebarVisibility = .all
        }
    }

    /// Add a favorite place from a chosen folder URL.
    func addPlace(url: URL) {
        places = placesStore.add(url: url, to: places)
    }

    /// Remove a favorite place. If it's the one currently being browsed, leave
    /// folder-browsing mode so the workspace doesn't point at a dead place.
    func removePlace(_ place: Place) {
        places = placesStore.remove(place, from: places)
        if browsingFolder == place.url {
            browsingFolder = nil
            folderItems = []
        }
    }

    /// Reorder Places via drag (sidebar `.onMove`) and persist the new order.
    func movePlaces(from source: IndexSet, to destination: Int) {
        places.move(fromOffsets: source, toOffset: destination)
        placesStore.save(places)
    }

    /// Extract the current selection (or whole archive) to a place.
    /// Extract to a favorite place. `selectedEntries` (in-archive paths) limits
    /// extraction to those items; empty extracts the whole archive.
    func extractToPlace(_ place: Place, selectedEntries: [String] = []) {
        guard let archive = currentArchive?.url else { return }
        let accessing = place.url.startAccessingSecurityScopedResource()
        defer { if accessing { place.url.stopAccessingSecurityScopedResource() } }
        startExtraction(archive: archive, destination: place.url, selectedEntries: selectedEntries)
    }

    // MARK: - In-archive folder navigation (mockup 1b breadcrumb)

    /// Entries shown for the current folder: direct children of `currentFolderPath`.
    /// Falls back to a flat list if the archive has no directory structure.
    var visibleEntries: [ArchiveEntry] {
        ArchiveBrowsing.visibleEntries(archiveEntries, currentFolderPath: currentFolderPath)
    }

    /// Breadcrumb components from archive root to the current folder.
    var breadcrumbs: [(name: String, path: String)] {
        ArchiveBrowsing.breadcrumbs(
            archiveName: currentArchive?.name ?? "Archive",
            currentFolderPath: currentFolderPath)
    }

    /// Enter a folder (double-click) or jump via breadcrumb.
    func navigateToFolder(_ path: String) {
        currentFolderPath = path
        selectedArchiveEntryIDs.removeAll()
    }

    /// Whether an entry is a folder the user can descend into.
    func isFolder(_ entry: ArchiveEntry) -> Bool { entry.kind == .folder }

    // MARK: - Places folder browser (mockup 2a)

    /// How the folder browser is currently sorted.
    var folderSortKey: FolderBrowsing.SortKey = .name
    /// Direction of the folder-browser sort (bridged from the Table header).
    var folderSortAscending = true

    /// Enter folder-browsing mode at `url` (clicking a Place). Leaves any open
    /// archive view; the archive stays open in the sidebar to return to.
    func browseFolder(_ url: URL) {
        currentArchiveID = nil
        browsingFolder = url
        folderBackStack = []
        selectedFolderItemIDs = []
        refreshFolder()
    }

    /// Navigate to the user's preferred startup Place (Settings → General →
    /// "When XZip opens"). Called once when the main window appears.
    /// No-op when a file open already put the app somewhere: an archive opened
    /// via Finder wins over the startup preference.
    func applyStartupLocation() {
        guard currentArchiveID == nil, browsingFolder == nil else { return }
        let stored = UserDefaults.standard.string(forKey: XZIPDefaults.startupLocation)
        guard let place = StartupLocation.resolve(storedID: stored, places: places) else { return }
        browseFolder(place.url)
    }

    /// Descend into a subfolder, remembering where we came from for Back.
    func descendIntoFolder(_ url: URL) {
        if let current = browsingFolder { folderBackStack.append(current) }
        browsingFolder = url
        selectedFolderItemIDs = []
        refreshFolder()
    }

    /// Go up to the parent directory (disabled at the filesystem root).
    func folderGoUp() {
        guard let current = browsingFolder else { return }
        let parent = current.deletingLastPathComponent()
        guard parent != current else { return }
        if let last = browsingFolder { folderBackStack.append(last) }
        browsingFolder = parent
        selectedFolderItemIDs = []
        refreshFolder()
    }

    /// Whether there is somewhere to go Back to.
    var canFolderGoBack: Bool { !folderBackStack.isEmpty }

    /// Return to the previously browsed folder.
    func folderGoBack() {
        guard let previous = folderBackStack.popLast() else { return }
        browsingFolder = previous
        selectedFolderItemIDs = []
        refreshFolder()
    }

    /// Breadcrumb trail for the folder browser, from the enclosing Place root
    /// down to the current folder. Rooting at the Place keeps the trail short
    /// and meaningful; if the folder isn't under any Place we walk up to the
    /// filesystem root.
    var folderBreadcrumbs: [URL] {
        guard let current = browsingFolder else { return [] }
        // Standardize BOTH sides of the root match: the cursor below walks
        // standardized paths, so an unstandardized Place (e.g. /private/tmp
        // vs /tmp) would never match and the crumbs would run past it to "/".
        let currentPath = current.standardizedFileURL.path
        let root = places.map(\.url).first {
            let rootPath = $0.standardizedFileURL.path
            return currentPath == rootPath || currentPath.hasPrefix(rootPath + "/")
        }
        var urls: [URL] = []
        let rootPath = root?.standardizedFileURL.path
        // Standardize so URL forms that arrive from drag & drop (relative /
        // reference-style) walk up like plain file-path URLs.
        var cursor = current.standardizedFileURL
        while true {
            urls.append(cursor)
            if let rootPath, cursor.path == rootPath { break }
            if cursor.path == "/" || cursor.path.isEmpty { break }
            let parent = cursor.deletingLastPathComponent()
            // `deletingLastPathComponent()` does not always converge to an
            // identical URL at the top — for some URL forms it keeps appending
            // "../", which once spun this loop forever (main-thread hang on
            // dropped folders outside every Place). Requiring the path to
            // strictly shrink guarantees termination for any URL shape.
            if parent.path.count >= cursor.path.count { break }
            cursor = parent
        }
        return urls.reversed()
    }

    /// Jump to an ancestor on-disk folder from the breadcrumb. Named distinctly
    /// from `navigateToFolder(_:)` (which takes an in-archive path string).
    func navigateToDiskFolder(_ url: URL) {
        guard url != browsingFolder else { return }
        if let current = browsingFolder { folderBackStack.append(current) }
        browsingFolder = url
        selectedFolderItemIDs = []
        refreshFolder()
    }

    /// Reload the current folder's contents from disk and re-sort.
    func refreshFolder() {
        guard let url = browsingFolder else { folderItems = []; return }
        // Listing + localized sort of a big folder is O(n log n); run it off the
        // main actor so clicking into a large directory doesn't beachball.
        let sortKey = folderSortKey
        let ascending = folderSortAscending
        let foldersFirst = XZIPDefaults.showsFoldersFirst
        Task {
            do {
                let sorted = try await Task.detached {
                    let raw = try FolderBrowsing.contentsResult(of: url)
                    return FolderBrowsing.sort(
                        raw, by: sortKey, ascending: ascending,
                        foldersFirst: foldersFirst)
                }.value
                guard self.browsingFolder == url else { return }
                self.folderItems = sorted
            } catch {
                guard self.browsingFolder == url else { return }
                // Don't render an unreadable folder as if it were genuinely empty.
                self.folderItems = []
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Change the sort key and re-sort in place.
    func setFolderSort(_ key: FolderBrowsing.SortKey, ascending: Bool = true) {
        folderSortKey = key
        folderSortAscending = ascending
        folderItems = FolderBrowsing.sort(
            folderItems, by: key, ascending: ascending,
            foldersFirst: XZIPDefaults.showsFoldersFirst
        )
    }

    /// Handle a double-click in the folder browser: descend into folders, open
    /// archives in the archive browser, or hand other files to the default app.
    func openFileItem(_ item: FileItem) {
        if item.isDirectory {
            descendIntoFolder(item.url)
        } else if FolderBrowsing.isArchive(item) {
            openArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Compress the current folder-browser selection (or all items if none are
    /// selected) via the compress sheet, seeding it with those files.
    func compressFolderSelection() {
        let urls: [URL] = selectedFolderItemIDs.isEmpty
            ? folderItems.map(\.url)
            : folderItems.filter { selectedFolderItemIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        compressionInputs = urls.map { InputItem(url: $0) }
        isCompressSheetPresented = true
    }

    /// Compress a specific set of folder-browser items (context-menu action).
    func compressItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        compressionInputs = items.map { InputItem(url: $0.url) }
        isCompressSheetPresented = true
    }

    /// Extract an archive `FileItem` from the folder browser. A nil destination
    /// extracts alongside the archive (into a folder named after it).
    func extractItem(_ item: FileItem, to destination: URL?) {
        // Extract the whole archive (empty selection).
        startExtraction(archive: item.url, destination: destination)
    }

    /// Reveal the given items in Finder (context-menu action).
    func revealInFinder(_ items: [FileItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Move the given items to the Trash and refresh the folder listing
    /// (context-menu action). Recoverable via Finder's Put Back.
    func moveToTrash(_ items: [FileItem]) {
        for item in items {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        refreshFolder()
    }

    // MARK: - Extraction

    /// Extract the chosen archive. When the conflict policy is "Ask", first
    /// pre-scans the destination for name clashes and surfaces `ConflictDialog`
    /// (mockup 3b) once; the chosen policy then applies to the whole batch.
    /// `selectedEntries` (empty = whole archive) and `destination` are passed
    /// explicitly rather than via shared mutable state, so a stale value from a
    /// prior call can never leak into the next extraction.
    func startExtraction(archive: URL, destination: URL? = nil, selectedEntries: [String] = []) {
        let destination = destination
            ?? archive.deletingLastPathComponent()
                .appendingPathComponent(archive.deletingPathExtension().lastPathComponent)

        // Read the policy live so a change in Settings applies immediately.
        conflictPolicy = XZIPDefaults.conflictPolicyValue
        guard conflictPolicy == .ask else {
            performExtraction(archive: archive, destination: destination,
                              policy: conflictPolicy, selectedEntries: selectedEntries)
            return
        }

        // Pre-scan for conflicts on a background task, then decide.
        let pwd = password.isEmpty ? nil : password
        Task {
            let conflicts: [URL]
            do {
                conflicts = try await self.scanConflicts(
                    archive: archive, destination: destination,
                    password: pwd, selectedEntries: selectedEntries)
            } catch ArchiveEngineError.passwordRequired, ArchiveEngineError.wrongPassword {
                // The pre-scan listing needs a password. Prompt for it, then retry
                // the WHOLE extraction so the conflict scan runs once we have it —
                // never fall through to an overwrite.
                self.pendingExtractionRetry = (url: archive, action: { [weak self] in
                    self?.startExtraction(archive: archive, destination: destination,
                                          selectedEntries: selectedEntries)
                })
                self.isPasswordPromptPresented = true
                return
            } catch {
                // Any other listing failure: don't guess. Surface it and stop
                // rather than overwriting files at the destination.
                self.errorMessage = error.localizedDescription
                return
            }
            guard let first = conflicts.first else {
                self.performExtraction(archive: archive, destination: destination,
                                       policy: .replace, selectedEntries: selectedEntries)
                return
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: first.path)
            self.pendingConflict = ConflictPrompt(
                firstConflict: first.lastPathComponent,
                totalConflicts: conflicts.count,
                existingSize: attrs?[.size] as? Int64,
                existingModified: attrs?[.modificationDate] as? Date,
                resolve: { [weak self] policy, _ in
                    // The selected policy applies to every conflict in this batch.
                    Task { @MainActor in
                        self?.pendingConflict = nil
                        self?.performExtraction(archive: archive, destination: destination,
                                                policy: policy, selectedEntries: selectedEntries)
                    }
                })
        }
    }

    /// List files that already exist in `destination` and would be overwritten.
    private func scanConflicts(
        archive: URL, destination: URL, password: String?, selectedEntries: [String]
    ) async throws -> [URL] {
        guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
        // A Set makes the "is this entry selected?" test O(1) instead of O(n) per
        // entry (was O(n·m) over the whole listing).
        let selected = Set(selectedEntries)
        // Let listing errors propagate: the caller must distinguish "no conflicts"
        // from "couldn't scan" (e.g. the archive needs a password). Swallowing the
        // error here and returning [] made the caller treat an unscanned archive
        // as conflict-free and overwrite the destination with .replace.
        let entries = try await service.list(archive: archive, password: password)
        // The filter + per-entry `fileExists` is O(n) over the whole listing
        // (100k+ entries for a big archive); run it off the main actor so the
        // "Ask" pre-scan never beachballs the UI.
        return await Task.detached {
            let fm = FileManager.default
            return entries.compactMap { entry -> URL? in
                // Only consider entries we're actually going to extract, so a
                // selective extraction doesn't prompt for untouched files.
                if !selected.isEmpty, !selected.contains(entry.path) { return nil }
                let rel = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
                let candidate = destination.appendingPathComponent(rel)
                return fm.fileExists(atPath: candidate.path) ? candidate : nil
            }
        }.value
    }

    /// Run the actual extraction with a resolved overwrite policy.
    private func performExtraction(
        archive: URL, destination: URL, policy: ConflictPolicy, selectedEntries: [String]
    ) {
        let pwd = password.isEmpty ? nil : password
        let existingFilePolicy: ExistingFilePolicy
        switch policy {
        case .replace, .ask:
            existingFilePolicy = .replace
        case .keepBoth:
            existingFilePolicy = .keepBoth
        case .skip:
            existingFilePolicy = .skip
        }
        let options = ExtractionOptions(
            password: pwd,
            selectedEntries: selectedEntries,
            existingFilePolicy: existingFilePolicy
        )
        let op = ArchiveOperation(
            title: String(localized: "Extracting \(archive.lastPathComponent)"),
            kind: .extract, state: .running, progress: 0,
            currentItem: String(localized: "Starting…"), detail: "")
        run(op, outputURL: destination, onComplete: { [weak self] output in
            self?.handlePostExtraction(archive: archive, destination: output ?? destination)
        }, onPasswordFailure: { [weak self] in
            guard let self else { return }
            // Encrypted entries surface only at extract time for zip/7z archives
            // whose listing needs no password. Ask for one and re-run this exact
            // extraction with it (the prompt sets `password` before retrying).
            self.pendingExtractionRetry = (url: archive, action: { [weak self] in
                self?.performExtraction(archive: archive, destination: destination,
                                        policy: policy, selectedEntries: selectedEntries)
            })
            self.isPasswordPromptPresented = true
        }) { [service] in
            try service.extract(archive: archive, destination: destination, options: options)
        }
    }

    /// Called by the password prompt after the user submits a password.
    /// Re-runs the extraction that surfaced the prompt (if it belongs to the
    /// archive still being viewed); otherwise relists the archive entries.
    /// Called by the password prompt after the user submits a password. Re-runs
    /// the extraction that surfaced the prompt if one is pending (its closure
    /// carries its own archive/destination/entries); otherwise relists the open
    /// archive. Opening a different archive clears any stale pending retry.
    func passwordPromptDidSubmit() {
        let pending = pendingExtractionRetry
        pendingExtractionRetry = nil
        if let pending {
            pending.action()
        } else {
            refreshEntries()
        }
    }

    /// Apply post-extraction preferences, only on success (fired via onComplete):
    /// the "After extracting" action, quarantine handling, and the optional
    /// "Move archive to Trash".
    private func handlePostExtraction(archive: URL, destination: URL) {
        let keepQuarantine = XZIPDefaults.quarantinesApps
        Task {
            // Quarantine extracted apps according to preference (Gatekeeper
            // safety) and wait for it to finish BEFORE revealing/opening, so a
            // launchable item can't be opened before its flag is set.
            await QuarantineService.apply(keepQuarantine: keepQuarantine, at: destination)

            // After extracting: reveal / open / nothing.
            switch XZIPDefaults.afterExtractAction {
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([destination])
            case .open:   NSWorkspace.shared.open(destination)
            case .nothing: break
            }

            // Move the source archive to Trash if requested. Close it from the
            // sidebar first so the workspace never points at a trashed file.
            if XZIPDefaults.movesToTrashAfterExtract {
                self.editSaveBack.endEditing(forArchive: archive)
                if let open = self.openArchives.first(where: { $0.url == archive }) {
                    self.closeArchive(open.id)
                }
                try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            }
        }
    }

    /// Create a new folder inside the current archive from the selection (5a).
    /// Implemented by adding an empty directory placeholder at the current path.
    func newFolderFromSelection(named name: String = "New Folder") {
        guard let url = currentArchive?.url, !name.isEmpty else { return }
        let base = currentFolderPath.isEmpty ? name : "\(currentFolderPath)/\(name)"
        let pwd = password.isEmpty ? nil : password
        Task {
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                // Stage the empty folder under a temp tree mirroring the current
                // path, then add it relative to that root so it lands at `base`
                // (matching the "Created folder …" message) rather than the root.
                let item = stage.appendingPathComponent(base, isDirectory: true)
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
                try await service.add(files: [item], to: url, password: pwd, workingDirectory: stage)
                self.refreshEntries()
                self.infoMessage = String(localized: "Created folder “\(base)”.")
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Load an archive's entries into the workspace table + register it in the
    /// Open Archives sidebar section, making it the current browser subject.
    func openArchive(_ url: URL) {
        // Switching to a DIFFERENT archive clears the shared `password` so the new
        // archive resolves its own (vault auto-fill in refreshEntries, or a
        // prompt) instead of inheriting the previous archive's — which caused
        // wrong-password errors and could save a password under the wrong vault
        // key. (The single shared `password` serving every archive is the root
        // cause; per-archive storage would be the fuller fix.)
        if currentArchive?.url != url { password = "" }
        // Opening a different archive invalidates any pending extraction-password
        // retry from a prior archive, so a password entered for THIS archive
        // relists it rather than re-running the old extraction.
        pendingExtractionRetry = nil
        // Feed macOS's recent-documents list (also powers the Dock icon's
        // right-click “Recent Documents” menu and File → Open Recent).
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentDocuments.removeAll { $0 == url }
        recentDocuments.insert(url, at: 0)
        // Opening an archive leaves the Places folder-browsing mode.
        browsingFolder = nil
        // The toolbar search field is shared between the folder browser and the
        // archive browser. A leftover query (e.g. the one used to find this
        // archive in the folder browser) would filter the archive's contents and
        // make it look empty, so clear it when opening an archive.
        searchText = ""
        // Register (or focus) the archive in the sidebar list.
        if let existing = openArchives.first(where: { $0.url == url }) {
            currentArchiveID = existing.id
        } else {
            let archive = OpenArchive(url: url)
            openArchives.append(archive)
            currentArchiveID = archive.id
        }
        // Reset in-archive navigation so switching archives never lands on an
        // empty pane (the previous folder path won't exist in the new archive)
        // or carries a stale selection into it.
        currentFolderPath = ""
        selectedArchiveEntryIDs.removeAll()
        // Clear the previous archive's entries so the browser shows its loading
        // state while the new archive is listed, instead of a blank pane or the
        // stale contents of the last archive. Slow-to-attach formats like DMG
        // make this gap visible; without it the pane sat empty, then filled
        // abruptly with no feedback in between.
        archiveEntries = []
        refreshEntries()
    }

    /// URLs of archives the user closed this session, most-recent last. Backs
    /// “Reopen Closed Archive” (⇧⌘T by default).
    var recentlyClosed: [URL] = []

    var canReopenClosed: Bool { !recentlyClosed.isEmpty }

    /// Close an open archive (removes it from the sidebar).
    func closeArchive(_ id: OpenArchive.ID) {
        // Remember the closed URL so it can be reopened (dedup + cap at 20).
        if let closed = openArchives.first(where: { $0.id == id })?.url {
            recentlyClosed.removeAll { $0 == closed }
            recentlyClosed.append(closed)
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
            // Stop any Edit & Save Back sessions on this archive so a later save
            // never writes into a closed (or about-to-be-trashed) file.
            editSaveBack.endEditing(forArchive: closed)
        }
        openArchives.removeAll { $0.id == id }
        if currentArchiveID == id {
            currentArchiveID = openArchives.first?.id
            // Reset the per-archive browse state (as openArchive does) before
            // showing the next archive: keeping the closed archive's folder path
            // and selection leaves the browser blank with a stale breadcrumb.
            currentFolderPath = ""
            selectedArchiveEntryIDs.removeAll()
            searchText = ""
            if currentArchive?.url != nil { refreshEntries() } else { archiveEntries = [] }
        }
    }

    /// Reopen the most recently closed archive (⇧⌘T).
    func reopenLastClosed() {
        guard let url = recentlyClosed.popLast() else { return }
        openArchive(url)
    }

    /// Snapshot of macOS's recent-documents list; the UI renders this, never
    /// NSDocumentController directly. The controller's read-back lags its
    /// write-through (LSSharedFileList daemon roundtrip), so re-reading right
    /// after a mutation returns stale entries.
    var recentDocuments: [URL] = NSDocumentController.shared.recentDocumentURLs

    /// Remove a single entry. NSDocumentController has no single-item removal
    /// API: clear the system list, then re-note the survivors (reversed, since
    /// each note inserts at the top).
    func removeRecent(_ url: URL) {
        recentDocuments.removeAll { $0 == url }
        let controller = NSDocumentController.shared
        controller.clearRecentDocuments(nil)
        for kept in recentDocuments.reversed() {
            controller.noteNewRecentDocumentURL(kept)
        }
    }

    /// Clear macOS's recent-documents list (File → Open Recent → Clear Menu).
    func clearRecents() {
        recentDocuments = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// Reload the open archive's entries from disk (after edits).
    @discardableResult
    func refreshEntries() -> Task<Void, Never> {
        guard let url = currentArchive?.url else { return Task {} }
        // Fall back to a Keychain vault entry saved for this archive so a
        // remembered password unlocks it without prompting again.
        if password.isEmpty, let saved = service.savedPassword(for: vaultKey(for: url)) {
            password = saved
        }
        let pwd = password.isEmpty ? nil : password
        listingGeneration += 1
        let generation = listingGeneration
        isLoadingEntries = true
        return Task {
            defer {
                // Only the most recent listing clears the flag: a stale task that
                // finishes after the user switched archives must not turn off the
                // spinner for the archive now loading (which would render its pane
                // as empty).
                if self.listingGeneration == generation { self.isLoadingEntries = false }
            }
            do {
                let entries = try await service.list(archive: url, password: pwd)
                // Ignore stale results: the user may have switched archives or
                // started a newer refresh while this listing was still in flight.
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                // Map + folder-synthesis is O(n) over the listing; run it off the
                // main actor so a 100k-entry archive doesn't stall the UI.
                let ui = await Task.detached { ModelMapping.uiEntries(from: entries) }.value
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                self.archiveEntries = ui
                // Keep the sidebar metadata (count + lock badge) in sync.
                if let index = self.openArchives.firstIndex(where: { $0.url == url }) {
                    self.openArchives[index].itemCount = entries.count
                    self.openArchives[index].isEncrypted = entries.contains { $0.isEncrypted }
                }
            } catch let error as ArchiveEngineError {
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                switch error {
                case .passwordRequired, .wrongPassword:
                    // Encrypted archive: prompt for the password (mockup 3a)
                    // instead of surfacing a dead-end error alert.
                    self.isPasswordPromptPresented = true
                default:
                    self.errorMessage = error.localizedDescription
                }
            } catch {
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Test integrity of the currently open archive.
    func testCurrentArchive() {
        guard let url = currentArchive?.url else { return }
        let pwd = password.isEmpty ? nil : password
        Task {
            do {
                let ok = try await service.test(archive: url, password: pwd)
                if ok {
                    self.infoMessage = String(localized: "Archive is intact.")
                } else {
                    self.errorMessage = String(localized: "Archive failed the integrity test.")
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel(_ id: ArchiveOperation.ID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        updateOperation(id) { $0.state = .cancelled }
    }

    /// Pause (cancel) every running operation. macOS 7-Zip has no true pause, so
    /// this cancels in-flight work; the row shows a Retry action to resume.
    func pauseAllOperations() {
        for op in operations where op.state == .running {
            runningTasks[op.id]?.cancel()
            runningTasks[op.id] = nil
            updateOperation(op.id) { $0.state = .paused }
        }
    }

    /// Pause (cancel) a single running operation. It can be resumed via Retry,
    /// which re-runs it from the start using its stored action.
    func pauseOperation(_ id: ArchiveOperation.ID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        updateOperation(id) { $0.state = .paused }
    }

    /// Re-run a previously failed/paused operation using its stored action.
    func retryOperation(_ id: ArchiveOperation.ID) {
        retryActions[id]?()
    }

    /// Reveal an operation's output in Finder (mockup 1f “Reveal”).
    func revealOutput(for id: ArchiveOperation.ID) {
        guard let op = operations.first(where: { $0.id == id }), let url = op.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

}

enum SampleData {
    static let archiveEntries: [ArchiveEntry] = {
        let now = Date()
        return [
            ArchiveEntry(name: "Documentation", path: "/Documentation", kind: .folder, originalSize: 12_400_000, compressedSize: 4_200_000, modifiedAt: now),
            ArchiveEntry(name: "Sources", path: "/Sources", kind: .folder, originalSize: 18_700_000, compressedSize: 6_100_000, modifiedAt: now),
            ArchiveEntry(name: "Resources", path: "/Resources", kind: .folder, originalSize: 8_900_000, compressedSize: 3_200_000, modifiedAt: now),
            ArchiveEntry(name: "README.md", path: "/README.md", kind: .document, originalSize: 1_200_000, compressedSize: 512_000, modifiedAt: now),
            ArchiveEntry(name: "Screenshot_1.png", path: "/Screenshot_1.png", kind: .image, originalSize: 2_100_000, compressedSize: 1_200_000, modifiedAt: now),
            ArchiveEntry(name: "data.json", path: "/data.json", kind: .source, originalSize: 128_000, compressedSize: 54_000, modifiedAt: now),
            ArchiveEntry(name: "app.js", path: "/app.js", kind: .source, originalSize: 3_300_000, compressedSize: 1_300_000, modifiedAt: now)
        ]
    }()

    static let presets: [ArchivePreset] = [
        ArchivePreset(name: "Balanced ZIP", summary: "Good compatibility and speed", format: .zip, level: .balanced),
        ArchivePreset(name: "Maximum 7Z", summary: "Smallest archive for storage", format: .sevenZip, level: .maximum),
        ArchivePreset(name: "Email Attachment", summary: "20 MB split volumes", format: .zip, level: .balanced, splitSizeMB: 20),
        ArchivePreset(name: "Secure Transfer", summary: "AES-256 encrypted ZIP", format: .zip, level: .maximum, encryptionEnabled: true),
        ArchivePreset(name: "Source Backup", summary: "TAR.XZ with source filters", format: .tarXz, level: .maximum, excludePatterns: ".build, DerivedData")
    ]

    static let operations: [ArchiveOperation] = [
        ArchiveOperation(title: "Compressing Project Assets", kind: .compress, state: .running, progress: 0.42, currentItem: "assets/video.mov", detail: "1.2 GB of 2.8 GB"),
        ArchiveOperation(title: "Extracting Backup_2024.7z", kind: .extract, state: .running, progress: 0.73, currentItem: "Photos/IMG_2841.heic", detail: "8,412 of 11,540 items"),
        ArchiveOperation(title: "Documents.zip", kind: .compress, state: .completed, progress: 1, currentItem: "Completed", detail: "Saved 38.4 MB")
    ]
}
