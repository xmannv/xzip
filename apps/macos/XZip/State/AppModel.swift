import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore
import XZIPDomain
import XZIPRuntime

enum PasswordValidationContext: Hashable {
    case listing
    case extraction
}

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
    /// Password for the archive being CREATED by the compress sheet. This is a
    /// draft value, not a credential: it never unlocks an existing archive.
    /// Credentials for archives the user opens live in `credentials`, keyed by
    /// archive, because one field cannot serve both roles without leaking
    /// between them.
    var compressionPassword = ""
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
    /// The archive the in-flight repack is rewriting, so the sheet's Cancel can
    /// address that mutation specifically. Admission and serialization live in
    /// `mutationGate`, which keys work per archive rather than app-wide.
    @ObservationIgnored var repackArchive: URL?
    /// Transient confirmation banner text (e.g. "Archive is intact").
    var infoMessage: String?

    /// Non-nil while safe extraction is unavailable because the transactional
    /// stack could not be assembled.
    ///
    /// `ExtractionRouter` already recorded this as `unavailableReason`, but the
    /// router is `@ObservationIgnored` and nothing read it. Mirrored here so a
    /// view can explain why extraction is blocked and offer a retry.
    private(set) var extractionFallbackReason: String?

    var selectedPresetID: ArchivePreset.ID?

    /// Keys (archive filenames) that have a password saved in the Keychain vault.
    var vaultKeys: [String] = []

    // MARK: - Backend

    /// The backend facade. Not observed — it holds no UI state.
    @ObservationIgnored let service: ArchiveService
    /// Owns temporary entries extracted for preview, drag-out, Open With and Share.
    /// These may be decrypted plaintext, so their lifetime is explicitly managed.
    @ObservationIgnored let scratch: ScratchStore
    /// Tracks running operation tasks so they can be cancelled by ID.
    @ObservationIgnored var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic per-operation counter. A retried operation reuses the same id
    /// with a new task; the generation lets the OLD task's teardown avoid
    /// clearing the NEW task's handle (which would leave the retry uncancellable).
    @ObservationIgnored var taskGenerations: [UUID: Int] = [:]
    /// Stores the work needed to re-run a failed operation (Retry, mockup 1f).
    /// Main-actor isolated (not `@Sendable`): only invoked from `retryOperation`.
    @ObservationIgnored var retryActions: [UUID: () -> Void] = [:]
    private struct PasswordPromptGroup {
        let id = UUID()
        let archive: URL
        var retries: [@MainActor @Sendable () -> Void]
        var validationContexts: Set<PasswordValidationContext>
        var errorMessage: String?
    }

    private struct PendingPasswordSave {
        var password: String
        var validationContexts: Set<PasswordValidationContext>
    }

    /// One UI prompt per archive, while preserving every operation retry.
    @ObservationIgnored private var activePasswordRetries: [@MainActor @Sendable () -> Void] = []
    @ObservationIgnored private var pendingPasswordSaves: [String: PendingPasswordSave] = [:]
    @ObservationIgnored private var deferredPasswordPrompts: [PasswordPromptGroup] = []
    /// Queue head reserved while SwiftUI completes the prior sheet dismissal.
    @ObservationIgnored private var scheduledPasswordPrompt: PasswordPromptGroup?
    /// Identity captured by the presenting view and returned by onDismiss.
    private(set) var passwordPromptPresentationID: UUID?
    private(set) var passwordPromptErrorMessage: String?
    private(set) var passwordPromptValidationContexts: Set<PasswordValidationContext> = []
    private(set) var passwordPromptShouldRemember = false
    @ObservationIgnored private var appearedPasswordPromptID: UUID?

    /// Owns the transactional extraction stack's crash-recovery startup gate.
    @ObservationIgnored let extractionRouter: ExtractionRouter

    /// Assembles the transactional extraction stack and publishes the outcome.
    ///
    /// Extraction remains blocked when this fails because only XZIPRuntime may
    /// mutate the final destination. Safe to call again: the router drops its
    /// failed attempt, so this doubles as the retry entry point.
    func prepareExtraction() async {
        await extractionRouter.prepare()
        extractionFallbackReason = extractionRouter.unavailableReason
    }

    /// Hides the extraction availability notice without changing router state.
    ///
    /// Only the notice is cleared, not the router's state, so a later
    /// `prepareExtraction()` that fails again raises it once more.
    func dismissExtractionFallbackNotice() {
        extractionFallbackReason = nil
    }

    /// Credentials for archives unlocked this session, one per archive.
    /// `@ObservationIgnored` on purpose: a secret is not view state, so no view
    /// can bind to it and changing one cannot invalidate unrelated views.
    @ObservationIgnored let credentials = ArchiveCredentials()

    /// How the app asks the user to prove they are present before saved credential use.
    ///
    /// A closure rather than a direct `AuthService` call keeps both verdicts
    /// reachable in tests because `LAContext` cannot evaluate policy there.
    @ObservationIgnored var authenticator: @MainActor (String) async -> Bool = {
        await AuthService.authenticate(reason: $0)
    }
    @ObservationIgnored private var extractionRequestGeneration: UInt64 = 0
    @ObservationIgnored private var latestConflictPromptGeneration: UInt64 = 0
    /// Scratch URLs of nested archives already extracted for browsing, keyed by
    /// "<archive path>\n<entry path>". Reopening the same entry focuses the
    /// archive already open instead of extracting — and listing — it twice into
    /// two identical sidebar rows. `archiveModifiedAt` invalidates the entry when
    /// the outer archive is repacked (any mutation swaps the file → new mtime).
    @ObservationIgnored var nestedEntryExportURLs: [String: (url: URL, archiveModifiedAt: Date?)] = [:]
    /// Keys with an `openEntryAsArchive` extraction currently in flight. The
    /// memo above is only written after extraction finishes, so a second
    /// double-click during a slow extract would otherwise race it and mint a
    /// duplicate export + sidebar row.
    @ObservationIgnored var nestedEntryOpensInFlight: Set<String> = []
    #if DEBUG
    @ObservationIgnored var conflictPreflightDidFinish:
        @MainActor (UInt64) -> Void = { _ in }
    #endif

    /// The gate serializing in-place archive rewrites.
    ///
    /// Owned by `ArchiveService`, which claims it inside every mutation, so this
    /// is only for the two things the UI legitimately needs to know: whether an
    /// archive is busy, and cancelling the in-flight repack. Forwarding (rather
    /// than holding a second gate) is what guarantees one serialization point.
    var mutationGate: ArchiveMutationGate { service.mutationGate }

    /// The credential to use when acting on `archive`, or nil when the user has
    /// not supplied one. Every read of an archive password goes through this, so
    /// no caller can accidentally pick up a different archive's credential.
    func credential(for archive: URL) -> String? {
        credentials.credential(for: archive)
    }

    /// The archive captured when the current password prompt was first raised.
    /// This must not be derived from mutable retry/current-archive state: another
    /// background failure can arrive while the user is already typing.
    private(set) var passwordPromptTarget: URL?

    var passwordPromptArchive: URL? {
        passwordPromptTarget
    }

    // MARK: - Password verification gate

    /// A submitted password awaiting the backend's verdict.
    ///
    /// The sheet stays up while this is set. Without it, submitting closed the
    /// sheet immediately and the next queued archive appeared **before** the
    /// backend reported that the password was wrong, so the failure resurfaced
    /// only after the user had already dealt with an unrelated archive.
    struct PasswordVerification {
        let archive: URL
        let generation: UInt64
    }

    private(set) var passwordVerification: PasswordVerification?

    /// True while the sheet is waiting on a verdict, so it can show progress and
    /// refuse a second submission of the same password.
    var isVerifyingPassword: Bool { passwordVerification != nil }

    @ObservationIgnored private var nextPasswordVerificationGeneration: UInt64 = 0
    @ObservationIgnored private var passwordVerificationWatchdog: Task<Void, Never>?

    /// Why a verification ended. "Incorrect" is deliberately absent: a wrong
    /// password arrives as a fresh `presentPasswordPrompt` for the same archive,
    /// which merges the error into the still-open sheet.
    enum PasswordVerdict {
        /// The backend accepted the password.
        case correct
        /// The attempt ended without ruling on the password (an unrelated error,
        /// a stale/cancelled listing, or the watchdog firing). Treated like
        /// `correct` for sheet purposes: releasing is the only safe answer, since
        /// holding a sheet no one will ever resolve is worse than releasing early.
        case indeterminate
    }

    /// Marks the start of a verification and returns its generation.
    ///
    /// The generation is what makes a late callback harmless: an attempt that has
    /// already been superseded cannot resolve the sheet the user is now using.
    private func beginPasswordVerification(for archive: URL) -> UInt64 {
        nextPasswordVerificationGeneration &+= 1
        let generation = nextPasswordVerificationGeneration
        passwordVerification = PasswordVerification(archive: archive, generation: generation)
        passwordVerificationWatchdog?.cancel()
        // Safety net, not the primary mechanism. Every known path resolves
        // explicitly; this exists so an unknown one degrades to the old
        // behaviour (sheet closes, queue advances) instead of stranding the UI.
        passwordVerificationWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.resolvePasswordVerification(generation: generation, verdict: .indeterminate)
        }
        return generation
    }

    /// Ends the verification identified by `generation`, releasing the sheet.
    ///
    /// A no-op when the generation is stale, so a terminal callback that arrives
    /// after a wrong-password re-prompt cannot close the reopened sheet.
    func resolvePasswordVerification(generation: UInt64?, verdict: PasswordVerdict) {
        guard let generation,
              let verification = passwordVerification,
              verification.generation == generation
        else { return }
        clearPasswordVerification()
        guard passwordPromptTarget == verification.archive else { return }
        // Clear the active request BEFORE lowering the sheet: the dismissal hook
        // treats a still-set target as a cancellation, which would discard the
        // pending Keychain save this submission is waiting to confirm.
        passwordPromptTarget = nil
        passwordPromptErrorMessage = nil
        passwordPromptValidationContexts = []
        passwordPromptShouldRemember = false
        activePasswordRetries = []
        pendingExtractionRetry = nil
        lowerPasswordPromptSheet()
    }

    private func clearPasswordVerification() {
        passwordVerification = nil
        passwordVerificationWatchdog?.cancel()
        passwordVerificationWatchdog = nil
    }

    /// The generation to hand back to `resolvePasswordVerification` for work
    /// started on `archive`, or nil when this work is not answering a prompt.
    func passwordVerificationGeneration(for archive: URL) -> UInt64? {
        guard let verification = passwordVerification,
              verification.archive == archive
        else { return nil }
        return verification.generation
    }

    /// Takes the sheet down and advances the queue.
    ///
    /// SwiftUI delivers `onDismiss` only for a sheet it actually built, so an
    /// unacknowledged presentation is consumed synchronously instead.
    private func lowerPasswordPromptSheet() {
        isPasswordPromptPresented = false
        guard let presentationID = passwordPromptPresentationID else { return }
        if appearedPasswordPromptID != presentationID {
            passwordPromptPresentationID = nil
            finishPasswordPromptDismissal()
        }
    }

    /// Present one stable prompt at a time. A later concurrent password failure
    /// cannot retarget the sheet or replace the retry the user is answering.
    private static func passwordPromptMessage(for error: ArchiveEngineError?) -> String? {
        guard case .wrongPassword? = error else { return nil }
        return error?.localizedDescription
    }

    private func confirmPendingPasswordSave(
        for archive: URL,
        password: String?,
        context: PasswordValidationContext
    ) {
        guard let password else { return }
        let key = vaultKey(for: archive)
        guard let pending = pendingPasswordSaves[key],
              pending.password == password,
              pending.validationContexts.contains(context)
        else { return }

        guard saveVaultPassword(password, for: key) else { return }
        pendingPasswordSaves[key] = nil
    }

    /// Internal rather than private: the single-entry operations live in
    /// `AppModel+SingleEntryOps.swift` and have to drop a rejected password too.
    func invalidateSavedPasswordIfMatching(
        _ attemptedPassword: String?,
        for archive: URL
    ) {
        guard let attemptedPassword else { return }
        let key = vaultKey(for: archive)
        guard service.savedPassword(for: key) == attemptedPassword else { return }
        do {
            try service.deletePassword(for: key)
            vaultKeys.removeAll { $0 == key }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentPasswordPrompt(
        for archive: URL,
        validationContext: PasswordValidationContext = .listing,
        error: ArchiveEngineError? = nil,
        retry: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let message = Self.passwordPromptMessage(for: error)

        if passwordPromptTarget == archive {
            if let retry { activePasswordRetries.append(retry) }
            passwordPromptValidationContexts.insert(validationContext)
            if let message { passwordPromptErrorMessage = message }
            // This IS the verdict for a password being verified: the backend
            // rejected it. Ending the verification here keeps the sheet on this
            // archive with the error shown, and makes the operation's later
            // terminal callback a no-op via the generation check.
            if passwordVerification?.archive == archive {
                clearPasswordVerification()
                // The sheet is not rebuilt on a rejection, so `activatePasswordPrompt`
                // no longer republishes this. Refresh it here to keep the model's
                // "Remember in Keychain" state truthful across the retry.
                passwordPromptShouldRemember =
                    pendingPasswordSaves[vaultKey(for: archive)] != nil
            }
            return
        }
        if scheduledPasswordPrompt?.archive == archive {
            if let retry { scheduledPasswordPrompt?.retries.append(retry) }
            scheduledPasswordPrompt?.validationContexts.insert(validationContext)
            if let message { scheduledPasswordPrompt?.errorMessage = message }
            return
        }
        if let index = deferredPasswordPrompts.firstIndex(where: { $0.archive == archive }) {
            if let retry { deferredPasswordPrompts[index].retries.append(retry) }
            deferredPasswordPrompts[index].validationContexts.insert(validationContext)
            if let message { deferredPasswordPrompts[index].errorMessage = message }
            return
        }
        let group = PasswordPromptGroup(
            archive: archive,
            retries: retry.map { [$0] } ?? [],
            validationContexts: [validationContext],
            errorMessage: message
        )
        guard canRaisePasswordPromptSheet else {
            deferredPasswordPrompts.append(group)
            return
        }
        activatePasswordPrompt(group)
    }

    /// Whether a sheet other than the password prompt owns the window's sheet
    /// slot right now.
    ///
    /// A window presents one sheet at a time, and `MainWindowView` attaches
    /// several to the same view. Raising the prompt while one of these is up let
    /// SwiftUI silently drop it, while the model went on believing it was
    /// visible — so every later prompt queued behind a sheet that was never
    /// shown and no user-visible event could clear it. `MainWindowView` observes
    /// this and calls `resumeDeferredPasswordPromptIfPossible()` when it clears.
    var isNonPasswordSheetPresented: Bool {
        isCompressSheetPresented
            || pendingSplitDetection != nil
            || pendingConflict != nil
            || shareArchive != nil
            || activeRepack != nil
            || newItemRequest != nil
            || errorMessage != nil
    }

    /// Whether the prompt can be raised now: the sheet slot has to be free of
    /// both another sheet and any prompt presentation still being tracked.
    private var canRaisePasswordPromptSheet: Bool {
        !isNonPasswordSheetPresented
            && !isPasswordPromptPresented
            && passwordPromptPresentationID == nil
            && scheduledPasswordPrompt == nil
    }

    /// Raises a prompt that was deferred because another sheet held the slot.
    ///
    /// Without this, deferring was a one-way trip: nothing else observes the
    /// competing sheets, so a prompt parked behind one stayed parked for the rest
    /// of the session and the archive could never be unlocked. `MainWindowView`
    /// calls this whenever `isNonPasswordSheetPresented` goes false.
    ///
    /// A no-op when the slot is still busy or nothing is waiting, so it is safe
    /// to call on every such change.
    func resumeDeferredPasswordPromptIfPossible() {
        guard !deferredPasswordPrompts.isEmpty, canRaisePasswordPromptSheet else { return }
        activatePasswordPrompt(deferredPasswordPrompts.removeFirst())
    }

    /// Places repository (file bookmarks in `UserDefaults`).
    @ObservationIgnored private(set) var placesStore: PlacesStore
    /// Coordinates the Edit & Save Back flow (mockup 5a).
    @ObservationIgnored lazy var editSaveBack = EditSaveBackService(service: service)

    init(
        service: ArchiveService = .live(),
        placesStore: PlacesStore = PlacesStore(),
        extractionRouter: ExtractionRouter = ExtractionRouter(),
        scratch: ScratchStore = ScratchStore()
    ) {
        self.service = service
        self.placesStore = placesStore
        self.extractionRouter = extractionRouter
        self.scratch = scratch
        self.presets = service.presetStore.load().map(ModelMapping.uiPreset(from:))
        self.vaultKeys = service.vaultKeys().sorted()
        // Seed the compression draft from the user's saved defaults.
        self.selectedFormat = XZIPDefaults.format
        self.selectedLevel = XZIPDefaults.level
        self.excludeMacNoise = XZIPDefaults.excludesMacNoise
        self.conflictPolicy = XZIPDefaults.conflictPolicyValue
        // Surface Places persistence failures instead of dropping the place.
        // Installed before the first `load()` so an unresolvable bookmark is
        // reported on launch too. `DispatchQueue.main.async` because the hook can
        // fire from `init`, where assigning an observable property would notify
        // observers about an object that is not fully constructed yet.
        self.placesStore.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.errorMessage = message }
        }
        self.places = self.placesStore.load()
        // Surface Edit & Save Back write-back failures instead of only logging.
        editSaveBack.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // Clear files the Share extension staged into the App Group container on
        // previous runs so they don't accumulate.
        XZIPAppGroup.pruneSharedInbox()
        // Anything left under an earlier session root came from a crash or force
        // quit and may contain decrypted plaintext.
        scratch.pruneStaleRoots()
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
        // No security-scope bracket: the app is not sandboxed (see
        // XZip.entitlements), so it granted nothing — and it released on return,
        // long before the extraction it was supposed to cover had run.
        startExtraction(
            archive: archive,
            destination: ExtractionDestination.folder(for: archive, in: place.url),
            selectedEntries: selectedEntries
        )
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

    /// Extract the chosen archive through the transactional runtime. Destructive
    /// replacement is never queued until the user approves the exact immutable
    /// preflight that will be executed.
    func startExtraction(
        archive: URL,
        destination: URL? = nil,
        selectedEntries: [String] = [],
        allowRememberedCredential: Bool = true
    ) {
        let destination = destination
            ?? archive.deletingLastPathComponent()
                .appendingPathComponent(archive.deletingPathExtension().lastPathComponent)

        conflictPolicy = XZIPDefaults.conflictPolicyValue
        let policy = conflictPolicy
        extractionRequestGeneration &+= 1
        let requestGeneration = extractionRequestGeneration
        Task {
            await prepareExtraction()
            await preflightExtraction(
                archive: archive,
                destination: destination,
                policy: policy,
                selectedEntries: selectedEntries,
                requestGeneration: requestGeneration,
                allowRememberedCredential: allowRememberedCredential
            )
        }
    }

    private func preflightExtraction(
        archive: URL,
        destination: URL,
        policy: ConflictPolicy,
        selectedEntries: [String],
        requestGeneration: UInt64,
        allowRememberedCredential: Bool
    ) async {
        let existingFilePolicy: ExistingFilePolicy
        switch policy {
        case .replace, .ask:
            existingFilePolicy = .replace
        case .keepBoth:
            existingFilePolicy = .keepBoth
        case .skip:
            existingFilePolicy = .skip
        }
        let isProspectiveDestructivePreflight = existingFilePolicy == .replace
        let bridge = extractionRouter.transactionalBridge(
            format: service.detectedFormat(for: archive),
            hasPassword: allowRememberedCredential
                && credentials.hasCredential(for: archive),
            destination: destination
        )
        guard let bridge else {
            errorMessage = String(
                localized: "This archive can’t be extracted safely to the selected destination."
            )
            return
        }

        let credentialLease = isProspectiveDestructivePreflight
            || !allowRememberedCredential
            ? nil
            : credentials.acquire(for: archive)
        let password = credentialLease?.password
        var credentialLeaseTransferred = false
        defer {
            if let credentialLease, !credentialLeaseTransferred {
                credentials.release(credentialLease, discardWhenUnused: false)
            }
        }

        let options = ExtractionOptions(
            password: password,
            selectedEntries: selectedEntries,
            existingFilePolicy: existingFilePolicy
        )
        let verification = password == nil
            ? nil
            : passwordVerificationGeneration(for: archive)
        defer {
            resolvePasswordVerification(
                generation: verification,
                verdict: .indeterminate
            )
        }

        let preflight: ExtractionPreflight
        do {
            preflight = try await bridge.preflight(
                archive: archive,
                destination: destination,
                options: options
            )
            if !isProspectiveDestructivePreflight {
                confirmPendingPasswordSave(
                    for: archive,
                    password: password,
                    context: .listing
                )
                resolvePasswordVerification(
                    generation: verification,
                    verdict: .correct
                )
            }
        } catch let error as ArchiveEngineError {
            if isProspectiveDestructivePreflight {
                switch error {
                case .passwordRequired, .wrongPassword:
                    errorMessage = String(
                        localized: "Destructive replacement can’t be confirmed safely because this archive requires a password to inspect conflicts."
                    )
                    return
                default:
                    break
                }
            }
            switch error {
            case .wrongPassword:
                invalidateSavedPasswordIfMatching(password, for: archive)
                if let password {
                    credentials.discard(for: archive, ifMatching: password)
                }
                fallthrough
            case .passwordRequired:
                presentPasswordPrompt(
                    for: archive,
                    validationContext: .listing,
                    error: error
                ) { [weak self] in
                    self?.startExtraction(
                        archive: archive,
                        destination: destination,
                        selectedEntries: selectedEntries
                    )
                }
            default:
                errorMessage = error.localizedDescription
            }
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard preflight.requiresDestructiveReplacementApproval else {
            if isProspectiveDestructivePreflight,
               allowRememberedCredential {
                await performExtractionUsingCurrentCredential(
                    preflight: preflight,
                    replacementApproval: nil,
                    authenticateSavedCredential: false
                )
            } else {
                credentialLeaseTransferred = performExtraction(
                    preflight: preflight,
                    password: password,
                    replacementApproval: nil,
                    credentialLease: credentialLease
                )
            }
            return
        }
        guard let firstConflict = preflight.conflicts.first else {
            errorMessage = String(
                localized: "Destructive replacement could not be confirmed safely."
            )
            return
        }

        defer { notifyConflictPreflightFinished(requestGeneration) }
        guard requestGeneration >= latestConflictPromptGeneration else {
            return
        }
        latestConflictPromptGeneration = requestGeneration
        let promptID = UUID()
        pendingConflict = ConflictPrompt(
            id: promptID,
            firstConflict: URL(fileURLWithPath: firstConflict.relativePath).lastPathComponent,
            totalConflicts: preflight.conflicts.count,
            destructiveDirectoryCount: preflight.destructiveReplacementPaths.count,
            existingSize: firstConflict.existingByteCount.flatMap(Int64.init(exactly:)),
            existingModified: firstConflict.existingModificationDate,
            resolve: { [weak self] selectedPolicy in
                self?.resolveConflictPrompt(
                    id: promptID,
                    selectedPolicy: selectedPolicy,
                    preflight: preflight,
                    archive: archive,
                    destination: destination,
                    selectedEntries: selectedEntries,
                    requestGeneration: requestGeneration,
                    allowRememberedCredential: allowRememberedCredential
                )
            },
            cancel: { [weak self] in
                self?.cancelConflictPrompt(id: promptID, archive: archive)
            }
        )
    }

    private func notifyConflictPreflightFinished(_ requestGeneration: UInt64) {
        #if DEBUG
        conflictPreflightDidFinish(requestGeneration)
        #endif
    }

    private func resolveConflictPrompt(
        id: UUID,
        selectedPolicy: ConflictPolicy,
        preflight: ExtractionPreflight,
        archive: URL,
        destination: URL,
        selectedEntries: [String],
        requestGeneration: UInt64,
        allowRememberedCredential: Bool
    ) {
        guard pendingConflict?.id == id else { return }
        pendingConflict = nil
        Task { @MainActor in
            if selectedPolicy == .replace,
               allowRememberedCredential {
                await performExtractionUsingCurrentCredential(
                    preflight: preflight,
                    replacementApproval:
                        preflight.makeDestructiveReplacementApproval(),
                    authenticateSavedCredential: true
                )
            } else if selectedPolicy == .replace {
                _ = performExtraction(
                    preflight: preflight,
                    password: nil,
                    replacementApproval:
                        preflight.makeDestructiveReplacementApproval(),
                    credentialLease: nil
                )
            } else {
                await preflightExtraction(
                    archive: archive,
                    destination: destination,
                    policy: selectedPolicy,
                    selectedEntries: selectedEntries,
                    requestGeneration: requestGeneration,
                    allowRememberedCredential: allowRememberedCredential
                )
            }
        }
    }

    private func cancelConflictPrompt(id: UUID, archive: URL) {
        guard pendingConflict?.id == id else { return }
        pendingConflict = nil
        infoMessage = String(
            localized: "Didn’t extract \(archive.lastPathComponent) — the existing files were left alone."
        )
    }

    private func performExtractionUsingCurrentCredential(
        preflight: ExtractionPreflight,
        replacementApproval: DestructiveReplacementApproval?,
        authenticateSavedCredential: Bool
    ) async {
        let archive = preflight.archive.url
        if authenticateSavedCredential,
           credentials.hasCredential(for: archive),
           vaultKeys.contains(vaultKey(for: archive)) {
            let reason = String(
                localized: "Authenticate to extract \(archive.lastPathComponent) with its saved password"
            )
            guard await authenticator(reason) else {
                infoMessage = String(
                    localized: "Didn’t extract \(archive.lastPathComponent) — authentication was needed to use its saved password."
                )
                return
            }
        }

        let credentialLease = credentials.acquire(for: archive)
        var credentialLeaseTransferred = false
        defer {
            if let credentialLease, !credentialLeaseTransferred {
                credentials.release(credentialLease, discardWhenUnused: false)
            }
        }
        credentialLeaseTransferred = performExtraction(
            preflight: preflight,
            password: credentialLease?.password,
            replacementApproval: replacementApproval,
            credentialLease: credentialLease
        )
    }

    /// Run extraction only from the exact immutable preflight approved by the
    /// user. No backend receives final-destination authority outside XZIPRuntime.
    @discardableResult
    private func performExtraction(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?,
        credentialLease: ArchiveCredentials.Lease?
    ) -> Bool {
        let archive = preflight.archive.url
        let destination = preflight.destination
        guard let bridge = extractionRouter.transactionalBridge(
            format: service.detectedFormat(for: archive),
            hasPassword: password != nil,
            destination: destination
        ) else {
            errorMessage = String(
                localized: "This archive can’t be extracted safely to the selected destination."
            )
            return false
        }

        let op = ArchiveOperation(
            title: String(localized: "Extracting \(archive.lastPathComponent)"),
            kind: .extract, state: .running, progress: 0,
            currentItem: String(localized: "Starting…"), detail: "")
        let verification = passwordVerificationGeneration(for: archive)
        run(op, outputURL: destination, onComplete: { [weak self] output in
            guard let self else { return }
            self.confirmPendingPasswordSave(
                for: archive,
                password: password,
                context: .extraction
            )
            self.handlePostExtraction(archive: archive, destination: output ?? destination)
        }, onFirstProgress: { [weak self] in
            self?.resolvePasswordVerification(generation: verification, verdict: .correct)
        }, onPasswordFailure: { [weak self] error in
            guard let self else { return }
            if case .wrongPassword = error {
                self.invalidateSavedPasswordIfMatching(password, for: archive)
                if let password {
                    self.credentials.discard(for: archive, ifMatching: password)
                }
            }
            self.presentPasswordPrompt(
                for: archive,
                validationContext: .extraction,
                error: error
            ) { [weak self] in
                Task { @MainActor in
                    await self?.performExtractionUsingCurrentCredential(
                        preflight: preflight,
                        replacementApproval: replacementApproval,
                        authenticateSavedCredential: false
                    )
                }
            }
        }, onTerminal: { [weak self] _ in
            guard let self else { return }
            self.resolvePasswordVerification(
                generation: verification,
                verdict: .indeterminate
            )
            guard let credentialLease else { return }
            let isOpen = self.openArchives.contains(where: { $0.url == archive })
            self.credentials.release(
                credentialLease,
                discardWhenUnused: !isOpen
            )
        }, retainsRetryAction: password == nil) { [bridge] in
            bridge.extract(
                preflight: preflight,
                password: password,
                replacementApproval: replacementApproval
            )
        }
        return true
    }

    /// Called by the password prompt after the user submits a password. Records
    /// the credential against the archive the prompt was about, then re-runs the
    /// pending extraction (its closure carries its own archive/destination/
    /// entries) or relists the open archive.
    ///
    /// The credential is stored under `passwordPromptArchive`, not under the
    /// archive on screen: "Extract Here" in the folder browser prompts for an
    /// archive the user never opened, and attributing that password to the
    /// viewed archive both failed to unlock the real target and saved it under
    /// the wrong Keychain key.
    func passwordPromptDidSubmit(_ password: String, saveToKeychain: Bool = false) {
        guard !password.isEmpty, let archive = passwordPromptArchive else { return }
        let contexts = passwordPromptValidationContexts
        credentials.store(password, for: archive)
        let key = vaultKey(for: archive)
        if saveToKeychain {
            pendingPasswordSaves[key] = PendingPasswordSave(
                password: password,
                validationContexts: contexts
            )
        } else {
            pendingPasswordSaves[key] = nil
        }
        let retries = activePasswordRetries
        // Consume the retries but KEEP `passwordPromptTarget`: the sheet stays up
        // until the backend rules on this password. If it is rejected, the
        // failure re-enters `presentPasswordPrompt` for this same archive and
        // merges the error into the sheet the user is still looking at, instead
        // of the sheet closing and the next queued archive appearing first.
        activePasswordRetries = []
        pendingExtractionRetry = nil
        // Clear any previous attempt's error so the sheet doesn't show a stale
        // "Incorrect password" while this attempt is still being checked.
        passwordPromptErrorMessage = nil
        let generation = beginPasswordVerification(for: archive)
        if retries.isEmpty {
            // A listing refresh only reports on the archive on screen. When the
            // prompt is about a different one (a Finder Quick Action), nothing
            // will produce a verdict, so settle it now rather than leaving the
            // sheet spinning until the watchdog fires.
            if currentArchive?.url == archive {
                refreshEntries()
            } else {
                resolvePasswordVerification(generation: generation, verdict: .indeterminate)
            }
        } else {
            for retry in retries { retry() }
        }
    }

    /// Called when the sheet disappears without unlocking. Presentation-level
    /// cleanup also invokes this, so Escape/programmatic dismissal cannot leave a
    /// stale retry armed.
    func passwordPromptDidCancel() {
        if let archive = passwordPromptTarget {
            pendingPasswordSaves[vaultKey(for: archive)] = nil
        }
        // Abandoning the sheet abandons any verdict it was waiting for.
        clearPasswordVerification()
        activePasswordRetries = []
        pendingExtractionRetry = nil
        passwordPromptTarget = nil
        passwordPromptErrorMessage = nil
        passwordPromptValidationContexts = []
        passwordPromptShouldRemember = false
    }

    /// Presentation-level terminal hook. It handles Escape/programmatic dismiss
    /// and advances a password failure that arrived while the prior sheet was
    /// visible. Submit/cancel clear the active request before this hook runs.
    func passwordPromptDidAppear(presentationID: UUID) {
        guard passwordPromptPresentationID == presentationID else { return }
        appearedPasswordPromptID = presentationID
    }

    func passwordPromptDidDismiss(presentationID: UUID) {
        // Consume only the sheet that actually closed. Delayed/duplicate callbacks
        // carry an older identity and cannot cancel or advance a newer prompt.
        guard passwordPromptPresentationID == presentationID else { return }
        appearedPasswordPromptID = nil
        passwordPromptPresentationID = nil
        finishPasswordPromptDismissal()
    }

    private func finishPasswordPromptDismissal() {
        if passwordPromptTarget != nil {
            passwordPromptDidCancel()
        }
        isPasswordPromptPresented = false
        // Also checks for a competing sheet: cancelling a prompt can itself raise
        // one (an operation's failure sets `errorMessage`), and reserving the next
        // prompt into a slot that sheet owns would lose it.
        guard scheduledPasswordPrompt == nil,
              !isNonPasswordSheetPresented,
              !deferredPasswordPrompts.isEmpty
        else { return }
        let reserved = deferredPasswordPrompts.removeFirst()
        scheduledPasswordPrompt = reserved
        // Capture identity: an older yielded task may not consume a replacement.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  let scheduled = self.scheduledPasswordPrompt,
                  scheduled.id == reserved.id
            else { return }
            self.scheduledPasswordPrompt = nil
            self.activatePasswordPrompt(scheduled)
        }
    }

    private func activatePasswordPrompt(_ group: PasswordPromptGroup) {
        passwordPromptTarget = group.archive
        activePasswordRetries = group.retries
        passwordPromptValidationContexts = group.validationContexts
        passwordPromptErrorMessage = group.errorMessage
        passwordPromptShouldRemember = pendingPasswordSaves[vaultKey(for: group.archive)] != nil
        passwordPromptPresentationID = group.id
        // Compatibility state for tests/older UI paths; group retries are source of truth.
        if let first = group.retries.first {
            pendingExtractionRetry = (url: group.archive, action: first)
        } else {
            pendingExtractionRetry = nil
        }
        isPasswordPromptPresented = true
    }

    private func purgePasswordPrompts(for archive: URL) {
        pendingPasswordSaves[vaultKey(for: archive)] = nil
        if passwordVerification?.archive == archive { clearPasswordVerification() }
        deferredPasswordPrompts.removeAll { $0.archive == archive }
        if scheduledPasswordPrompt?.archive == archive { scheduledPasswordPrompt = nil }
        guard passwordPromptTarget == archive else { return }
        passwordPromptDidCancel()
        isPasswordPromptPresented = false
        guard let presentationID = passwordPromptPresentationID else { return }
        // If SwiftUI never built the sheet, no onDismiss callback will arrive.
        // Consume that unacknowledged presentation synchronously instead.
        if appearedPasswordPromptID != presentationID {
            passwordPromptPresentationID = nil
            finishPasswordPromptDismissal()
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
    ///
    /// Delegates to the New Item flow instead of reimplementing it: this used to
    /// be a near-copy of `createInArchive` that staged and added the placeholder
    /// itself, and — being a copy — it never took the archive's turn at the
    /// mutation gate, so "New Folder from Selection" could rewrite an archive
    /// concurrently with a drop or a delete.
    func newFolderFromSelection(named name: String = "New Folder") {
        createNewItemInArchive(kind: .folder, name: name)
    }

    /// Load an archive's entries into the workspace table + register it in the
    /// Open Archives sidebar section, making it the current browser subject.
    func openArchive(
        _ url: URL,
        allowRememberedCredential: Bool = true,
        registersRecentDocument: Bool = true
    ) {
        // No password clearing here any more: credentials are keyed by archive,
        // so each one resolves its own without inheriting the previous archive's.
        // An active password prompt owns an immutable archive/retry pair until
        // submit or explicit dismissal. Merely viewing another archive must not
        // destroy that unrelated recovery action.
        // Feed macOS's recent-documents list (also powers the Dock icon's
        // right-click “Recent Documents” menu and File → Open Recent). Skipped
        // for scratch URLs (nested archives extracted for browsing): those paths
        // stop existing on quit, so they'd only litter the menu with dead items.
        if registersRecentDocument {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            recentDocuments.removeAll { $0 == url }
            recentDocuments.insert(url, at: 0)
        }
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
        refreshEntries(
            allowRememberedCredential: allowRememberedCredential
        )
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
            // The credential existed to work on this archive; closing it ends
            // that, so reopening asks again (or auto-unlocks from the vault).
            credentials.discard(for: closed)
            purgePasswordPrompts(for: closed)
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
    func refreshEntries(
        allowRememberedCredential: Bool = true
    ) -> Task<Void, Never> {
        guard let url = currentArchive?.url else { return Task {} }
        // Fall back to a Keychain vault entry saved for this archive so a
        // remembered password unlocks it without prompting again. Stored against
        // THIS archive, so it cannot become another archive's credential.
        if allowRememberedCredential,
           credential(for: url) == nil,
           let saved = service.savedPassword(for: vaultKey(for: url)) {
            credentials.store(saved, for: url)
        }
        let pwd = allowRememberedCredential
            ? credential(for: url)
            : nil
        listingGeneration += 1
        let generation = listingGeneration
        // A prompt waiting on this archive is answered by this listing.
        let verification = passwordVerificationGeneration(for: url)
        isLoadingEntries = true
        return Task {
            // Covers every early return below (stale listing, archive switched)
            // as well as unrelated errors: the sheet must never be left waiting
            // on a verdict that will not arrive.
            defer {
                self.resolvePasswordVerification(
                    generation: verification,
                    verdict: .indeterminate
                )
            }
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
                let isEncrypted = entries.contains { $0.isEncrypted }
                // Keep the sidebar metadata (count + lock badge) in sync.
                if let index = self.openArchives.firstIndex(where: { $0.url == url }) {
                    // Counted from `ui`, the same array the status bar counts, so
                    // the sidebar and the window subtitle cannot disagree with it.
                    // `entries.count` omits the synthesized folder rows and made
                    // the two totals differ for archives without directory records.
                    self.openArchives[index].itemCount = ui.count
                    self.openArchives[index].isEncrypted = isEncrypted
                }
                await self.verifyListingCredential(
                    for: url,
                    password: pwd,
                    isEncrypted: isEncrypted,
                    listingGeneration: generation,
                    verification: verification
                )
            } catch let error as ArchiveEngineError {
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                switch error {
                case .wrongPassword:
                    self.invalidateSavedPasswordIfMatching(pwd, for: url)
                    // Encrypted archive: bind the prompt to this listing's URL;
                    // a later background failure cannot retarget it.
                    self.presentPasswordPrompt(
                        for: url,
                        validationContext: .listing,
                        error: error
                    )
                case .passwordRequired:
                    self.presentPasswordPrompt(
                        for: url,
                        validationContext: .listing,
                        error: error
                    )
                default:
                    self.errorMessage = error.localizedDescription
                }
            } catch {
                guard self.listingGeneration == generation, self.currentArchive?.url == url else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Rules on `password` for an encrypted archive that listed successfully, and
    /// asks the user for one when it cannot be proven.
    ///
    /// A successful listing is not proof of anything: `7z a -p`, ZIP and RAR
    /// without `-hp` all encrypt the data behind a plaintext header, so `list`
    /// succeeds with no password at all. Two bugs followed from treating it as a
    /// verdict — the user was never prompted when opening such an archive, and a
    /// wrong password entered elsewhere was declared correct and written to the
    /// Keychain. Both are now decided by `verifyPassword`, which actually
    /// decrypts.
    private func verifyListingCredential(
        for url: URL,
        password: String?,
        isEncrypted: Bool,
        listingGeneration generation: Int,
        verification: UInt64?
    ) async {
        guard let password, !password.isEmpty else {
            guard listingGeneration == generation, currentArchive?.url == url else { return }
            // Listing an encrypted archive without a password means the header was
            // plaintext, so nothing has been proven and the user still has to
            // supply one. `.passwordRequired` rather than `.wrongPassword`: no
            // password was rejected, so the sheet must not claim one was.
            //
            // When nothing is encrypted there is no password to rule on, and the
            // sheet is released rather than left waiting for a verdict.
            if isEncrypted {
                presentPasswordPrompt(
                    for: url,
                    validationContext: .listing,
                    error: .passwordRequired
                )
            } else {
                resolvePasswordVerification(
                    generation: verification,
                    verdict: .indeterminate
                )
            }
            return
        }
        do {
            try await service.verifyPassword(archive: url, password: password)
        } catch let error as ArchiveEngineError {
            guard listingGeneration == generation, currentArchive?.url == url else { return }
            switch error {
            case .wrongPassword, .passwordRequired:
                // Drop the proven-wrong credential from both stores before
                // prompting, so a retry cannot silently reuse it.
                invalidateSavedPasswordIfMatching(password, for: url)
                credentials.discard(for: url, ifMatching: password)
                presentPasswordPrompt(
                    for: url,
                    validationContext: .listing,
                    error: error
                )
            default:
                // An unrelated failure (a damaged archive, a missing binary) says
                // nothing about the password, so the sheet is released rather than
                // left waiting on a verdict that will not come.
                errorMessage = error.localizedDescription
                resolvePasswordVerification(
                    generation: verification,
                    verdict: .indeterminate
                )
            }
            return
        } catch {
            guard listingGeneration == generation, currentArchive?.url == url else { return }
            errorMessage = error.localizedDescription
            resolvePasswordVerification(
                generation: verification,
                verdict: .indeterminate
            )
            return
        }
        // Proven by decryption, so it is now safe to persist and to close the
        // sheet. Deliberately not guarded on staleness: the password was verified
        // for THIS archive, and a pending Keychain save the user asked for must
        // survive them switching away while the check ran.
        confirmPendingPasswordSave(for: url, password: password, context: .listing)
        resolvePasswordVerification(generation: verification, verdict: .correct)
    }

    /// Tell the user a mutation was refused because that archive is still busy.
    ///
    /// Only reached from `mutationGate.tryRun`, whose callers are user-driven, so
    /// asking them to retry is honest. Watcher-driven writes use `enqueue`
    /// instead and never surface this.
    func reportArchiveBusy() {
        errorMessage = String(localized: "Another change to this archive is still in progress. Please wait for it to finish.")
    }

    /// Test integrity of the currently open archive.
    func testCurrentArchive() {
        guard let url = currentArchive?.url else { return }
        let pwd = credential(for: url)
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
