import Foundation
import os
import XZIPCore
import XZIPDomain
import XZIPRuntime

protocol ExtractionBridging: Sendable {
    func preflight(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> ExtractionPreflight

    func extract(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?
    ) -> AsyncThrowingStream<Double, Error>
}

extension TransactionalExtractionBridge: ExtractionBridging {}

/// Decides which extraction path a request takes, and owns the transactional
/// stack's startup gate.
///
/// Extraction uses only the transactional runtime. The staging namespace lives
/// in Application Support, and the transaction publishes files by renaming them
/// out of staging — which the kernel only allows within one filesystem. The
/// journal enforces this by refusing a destination on another volume, so such an
/// extraction remains unavailable rather than granting a backend direct final-
/// destination authority.
///
/// Password-protected archives *do* use the transactional path (Wave 9D): the
/// bridge deposits the credential for the operation and the runtime's resolver
/// withdraws it exactly once.
///
/// Anything the router cannot positively identify remains unavailable rather
/// than bypassing transactional destination authority.
@MainActor
final class ExtractionRouter {

    /// Set once the transactional stack is assembled and crash recovery has
    /// completed. `nil` means safe extraction is unavailable.
    private var bridge: Bridge?

    /// Why safe extraction is unavailable, surfaced for diagnostics and retry.
    private(set) var unavailableReason: String?

    /// Volume of the staging namespace, resolved once assembly succeeds.
    ///
    /// Kept as the volume identifier Foundation reports rather than a device
    /// number: it is documented for exactly this comparison, and it avoids this
    /// layer duplicating the `stat` handling the runtime already owns.
    private var stagingVolume: (any NSObjectProtocol)?

    /// How the staging volume is resolved. Injectable so a test can exercise the
    /// cross-volume route without a second physical volume attached; production
    /// resolves it from the real Application Support container.
    private let resolveStagingVolume: () -> (any NSObjectProtocol)?

    private static let log = Logger(
        subsystem: "com.codetay.xzip",
        category: "ExtractionRouter"
    )

    /// The in-flight assembly, shared by every concurrent caller.
    ///
    /// Being `@MainActor` is **not** enough to make `prepare()` run once:
    /// it suspends on `await`, so two callers can both pass the "already
    /// prepared?" check before either stores a result. Since assembly runs crash
    /// recovery over a shared durable namespace, that would reconcile the same
    /// state twice concurrently.
    private var assembly: Task<Result<Bridge, Error>, Never>?

    private let makeBridge: @Sendable () async throws -> Bridge

    /// The assembly produces the bridge rather than the runtime: the credential
    /// registry that feeds the runtime's resolver is internal to XZIPRuntime, so
    /// only that module can connect the two.
    typealias Bridge = any ExtractionBridging

    init(
        makeBridge: (@Sendable () async throws -> Bridge)? = nil,
        resolveStagingVolume: (() -> (any NSObjectProtocol)?)? = nil
    ) {
        self.makeBridge = makeBridge ?? Self.makeLiveBridge
        self.resolveStagingVolume = resolveStagingVolume ?? {
            try? Self.applicationSupportDirectory()
                .resourceValues(forKeys: [.volumeIdentifierKey])
                .volumeIdentifier
        }
    }

    // MARK: - Startup gate

    /// Assembles the transactional stack, which runs crash recovery to
    /// completion before the runtime becomes usable.
    ///
    /// Safe to call from several places (each window's `.task`, a retry): the
    /// first call starts assembly and the rest await that same work.
    ///
    /// Recovery failure is recorded rather than thrown. The app keeps extraction
    /// blocked and can surface the reason while allowing a later retry.
    func prepare() async {
        guard bridge == nil else { return }

        let task: Task<Result<Bridge, Error>, Never>
        if let inFlight = assembly {
            task = inFlight
        } else {
            let make = makeBridge
            task = Task {
                do { return .success(try await make()) }
                catch { return .failure(error) }
            }
            // Assigned before the first await below, so a caller arriving during
            // assembly joins this task instead of starting a second one.
            assembly = task
        }

        switch await task.value {
        case let .success(assembled):
            // Concurrent callers all land here with the same bridge; keep the
            // first rather than replacing a live one.
            if bridge == nil {
                bridge = assembled
            }
            unavailableReason = nil
            // Resolved here rather than per extraction: it cannot change for the
            // lifetime of the process, and a failure to resolve it must not fail
            // the gate that just succeeded.
            if stagingVolume == nil {
                stagingVolume = resolveStagingVolume()
            }
            // The stored bridge is the result now, so drop the completed task
            // rather than retaining it for the process lifetime.
            assembly = nil
        case let .failure(error):
            bridge = nil
            unavailableReason = String(describing: error)
            // Cleared so a later attempt can retry, matching the pre-existing
            // behaviour where a failed gate did not permanently disable the
            // transactional path.
            assembly = nil
        }
    }

    // MARK: - Routing

