import Foundation
import XZIPCore
import XZIPDomain

/// Assembles the live transactional extraction stack and gates it behind crash
/// recovery before exposing a ready `ArchiveRuntime`.
///
/// This is the production cutover seam (State Task 9): it wires the Wave 9A/9B
/// collaborators — `AppSupportTransactionNamespaceProvider`,
/// `TransactionJournalStore`, `ExtractionRecoveryCoordinator`,
/// `LiveArchiveExtractionBackendAdapter` (over a Core `ArchiveStagingExtracting`),
/// `LivePublicationQuarantine`, `ExtractionTransaction`, and
/// `TransactionalArchiveExtractionHandler` — and injects the handler into an
/// `ArchiveRuntime`.
///
/// It lives in XZIPRuntime because the handler, its initializer, and the
/// `ArchiveRuntime` handler-injecting initializer are all `internal`.
///
/// **Recovery-before-availability gate:** `recoverLiveTransactions()` runs to
/// completion *before* the runtime is constructed. If recovery throws, the
/// factory throws and no transactional runtime is produced, so operations never
/// begin on an unreconciled durable state.
public enum LiveExtractionAssembly {

    /// Ordering seam: runs `recover` fully, then builds the runtime. Any
    /// recovery failure propagates and `makeRuntime` is never invoked. Kept
    /// generic so the gate ordering can be verified without a real runtime.
    static func assemble<Runtime>(
        recover: () async throws -> Void,
        makeRuntime: () async throws -> Runtime
    ) async throws -> Runtime {
        try await recover()
        return try await makeRuntime()
    }

    /// Builds the live transactional `ArchiveRuntime`.
    ///
    /// - Parameters:
    ///   - backend: the legacy `ArchiveBackend` for non-extraction operations
    ///     (comment/list/compress/etc). Extraction is routed through the
    ///     injected transactional handler, never this backend.
    ///   - stagingExtractor: the Core staging extractor (for production, a
    ///     `FormatRoutingArchiveStagingExtractor`), wrapped by
    ///     `LiveArchiveExtractionBackendAdapter`.
    ///   - identityResolver: resolves archive URLs to stable identities.
    ///   - applicationSupportDirectory: parent of the transaction namespace.
    ///   - now/uuidProvider: injectable clock/UUID for the quarantine value.
    ///
    /// The returned runtime has a credential resolver, but no way to reach the
    /// registry that feeds it. Use `liveBridge` for extraction of
    /// password-protected archives; this entry point is for callers that only
    /// need the runtime itself.
    public static func live(
        backend: any ArchiveBackend,
        stagingExtractor: any ArchiveStagingExtracting,
        identityResolver: any ArchiveIdentityResolving,
        applicationSupportDirectory: URL,
        namespaceName: String = "transactions",
        indexFileName: String = "extraction-index.json",
        policy: ArchiveResourcePolicy = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) async throws -> ArchiveRuntime {
        try await liveStack(
            backend: backend,
            stagingExtractor: stagingExtractor,
            identityResolver: identityResolver,
            applicationSupportDirectory: applicationSupportDirectory,
            namespaceName: namespaceName,
            indexFileName: indexFileName,
            policy: policy,
            now: now,
            uuidProvider: uuidProvider
        ).runtime
    }

    /// Builds the live transactional stack and returns it as the progress-stream
    /// bridge the app's operation UI consumes.
    ///
    /// This is the only way to obtain a bridge that can extract
    /// password-protected archives. The credential registry it wires to the
    /// handler's resolver is module-internal, so the app cannot connect the two
    /// itself — which is deliberate: no public API takes or exposes a raw
    /// password.
    public static func liveBridge(
        backend: any ArchiveBackend,
        stagingExtractor: any ArchiveStagingExtracting,
        identityResolver: any ArchiveIdentityResolving,
        applicationSupportDirectory: URL,
        namespaceName: String = "transactions",
        indexFileName: String = "extraction-index.json",
        policy: ArchiveResourcePolicy = .production,
        preserveTimestamps: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) async throws -> TransactionalExtractionBridge<ArchiveRuntime> {
        let stack = try await liveStack(
            backend: backend,
            stagingExtractor: stagingExtractor,
            identityResolver: identityResolver,
            applicationSupportDirectory: applicationSupportDirectory,
            namespaceName: namespaceName,
            indexFileName: indexFileName,
            policy: policy,
            now: now,
            uuidProvider: uuidProvider
        )
        return TransactionalExtractionBridge(
            runtime: stack.runtime,
            resourcePolicy: policy,
            preserveTimestamps: preserveTimestamps,
            credentials: stack.credentials
        )
    }

    /// The assembled stack: the runtime plus the registry its resolver draws
    /// from, which the caller needs to deposit per-operation credentials.
    struct LiveStack {
        let runtime: ArchiveRuntime
        let credentials: EphemeralCredentialRegistry
    }

    static func liveStack(
        backend: any ArchiveBackend,
        stagingExtractor: any ArchiveStagingExtracting,
        identityResolver: any ArchiveIdentityResolving,
        applicationSupportDirectory: URL,
        namespaceName: String = "transactions",
        indexFileName: String = "extraction-index.json",
        policy: ArchiveResourcePolicy = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) async throws -> LiveStack {
        let fileSystem = DarwinFileSystemOperations()

        let namespaceProvider = try AppSupportTransactionNamespaceProvider(
            applicationSupportDirectory: applicationSupportDirectory,
            namespaceName: namespaceName,
            fileSystem: fileSystem
        )
        let namespace = await namespaceProvider.trustedNamespace()
        // The journal index lives in the transaction namespace directory
        // itself; open a transaction-owned (0700, no-follow) handle to it.
        let indexDirectory = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespace.url,
            expected: namespace.identity
        )
        let journal = TransactionJournalStore(
            indexDirectory: indexDirectory,
            indexFileName: indexFileName,
            policy: policy,
            fileSystem: fileSystem
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: journal,
            fileSystem: fileSystem
        )
        let adapter = LiveArchiveExtractionBackendAdapter(
            stagingExtractor: stagingExtractor
        )
        let quarantine = LivePublicationQuarantine(now: now, uuidProvider: uuidProvider)
        let stateResolver = ExtractionStateResolver(
            archiveIdentityResolver: identityResolver,
            fileSystem: fileSystem
        )
        let transaction = ExtractionTransaction(
            backend: adapter,
            journal: journal,
            preparationAborter: recovery,
            namespaceProvider: namespaceProvider,
            fileSystem: fileSystem,
            stateResolver: stateResolver,
            quarantine: quarantine
        )
        // Injected once here, but a password only exists per-operation, so the
        // registry is the seam the caller deposits into. The resolver withdraws
        // it, which removes it.
        let credentials = EphemeralCredentialRegistry()
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: journal,
            committedFinalizer: recovery,
            credentialResolver: credentials
        )

        let runtime = try await assemble(
            recover: { try await recovery.recoverLiveTransactions() },
            makeRuntime: {
                ArchiveRuntime(
                    backend: backend,
                    identityResolver: identityResolver,
                    policy: policy,
                    extractionHandler: handler
                )
            }
        )
        return LiveStack(runtime: runtime, credentials: credentials)
    }
}
