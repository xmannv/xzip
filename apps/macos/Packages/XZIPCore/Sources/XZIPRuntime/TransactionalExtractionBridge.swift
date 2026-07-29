import Foundation
import XZIPCore
import XZIPDomain

/// Adapts the transactional runtime's extraction API to the fraction-stream
/// shape the app's operation UI is built around.
///
/// `ArchiveRuntime.extract` is `async throws -> Void` and reports progress out
/// of band through `progress(for:)`, while `AppModel.run` consumes an
/// `AsyncThrowingStream<Double, Error>`. This bridge translates between the two
/// so the cutover does not require rewriting the operation UI.
///
/// **Progress registration is ordered, not incidental.** The observation store
/// buffers only the newest event and finishes a subscriber immediately if the
/// operation is already terminal, so the subscription is taken out *before*
/// `extract` is invoked. Registering afterwards would race the operation and
/// could yield a stream that finishes without ever reporting progress.
public struct TransactionalExtractionBridge<
    Runtime: ArchiveRuntimeClient & ArchiveRuntimeObserving & ArchiveExtractionPreflighting
>: Sendable {

    private let runtime: Runtime
    private let resourcePolicy: ArchiveResourcePolicy
    private let preserveTimestamps: Bool

    /// Where a per-operation password is deposited for the runtime's credential
    /// resolver to withdraw. `nil` means this bridge was built without a
    /// credential seam, in which case encrypted archives are refused rather than
    /// extracted passwordless.
    private let credentials: EphemeralCredentialRegistry?

    /// Builds a bridge with no credential seam.
    ///
    /// Extraction of password-protected archives requires the registry that
    /// `LiveExtractionAssembly.live` wires to the runtime's resolver, so a bridge
    /// made here refuses them. Use `live` for the production path.
    public init(
        runtime: Runtime,
        resourcePolicy: ArchiveResourcePolicy = .production,
        preserveTimestamps: Bool = true
    ) {
        self.init(
            runtime: runtime,
            resourcePolicy: resourcePolicy,
            preserveTimestamps: preserveTimestamps,
            credentials: nil
        )
    }

    /// Builds a bridge that can carry credentials.
    ///
    /// Internal because `EphemeralCredentialRegistry` is module-internal: the app
    /// never handles the registry, and no public API exposes a raw password.
    init(
        runtime: Runtime,
        resourcePolicy: ArchiveResourcePolicy = .production,
        preserveTimestamps: Bool = true,
        credentials: EphemeralCredentialRegistry?
    ) {
        self.runtime = runtime
        self.resourcePolicy = resourcePolicy
        self.preserveTimestamps = preserveTimestamps
        self.credentials = credentials
    }

    /// Maps the app's extraction policy onto the runtime's conflict policy.
    ///
    /// The mapping is exhaustive by design: `ExistingFilePolicy` has no `.ask`
    /// case, so the runtime's `.ask` — which `ExtractionTransaction` rejects
    /// with `unresolvedConflictPolicy` — is unreachable from the app.
    static func conflictPolicy(
        for policy: ExistingFilePolicy
    ) -> OperationConflictPolicy {
        switch policy {
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        case .fail: .fail
        }
    }

    public func preflight(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> ExtractionPreflight {
        if options.password != nil, credentials == nil {
            throw TransactionalExtractionUnsupported.credentialsUnavailable
        }

        let locator = try await runtime.openArchive(at: archive)
        try DarwinFileSystemOperations().createDirectoryPathNoFollow(
            at: destination
        )

        let operationID = OperationID()
        if let password = options.password, let credentials {
            await credentials.deposit(password, for: operationID)
        }

        do {
            let preflight = try await runtime.preflightExtraction(
                ExtractionPreflightRequest(
                    operationID: operationID,
                    sessionID: ArchiveSessionID(),
                    archive: locator,
                    destination: destination,
                    selectedEntries: options.selectedEntries,
                    conflictPolicy: Self.conflictPolicy(
                        for: options.existingFilePolicy
                    ),
                    preserveTimestamps: preserveTimestamps,
                    resourcePolicy: resourcePolicy,
                    ui: OperationUIMetadata(title: "Extract")
                )
            )
            await credentials?.discard(operationID)
            return preflight
        } catch {
            await credentials?.discard(operationID)
            throw error
        }
    }

    public func extract(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?
    ) -> AsyncThrowingStream<Double, Error> {
        let operationID = OperationID()
        let credentialDeposit = CredentialDepositSettlement()
        let progress = ExtractionProgressBuffer()
        let execution = ExtractionExecutionController {
            do {
                if preflight.requiresDestructiveReplacementApproval,
                   replacementApproval == nil {
                    throw ArchiveFailure.destructiveReplacementApprovalRequired
                }
                if password != nil, credentials == nil {
                    throw TransactionalExtractionUnsupported.credentialsUnavailable
                }
                try Task.checkCancellation()
                if let password, let credentials {
                    await credentials.deposit(password, for: operationID)
                }
                credentialDeposit.settle()
                try Task.checkCancellation()

                let events = await runtime.progress(for: operationID)
                let pump = Task {
                    for await event in events {
                        if case let .archive(archiveProgress) = event,
                           let fraction = archiveProgress.fraction {
                            await progress.yield(fraction)
                        }
                    }
                }

                let request = ExtractionRequest(
                    operationID: operationID,
                    sessionID: ArchiveSessionID(),
                    archive: preflight.archive,
                    destination: preflight.destination,
                    selectedEntries: preflight.selectedEntries,
                    conflictPolicy: preflight.conflictPolicy,
                    preserveTimestamps: preflight.preserveTimestamps,
                    resourcePolicy: preflight.resourcePolicy,
                    ui: OperationUIMetadata(title: "Extract"),
                    expectedArchiveRevision: preflight.archiveRevision,
                    expectedDestinationIdentity: preflight.destinationIdentity,
                    planDigest: preflight.planDigest,
                    publicationBinding: preflight.publicationBinding,
                    replacementApproval: replacementApproval
                )

                do {
                    try await runtime.extract(request)
                } catch {
                    pump.cancel()
                    await pump.value
                    throw error
                }
                pump.cancel()
                await pump.value
                await credentials?.discard(operationID)
                await progress.yield(1.0)
                await progress.finish()
            } catch {
                credentialDeposit.settle()
                await credentials?.discard(operationID)
                await progress.finish(throwing: error)
            }
        }

        return AsyncThrowingStream(unfolding: {
            do {
                try Task.checkCancellation()
                await execution.start()
                try Task.checkCancellation()
                let fraction = try await progress.next()
                guard Task.isCancelled else { return fraction }
                throw CancellationError()
            } catch {
                guard Task.isCancelled || error is CancellationError else {
                    throw error
                }

                await execution.cancelAndWait()
                await credentialDeposit.waitUntilSettled()
                await credentials?.discard(operationID)
                throw CancellationError()
            }
        })
    }
}

actor ExtractionExecutionController {
    private var operation: (@Sendable () async -> Void)?
    private var work: Task<Void, Never>?

    init(operation: @escaping @Sendable () async -> Void) {
        self.operation = operation
    }

    func start() {
        guard work == nil, let operation else { return }
        self.operation = nil
        work = Task { await operation() }
    }

    func cancelAndWait() async {
        guard let work else { return }
        work.cancel()
        await work.value
    }
}

private actor ExtractionProgressBuffer {
    private enum Terminal {
        case open
        case finished
        case failed(any Error)
    }

    private var bufferedFractions: [Double] = []
    private var terminal: Terminal = .open
    private var pendingNext:
        CheckedContinuation<Result<Double?, any Error>, Never>?

    func yield(_ fraction: Double) {
        guard case .open = terminal else { return }
        if let pendingNext {
            self.pendingNext = nil
            pendingNext.resume(returning: .success(fraction))
        } else {
            bufferedFractions.append(fraction)
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        guard case .open = terminal else { return }
        terminal = error.map(Terminal.failed) ?? .finished
        resumePendingNextIfPossible()
    }

    func next() async throws -> Double? {
        let result: Result<Double?, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else if let fraction = bufferedFractions.first {
                    bufferedFractions.removeFirst()
                    continuation.resume(returning: .success(fraction))
                } else {
                    switch terminal {
                    case .open:
                        pendingNext = continuation
                    case .finished:
                        continuation.resume(returning: .success(nil))
                    case let .failed(error):
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await cancelPendingNext() }
        }
        return try result.get()
    }

    private func cancelPendingNext() {
        guard let pendingNext else { return }
        self.pendingNext = nil
        pendingNext.resume(returning: .failure(CancellationError()))
    }

    private func resumePendingNextIfPossible() {
        guard bufferedFractions.isEmpty, let pendingNext else { return }
        switch terminal {
        case .open:
            return
        case .finished:
            self.pendingNext = nil
            pendingNext.resume(returning: .success(nil))
        case let .failed(error):
            self.pendingNext = nil
            pendingNext.resume(returning: .failure(error))
        }
    }
}

private struct CredentialDepositSettlement: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func settle() {
        continuation.yield(())
        continuation.finish()
    }

    func waitUntilSettled() async {
        for await _ in stream { return }
    }
}

/// Extraction shapes the transactional path does not accept yet, and which the
/// caller must keep on the legacy path.
public enum TransactionalExtractionUnsupported: Error, Equatable, Sendable {
    /// A password was supplied to a bridge built without a credential seam.
    /// The production bridge from `LiveExtractionAssembly.live` has one.
    case credentialsUnavailable
}