    /// Whether this extraction can go through the transactional path.
    ///
    /// `detectedFormat` is content-detected from magic bytes *where a signature
    /// exists*, but `ArchiveFormatDetector` carries no DMG/UDIF signature — the
    /// UDIF marker lives in a trailer at the end of the file, outside the header
    /// window the detector reads — and it falls back to inferring the format
    /// from the filename when no signature matches. A DMG is therefore
    /// recognised by its `.dmg` extension, and a DMG deliberately renamed
    /// `.zip` is *not* caught here: it is inferred as `.zip` and routed to the
    /// transactional path, where 7zz rejects it. That yields a confusing error
    /// message rather than a clean "unsupported format", which is an accepted
    /// trade-off for a case that only arises from a misleading filename.
    nonisolated static func canUseTransaction(
        format: ArchiveFormat?,
        hasPassword: Bool
    ) -> Bool {
        // `hasPassword` no longer gates the decision: the transactional path
        // carries credentials as of Wave 9D. Kept in the signature because the
        // caller resolves it anyway and a future format might need it.
        _ = hasPassword
        guard format != nil else { return false }
        return true
    }

    /// Volume identifier for `destination`, or for its nearest existing
    /// ancestor when the destination folder has not been created yet (extracting
    /// into a new subfolder is the common case).
    ///
    /// `nil` means the volume could not be determined, which callers treat as
    /// ineligible rather than guessing and losing transactional guarantees.
    ///
    /// `nonisolated` for the same reason as `canUseTransaction`: it is a pure
    /// function of its argument and reads none of the router's state.
    nonisolated static func volumeIdentifier(
        of destination: URL
    ) -> (any NSObjectProtocol)? {
        var candidate = destination.standardizedFileURL
        while true {
            if let identifier = try? candidate.resourceValues(
                forKeys: [.volumeIdentifierKey]
            ).volumeIdentifier {
                return identifier
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            // deletingLastPathComponent() is a fixed point at the root, so this
            // is what terminates the walk.
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }

    /// Whether `destination` sits on the volume the staging namespace is on.
    ///
    /// Separate from `canUseTransaction` so it can be tested against a mismatched
    /// identifier without needing a second physical volume attached.
    nonisolated static func destinationSharesVolume(
        destination: URL,
        stagingVolume: (any NSObjectProtocol)?
    ) -> Bool {
        guard let stagingVolume,
              let destinationVolume = volumeIdentifier(of: destination)
        else { return false }
        return stagingVolume.isEqual(destinationVolume)
    }

    /// The bridge to extract through, or `nil` when safe extraction is unavailable.
    ///
    /// Returns the bridge rather than a ready-made stream on purpose: the
    /// operation runner builds its stream lazily and rebuilds it on Retry, and
    /// an `AsyncThrowingStream` starts its work as soon as it is constructed. A
    /// pre-built stream would therefore begin extracting before the operation
    /// was queued, and a retry would re-consume an already-finished stream. The
    /// bridge is `Sendable`, so the caller can hold it in the runner's
    /// non-isolated closure.
    ///
    /// `destination` is required rather than defaulted: a caller that forgot to
    /// pass it would silently route a cross-volume extraction into the
    /// transaction, which is the failure this parameter exists to prevent.
    func transactionalBridge(
        format: ArchiveFormat?,
        hasPassword: Bool,
        destination: URL
    ) -> Bridge? {
        guard Self.canUseTransaction(format: format, hasPassword: hasPassword) else {
            return nil
        }
        guard Self.destinationSharesVolume(
            destination: destination,
            stagingVolume: stagingVolume
        ) else {
            Self.log.notice(
                """
                Destination is not on the staging volume; safe extraction is \
                unavailable: \(destination.path, privacy: .private)
                """
            )
            return nil
        }
        return bridge
    }

    // MARK: - Live wiring

    /// Mirrors `ArchiveService.live()`'s binary discovery so both paths run the
    /// same `7zz`.
    private static let makeLiveBridge: @Sendable () async throws -> Bridge = {
        let binDir = Bundle.main.resourceURL?.appendingPathComponent("bin")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin")
        let policy = ArchiveResourcePolicy.production
        let locator = BinaryLocator(searchDirectories: [binDir])
        let processController = ProcessController(
            policy: policy,
            permits: LocalProcessPermitPool(
                limit: policy.scheduling.globalProcessLimit
            )
        )
        let sevenZip = SevenZipEngine(
            runner: processController,
            locator: locator,
            policy: policy
        )
        let dmg = DMGEngine(runner: processController)
        let stagingExtractor = FormatRoutingArchiveStagingExtractor(
            fallback: sevenZip,
            overrides: [.dmg: dmg]
        )
        return try await LiveExtractionAssembly.liveBridge(
            backend: ExtractionOnlyArchiveBackend(),
            stagingExtractor: stagingExtractor,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: try applicationSupportDirectory(),
            policy: policy
        )
    }

    /// The app's own Application Support container, created if absent. The
    /// transaction namespace lives beneath it.
    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let container = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.codetay.xzip",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return container
    }
}
