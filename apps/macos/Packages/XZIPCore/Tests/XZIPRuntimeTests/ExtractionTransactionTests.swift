import Darwin
import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

private enum ExtractionTransactionTestError: Error, Equatable {
    case unexpectedCall(String)
}

private actor DescriptorRecorder: ArchiveRuntimeClient {
    private(set) var descriptors: [OperationDescriptor] = []

    func openArchive(at url: URL) async throws -> ArchiveLocator {
        throw ExtractionTransactionTestError.unexpectedCall("openArchive")
    }

    func executeOperation(_ descriptor: OperationDescriptor) async throws {
        descriptors.append(descriptor)
    }
}

private actor HandlerRecorder: ArchiveExtractionHandling {
    private var preparation: ArchiveExtractionPreparation
    private var freshExecution: ArchiveExtractionExecution
    private(set) var preparedDescriptors: [OperationDescriptor] = []
    private(set) var freshDescriptors: [OperationDescriptor] = []

    init(
        preparation: ArchiveExtractionPreparation,
        freshExecution: ArchiveExtractionExecution
    ) {
        self.preparation = preparation
        self.freshExecution = freshExecution
    }

    func setPreparation(_ preparation: ArchiveExtractionPreparation) {
        self.preparation = preparation
    }

    func preflight(
        request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight {
        throw ExtractionTransactionTestError.unexpectedCall("preflight")
    }

    func prepare(
        descriptor: OperationDescriptor
    ) async throws -> ArchiveExtractionPreparation {
        preparedDescriptors.append(descriptor)
        return preparation
    }

    func executeFresh(
        payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ArchiveExtractionExecution {
        freshDescriptors.append(descriptor)
        return freshExecution
    }
}

private final class LegacyExtractionBackendSpy: ArchiveBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var extractionCalls = 0

    func extractionCallCount() -> Int {
        lock.withLock { extractionCalls }
    }

    func readComment(for archive: URL) async throws -> String {
        throw ExtractionTransactionTestError.unexpectedCall("readComment")
    }

    func writeComment(_ comment: String, to archive: URL) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("writeComment")
    }

    func canEditComment(for archive: URL) -> Bool { false }

    func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult? {
        throw ExtractionTransactionTestError.unexpectedCall("detectSplit")
    }

    func joinSplit(
        parts: [URL],
        destination: URL
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ExtractionTransactionTestError.unexpectedCall("joinSplit"))
        }
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        throw ExtractionTransactionTestError.unexpectedCall("compress")
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        lock.withLock { extractionCalls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func detectedFormat(for archive: URL) -> ArchiveFormat? { nil }

    func list(archive: URL, password: String?) async throws -> [ArchiveEntry] { [] }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        ArchiveListingResult(entries: [], truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        throw ExtractionTransactionTestError.unexpectedCall("test")
    }

    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("add")
    }

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("addViaRepack")
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("delete")
    }

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("rename")
    }

    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("update")
    }
}

private struct ThrowingArchiveIdentityResolver: ArchiveIdentityResolving {
    func resolve(_ url: URL) throws -> ResolvedArchive {
        throw ExtractionTransactionTestError.unexpectedCall("identityResolver")
    }
}

private actor FinalizerRecorder {
    private(set) var attempts = 0

    func record() {
        attempts += 1
    }
}

private actor CredentialRecorder: EphemeralExtractionCredentialResolving {
    private let events: TransactionEventLog?
    private(set) var calls = 0

    init(events: TransactionEventLog? = nil) {
        self.events = events
    }

    func resolveExtractionCredential(
        sessionID: ArchiveSessionID,
        operationID: OperationID,
        archiveID: ArchiveID
    ) async throws -> String? {
        calls += 1
        events?.append("credential")
        return "secret"
    }
}

private struct AbsentDurableResolver: DurableExtractionResolving {
    func resolveExtraction(
        for operationID: OperationID
    ) async throws -> DurableExtractionResolution {
        .absent
    }
}

private struct NoopCommittedFinalizer: CommittedExtractionFinalizing {
    func finalizeCommittedExtraction(operationID: OperationID) async throws {}
}

private struct UnexpectedPreparationAborter: ExtractionPreparationAborting {
    func abortPreparation(transactionID: TransactionID) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("abortPreparation")
    }
}

private struct UnexpectedNamespaceProvider: TransactionNamespaceProviding {
    func namespace(
        forDestinationIdentity destinationIdentity: FileNodeIdentity
    ) async throws -> TransactionNamespaceLocator {
        throw ExtractionTransactionTestError.unexpectedCall("namespace")
    }
}

private struct NoopQuarantine: PublicationQuarantining {
    func apply(
        to entries: [QuarantineManifestEntry],
        stagingRoot: URL,
        stagingRootIdentity: FileNodeIdentity,
        fileSystem: any FileSystemOperations
    ) throws {}
}

private struct UnexpectedExtractionBackend: ArchiveExtractionBackend {
    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        throw ExtractionTransactionTestError.unexpectedCall("inventory")
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ExtractionTransactionTestError.unexpectedCall("stage"))
        }
    }
}

private struct UnexpectedJournal: ExtractionJournalStore {
    func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation {
        throw ExtractionTransactionTestError.unexpectedCall("register")
    }

    func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity {
        throw ExtractionTransactionTestError.unexpectedCall("createTransactionRoot")
    }

    func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction {
        throw ExtractionTransactionTestError.unexpectedCall("activate")
    }

    func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("relinquishPreparation")
    }

    func markRolledBack(_ transactionID: TransactionID) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("markRolledBack")
    }

    func releaseRolledBack(_ transactionID: TransactionID) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("releaseRolledBack")
    }

    func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws {
        throw ExtractionTransactionTestError.unexpectedCall("markCommitted")
    }
}

private final class TransactionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    func values() -> [String] {
        lock.withLock { storage }
    }
}

private final class StagingExtractionBackend: ArchiveExtractionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let inventoryValue: ExtractionInventory
    private let progressValues: [ArchiveProgress]
    private let stagingError: Error?
    private let cancelTaskOnStaging: Bool
    private let extraStagingPath: String?
    private let omittedStagingPaths: Set<String>
    private let sparseFileSizes: [String: UInt64]
    private let stagedDirectoryMode: Int
    private let events: TransactionEventLog?
    private var inventoryPasswords: [String?] = []
    private var stagingPasswords: [String?] = []
    private var receivedManifests: [StagingCleanupManifest] = []
    private var receivedPreserveTimestamps: [Bool] = []
    private var receivedPolicies: [ArchiveResourcePolicy] = []
    private var receivedStagingDestinations: [URL] = []

    init(
        inventory: ExtractionInventory,
        progressValues: [ArchiveProgress] = [],
        stagingError: Error? = nil,
        cancelTaskOnStaging: Bool = false,
        extraStagingPath: String? = nil,
        omittedStagingPaths: Set<String> = [],
        sparseFileSizes: [String: UInt64] = [:],
        // Real extractors recreate archive directories with the mode recorded
        // in the archive, so the default mirrors `7zz` (0755) rather than the
        // transaction's own 0700. The transaction must adopt such a tree at any
        // point in its lifetime, including after a failure or a crash.
        stagedDirectoryMode: Int = 0o755,
        events: TransactionEventLog? = nil
    ) {
        inventoryValue = inventory
        self.progressValues = progressValues
        self.stagingError = stagingError
        self.cancelTaskOnStaging = cancelTaskOnStaging
        self.extraStagingPath = extraStagingPath
        self.omittedStagingPaths = omittedStagingPaths
        self.sparseFileSizes = sparseFileSizes
        self.stagedDirectoryMode = stagedDirectoryMode
        self.events = events
    }

    func observations() -> (
        inventoryPasswords: [String?],
        stagingPasswords: [String?],
        manifests: [StagingCleanupManifest],
        preserveTimestamps: [Bool],
        policies: [ArchiveResourcePolicy],
        stagingDestinations: [URL]
    ) {
        lock.withLock {
            (
                inventoryPasswords,
                stagingPasswords,
                receivedManifests,
                receivedPreserveTimestamps,
                receivedPolicies,
                receivedStagingDestinations
            )
        }
    }

    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        lock.withLock { inventoryPasswords.append(password) }
        events?.append("inventory")
        return inventoryValue
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.withLock {
            stagingPasswords.append(password)
            receivedManifests.append(cleanupManifest)
            receivedPreserveTimestamps.append(preserveTimestamps)
            receivedPolicies.append(policy)
            receivedStagingDestinations.append(destination)
        }
        events?.append("stage")
        let inventory = inventoryValue
        let progressValues = progressValues
        let stagingError = stagingError
        let extraStagingPath = extraStagingPath
        if cancelTaskOnStaging {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        let omittedStagingPaths = omittedStagingPaths
        let sparseFileSizes = sparseFileSizes
        let stagedDirectoryMode = stagedDirectoryMode
        return AsyncThrowingStream { continuation in
            do {
                let directories = cleanupManifest.entries
                    .filter { $0.kind == .directory }
                    .sorted { pathLess($0.relativePath, $1.relativePath) }
                for entry in directories where !omittedStagingPaths.contains(entry.relativePath) {
                    try FileManager.default.createDirectory(
                        at: destination.appendingPathComponent(
                            entry.relativePath,
                            isDirectory: true
                        ),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: stagedDirectoryMode]
                    )
                }
                for entry in inventory.entries
                where entry.kind != .directory && !omittedStagingPaths.contains(entry.path) {
                    let url = destination.appendingPathComponent(entry.path)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: stagedDirectoryMode]
                    )
                    switch entry.kind {
                    case .regularFile:
                        if let logicalSize = sparseFileSizes[entry.path] {
                            let descriptor = Darwin.open(
                                url.path,
                                O_WRONLY | O_CREAT | O_EXCL,
                                S_IRUSR | S_IWUSR
                            )
                            guard descriptor >= 0 else {
                                throw NSError(
                                    domain: NSPOSIXErrorDomain,
                                    code: Int(errno)
                                )
                            }
                            defer { Darwin.close(descriptor) }
                            guard ftruncate(descriptor, off_t(logicalSize)) == 0 else {
                                throw NSError(
                                    domain: NSPOSIXErrorDomain,
                                    code: Int(errno)
                                )
                            }
                        } else {
                            try Data(entry.path.utf8).write(to: url)
                        }
                    case .symbolicLink:
                        try FileManager.default.createSymbolicLink(
                            atPath: url.path,
                            withDestinationPath: entry.linkTarget ?? "target"
                        )
                    default:
                        break
                    }
                }
                if let extraStagingPath {
                    let extra = destination.appendingPathComponent(extraStagingPath)
                    try FileManager.default.createDirectory(
                        at: extra.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: stagedDirectoryMode]
                    )
                    try Data("extra".utf8).write(to: extra)
                }
                for value in progressValues {
                    continuation.yield(value)
                }
                if let stagingError {
                    continuation.finish(throwing: stagingError)
                } else {
                    continuation.finish()
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private final class ArchivePathSwapStagingBackend: ArchiveExtractionBackend, @unchecked Sendable {
    private let originalArchive: URL
    private let inventoryValue: ExtractionInventory

    init(originalArchive: URL, inventory: ExtractionInventory) {
        self.originalArchive = originalArchive
        inventoryValue = inventory
    }

    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        inventoryValue
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let detachedArchive = originalArchive.deletingLastPathComponent()
                .appendingPathComponent("original-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(
                    at: originalArchive,
                    to: detachedArchive
                )
                do {
                    try Data("foreign".utf8).write(to: originalArchive)
                    let materialized = try Data(contentsOf: archive.url)
                    try FileManager.default.removeItem(at: originalArchive)
                    try FileManager.default.moveItem(
                        at: detachedArchive,
                        to: originalArchive
                    )
                    try materialized.write(
                        to: destination.appendingPathComponent("file.txt")
                    )
                    continuation.finish()
                } catch {
                    try? FileManager.default.removeItem(at: originalArchive)
                    try? FileManager.default.moveItem(
                        at: detachedArchive,
                        to: originalArchive
                    )
                    throw error
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private final class BoundArchivePathSwapStagingBackend: ArchiveExtractionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let inventoryValue: ExtractionInventory
    private var receivedArchiveURL: URL?

    init(inventory: ExtractionInventory) {
        inventoryValue = inventory
    }

    func archiveURL() -> URL? {
        lock.withLock { receivedArchiveURL }
    }

    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        inventoryValue
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.withLock { receivedArchiveURL = archive.url }
        return AsyncThrowingStream { continuation in
            let detachedArchive = archive.url.deletingLastPathComponent()
                .appendingPathComponent("bound-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(
                    at: archive.url,
                    to: detachedArchive
                )
                do {
                    try Data("foreign".utf8).write(to: archive.url)
                    let materialized = try Data(contentsOf: archive.url)
                    try FileManager.default.removeItem(at: archive.url)
                    try FileManager.default.moveItem(
                        at: detachedArchive,
                        to: archive.url
                    )
                    try materialized.write(
                        to: destination.appendingPathComponent("file.txt")
                    )
                    continuation.finish()
                } catch {
                    try? FileManager.default.removeItem(at: archive.url)
                    try? FileManager.default.moveItem(
                        at: detachedArchive,
                        to: archive.url
                    )
                    throw error
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private final class SymlinkRetargetStagingBackend: ArchiveExtractionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let symlinkURL: URL
    private let originalTarget: URL
    private let replacementTarget: URL
    private let inventoryValue: ExtractionInventory
    private var inventoryCallCount = 0
    private var materializationCallCount = 0

    init(
        symlinkURL: URL,
        originalTarget: URL,
        replacementTarget: URL,
        inventory: ExtractionInventory
    ) {
        self.symlinkURL = symlinkURL
        self.originalTarget = originalTarget
        self.replacementTarget = replacementTarget
        inventoryValue = inventory
    }

    func observations() -> (inventoryCalls: Int, materializationCalls: Int) {
        lock.withLock { (inventoryCallCount, materializationCallCount) }
    }

    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        lock.withLock { inventoryCallCount += 1 }
        return inventoryValue
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.withLock { materializationCallCount += 1 }
        return AsyncThrowingStream { continuation in
            do {
                try retarget(to: replacementTarget)
                let materialized = try Data(contentsOf: archive.url)
                try retarget(to: originalTarget)
                try materialized.write(
                    to: destination.appendingPathComponent("file.txt")
                )
                continuation.finish()
            } catch {
                try? retarget(to: originalTarget)
                continuation.finish(throwing: error)
            }
        }
    }

    private func retarget(to target: URL) throws {
        try FileManager.default.removeItem(at: symlinkURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: target
        )
    }
}

private final class MultipartArchiveStagingBackend: ArchiveExtractionBackend, @unchecked Sendable {
    private let inventoryValue: ExtractionInventory

    init(inventory: ExtractionInventory) {
        inventoryValue = inventory
    }

    func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        guard FileManager.default.fileExists(atPath: companionURL(for: archive.url).path) else {
            throw ExtractionTransactionTestError.unexpectedCall("missing multipart companion")
        }
        return inventoryValue
    }

    func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            do {
                guard FileManager.default.fileExists(atPath: companionURL(for: archive.url).path) else {
                    throw ExtractionTransactionTestError.unexpectedCall("missing multipart companion")
                }
                try Data(contentsOf: archive.url).write(
                    to: destination.appendingPathComponent("file.txt")
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func companionURL(for archive: URL) -> URL {
        archive.deletingPathExtension().appendingPathExtension("z01")
    }
}

private final class ArchiveReleaseSwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let originalArchive: URL
    private var boundArchive: URL?
    private var detachedArchive: URL?

    init(originalArchive: URL) {
        self.originalArchive = originalArchive
    }

    func replaceBoundPathWithForeignFile(_ url: URL) throws {
        try lock.withLock {
            let detached = url.deletingLastPathComponent()
                .appendingPathComponent("release-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: url, to: detached)
            try Data("foreign".utf8).write(to: url)
            boundArchive = url
            detachedArchive = detached
        }
    }

    func foreignFileStillExists() -> Bool {
        lock.withLock {
            guard let boundArchive else { return false }
            return (try? Data(contentsOf: boundArchive)) == Data("foreign".utf8)
        }
    }

    func cleanup() {
        lock.withLock {
            guard let boundArchive, let detachedArchive else { return }
            try? FileManager.default.removeItem(at: boundArchive)
            if boundArchive == originalArchive {
                try? FileManager.default.moveItem(at: detachedArchive, to: originalArchive)
            } else {
                try? FileManager.default.removeItem(at: detachedArchive)
            }
        }
    }
}

private final class RecordingPublicationQuarantine: PublicationQuarantining, @unchecked Sendable {
    private let lock = NSLock()
    private let injectedError: Error?
    private let events: TransactionEventLog?
    private let onApply: (@Sendable () throws -> Void)?
    private var receivedEntries: [[QuarantineManifestEntry]] = []

    init(
        injectedError: Error? = nil,
        events: TransactionEventLog? = nil,
        onApply: (@Sendable () throws -> Void)? = nil
    ) {
        self.injectedError = injectedError
        self.events = events
        self.onApply = onApply
    }

    func entries() -> [[QuarantineManifestEntry]] {
        lock.withLock { receivedEntries }
    }

    func apply(
        to entries: [QuarantineManifestEntry],
        stagingRoot: URL,
        stagingRootIdentity: FileNodeIdentity,
        fileSystem: any FileSystemOperations
    ) throws {
        lock.withLock { receivedEntries.append(entries) }
        events?.append("quarantine")
        if let injectedError { throw injectedError }
        try onApply?()
    }
}

private actor RecordingExtractionJournal: ExtractionJournalStore {
    enum CommitBehavior: Sendable {
        case normal
        case failBeforeCommit
        case cancelAfterSuccess
        case uncertainAfterSuccess(URL)
    }

    private let base: any ExtractionJournalStore
    private let events: TransactionEventLog?
    private let commitBehavior: CommitBehavior
    private let afterAppend: (@Sendable (ExtractionJournalRecord) throws -> Void)?
    private let afterArm: (@Sendable (RecoveryJournalMutation) throws -> Void)?
    private let boundaryProbe: ExtractionTransactionBoundaryProbe?
    private let recoveryMutationTransform:
        (@Sendable ([RecoveryJournalMutation]) throws -> [RecoveryJournalMutation])?
    private(set) var registeredHeaders: [ExtractionJournalHeader] = []
    private(set) var appendRecords: [ExtractionJournalRecord] = []
    private(set) var armedMutations: [RecoveryJournalMutation] = []
    private(set) var committedResults: [ExtractionResult] = []
    private(set) var relinquishCount = 0
    private(set) var markRolledBackCount = 0
    private(set) var releaseRolledBackCount = 0

    init(
        base: any ExtractionJournalStore,
        events: TransactionEventLog? = nil,
        commitBehavior: CommitBehavior = .normal,
        afterAppend: (@Sendable (ExtractionJournalRecord) throws -> Void)? = nil,
        afterArm: (@Sendable (RecoveryJournalMutation) throws -> Void)? = nil,
        boundaryProbe: ExtractionTransactionBoundaryProbe? = nil,
        recoveryMutationTransform:
            (@Sendable ([RecoveryJournalMutation]) throws -> [RecoveryJournalMutation])? = nil
    ) {
        self.base = base
        self.events = events
        self.commitBehavior = commitBehavior
        self.afterAppend = afterAppend
        self.afterArm = afterArm
        self.boundaryProbe = boundaryProbe
        self.recoveryMutationTransform = recoveryMutationTransform
    }

    func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation {
        registeredHeaders.append(transaction)
        events?.append("register")
        return try await base.register(transaction: transaction, namespace: namespace)
    }

    func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity {
        events?.append("createRoot")
        return try await base.createTransactionRoot(reservation)
    }

    func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction {
        events?.append("activate")
        return try await base.activate(reservation)
    }

    func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws {
        relinquishCount += 1
        events?.append("relinquishPreparation")
        try await base.relinquishPreparation(reservation)
    }

    func armReplaceSwap(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCaptured: CapturedTreeManifest,
        transactionID: TransactionID
    ) async throws {
        let mutation = RecoveryJournalMutation.replaceSwap(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            replacementIdentity: replacementIdentity,
            expectedCaptured: expectedCaptured,
            recoveryCapturedIdentity: nil
        )
        events?.append("appendStart")
        try await base.armReplaceSwap(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            replacementIdentity: replacementIdentity,
            expectedCaptured: expectedCaptured,
            transactionID: transactionID
        )
        armedMutations.append(mutation)
        events?.append("appendReturned")
        try afterArm?(mutation)
        try boundaryProbe?.reach(.afterReplaceArmed)
    }

    func armPublishMove(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity,
        transactionID: TransactionID
    ) async throws {
        let mutation = RecoveryJournalMutation.publishMove(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            publishedIdentity: publishedIdentity
        )
        events?.append("appendStart")
        try await base.armPublishMove(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            publishedIdentity: publishedIdentity,
            transactionID: transactionID
        )
        armedMutations.append(mutation)
        events?.append("appendReturned")
        try afterArm?(mutation)
    }

    func recordsForRecovery(
        _ transactionID: TransactionID
    ) async throws -> [RecoveryJournalMutation] {
        try boundaryProbe?.reach(.afterAppliedRegistration)
        let mutations = try await base.recordsForRecovery(transactionID)
        return try recoveryMutationTransform?(mutations) ?? mutations
    }

    func markRolledBack(_ transactionID: TransactionID) async throws {
        markRolledBackCount += 1
        events?.append("markRolledBack")
        try await base.markRolledBack(transactionID)
    }

    func releaseRolledBack(_ transactionID: TransactionID) async throws {
        releaseRolledBackCount += 1
        events?.append("releaseRolledBack")
        try await base.releaseRolledBack(transactionID)
    }

    func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws {
        events?.append("markCommittedStart")
        if case .failBeforeCommit = commitBehavior {
            throw ExtractionTransactionTestError.unexpectedCall("markCommitted")
        }
        try await base.markCommitted(transactionID: transactionID, result: result)
        committedResults.append(result)
        events?.append("markCommittedReturned")
        try boundaryProbe?.reach(.afterDurableCommit)
        if case .cancelAfterSuccess = commitBehavior {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        if case let .uncertainAfterSuccess(recoveryURL) = commitBehavior {
            throw TransactionJournalError.commitStateUncertain(recoveryURL: recoveryURL)
        }
    }
}


private actor FailingActivationJournal: ExtractionJournalStore {
    private let base: any ExtractionJournalStore

    init(base: any ExtractionJournalStore) {
        self.base = base
    }

    func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation {
        try await base.register(transaction: transaction, namespace: namespace)
    }

    func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity {
        try await base.createTransactionRoot(reservation)
    }

    func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction {
        throw ExtractionTransactionTestError.unexpectedCall("activate")
    }

    func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws {
        try await base.relinquishPreparation(reservation)
    }

    func markRolledBack(_ transactionID: TransactionID) async throws {
        try await base.markRolledBack(transactionID)
    }

    func releaseRolledBack(_ transactionID: TransactionID) async throws {
        try await base.releaseRolledBack(transactionID)
    }

    func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws {
        try await base.markCommitted(transactionID: transactionID, result: result)
    }
}


private actor CollisionCountingJournal: ExtractionJournalStore {
    private let base: any ExtractionJournalStore
    private(set) var appendCount = 0

    init(base: any ExtractionJournalStore) {
        self.base = base
    }

    func register(
        transaction: ExtractionJournalHeader,
        namespace: TransactionNamespaceLocator
    ) async throws -> TransactionRootReservation {
        try await base.register(transaction: transaction, namespace: namespace)
    }

    func createTransactionRoot(
        _ reservation: TransactionRootReservation
    ) async throws -> FileNodeIdentity {
        try await base.createTransactionRoot(reservation)
    }

    func activate(
        _ reservation: TransactionRootReservation
    ) async throws -> ActivatedExtractionTransaction {
        try await base.activate(reservation)
    }

    func relinquishPreparation(
        _ reservation: TransactionRootReservation
    ) async throws {
        try await base.relinquishPreparation(reservation)
    }

    func armReplaceSwap(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        replacementIdentity: FileNodeIdentity,
        expectedCaptured: CapturedTreeManifest,
        transactionID: TransactionID
    ) async throws {
        appendCount += 1
        try await base.armReplaceSwap(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            replacementIdentity: replacementIdentity,
            expectedCaptured: expectedCaptured,
            transactionID: transactionID
        )
    }

    func armPublishMove(
        mutationID: JournalMutationID,
        staged: JournalNodeReference,
        destination: JournalNodeReference,
        publishedIdentity: FileNodeIdentity,
        transactionID: TransactionID
    ) async throws {
        appendCount += 1
        try await base.armPublishMove(
            mutationID: mutationID,
            staged: staged,
            destination: destination,
            publishedIdentity: publishedIdentity,
            transactionID: transactionID
        )
    }

    func recordsForRecovery(
        _ transactionID: TransactionID
    ) async throws -> [RecoveryJournalMutation] {
        try await base.recordsForRecovery(transactionID)
    }

    func markRolledBack(_ transactionID: TransactionID) async throws {
        try await base.markRolledBack(transactionID)
    }

    func releaseRolledBack(_ transactionID: TransactionID) async throws {
        try await base.releaseRolledBack(transactionID)
    }

    func markCommitted(
        transactionID: TransactionID,
        result: ExtractionResult
    ) async throws {
        try await base.markCommitted(transactionID: transactionID, result: result)
    }
}

private actor RecordingPreparationAborter: ExtractionPreparationAborting {
    private let base: any ExtractionPreparationAborting
    private let events: TransactionEventLog?
    private(set) var transactionIDs: [TransactionID] = []

    init(
        base: any ExtractionPreparationAborting,
        events: TransactionEventLog? = nil
    ) {
        self.base = base
        self.events = events
    }

    func abortPreparation(transactionID: TransactionID) async throws {
        transactionIDs.append(transactionID)
        events?.append("abortPreparation")
        try await base.abortPreparation(transactionID: transactionID)
    }
}

private struct RejectingTransactionNamespaceProvider: TransactionNamespaceProviding {
    func namespace(
        forDestinationIdentity destinationIdentity: FileNodeIdentity
    ) async throws -> TransactionNamespaceLocator {
        throw TransactionJournalError.unavailableDestinationVolume(destinationIdentity.device)
    }
}

private struct TransactionExecutionFixture {
    let task5: Task5TestSupport.Fixture
    let archive: ArchiveLocator
    let request: ExtractionRequest

    func remove() {
        task5.indexDirectory.close()
        try? FileManager.default.removeItem(at: task5.root)
    }
}

private extension TransactionExecutionFixture {
    func preflightRequest(
        policy: OperationConflictPolicy,
        selectedEntries: [String]? = nil
    ) -> ExtractionPreflightRequest {
        ExtractionPreflightRequest(
            operationID: request.operationID,
            sessionID: request.sessionID,
            archive: archive,
            destination: task5.destinationURL,
            selectedEntries: selectedEntries ?? request.selectedEntries,
            conflictPolicy: policy,
            preserveTimestamps: request.preserveTimestamps,
            resourcePolicy: request.resourcePolicy,
            ui: request.ui
        )
    }

    func makeRequest(
        conflictPolicy: OperationConflictPolicy? = nil,
        selectedEntries: [String]? = nil,
        expectedArchiveRevision: ArchiveRevision,
        expectedDestinationIdentity: ExtractionDestinationIdentity,
        planDigest: ExtractionPlanDigest,
        publicationBinding: [ExtractionPublicationBindingEntry],
        replacementApproval: DestructiveReplacementApproval?
    ) -> ExtractionRequest {
        ExtractionRequest(
            operationID: request.operationID,
            sessionID: request.sessionID,
            archive: archive,
            destination: task5.destinationURL,
            selectedEntries: selectedEntries ?? request.selectedEntries,
            conflictPolicy: conflictPolicy ?? request.conflictPolicy,
            preserveTimestamps: request.preserveTimestamps,
            resourcePolicy: request.resourcePolicy,
            ui: request.ui,
            expectedArchiveRevision: expectedArchiveRevision,
            expectedDestinationIdentity: expectedDestinationIdentity,
            planDigest: planDigest,
            publicationBinding: publicationBinding,
            replacementApproval: replacementApproval
        )
    }

    func approvedRequest(
        transaction: ExtractionTransaction,
        policy: OperationConflictPolicy,
        selectedEntries: [String]? = nil
    ) async throws -> ExtractionRequest {
        let preflight = try await transaction.preflight(
            preflightRequest(
                policy: policy,
                selectedEntries: selectedEntries
            ),
            password: nil
        )
        return makeRequest(
            conflictPolicy: policy,
            selectedEntries: selectedEntries,
            expectedArchiveRevision: preflight.archiveRevision,
            expectedDestinationIdentity: preflight.destinationIdentity,
            planDigest: preflight.planDigest,
            publicationBinding: preflight.publicationBinding,
            replacementApproval: preflight.requiresDestructiveReplacementApproval
                ? preflight.makeDestructiveReplacementApproval()
                : nil
        )
    }
}

private func makeTransactionExecutionFixture(
    _ test: XCTestCase,
    conflictPolicy: OperationConflictPolicy = .fail,
    preserveTimestamps: Bool = true,
    resourcePolicy: ArchiveResourcePolicy = .production
) async throws -> TransactionExecutionFixture {
    let task5 = try await Task5TestSupport.makeFixture(test)
    let archiveURL = task5.root.appendingPathComponent("archive.zip")
    try Data("archive".utf8).write(to: archiveURL)
    let archive = try ArchiveIdentityResolver().resolve(archiveURL).locator
    let request = ExtractionRequest(
        operationID: OperationID(),
        sessionID: ArchiveSessionID(),
        archive: archive,
        destination: task5.destinationURL,
        selectedEntries: [],
        conflictPolicy: conflictPolicy,
        preserveTimestamps: preserveTimestamps,
        resourcePolicy: resourcePolicy,
        ui: .init(title: "Transaction")
    )
    return TransactionExecutionFixture(task5: task5, archive: archive, request: request)
}


private func makeTransaction(
    fixture: TransactionExecutionFixture,
    backend: any ArchiveExtractionBackend,
    journal: (any ExtractionJournalStore)? = nil,
    quarantine: any PublicationQuarantining = NoopQuarantine(),
    fileSystem: (any FileSystemOperations)? = nil,
    archiveSourceBindingBeforeReleaseObserver: (@Sendable (URL) throws -> Void)? = nil,
    replaceSwapSyncCompletionBeforeCommit: (@Sendable (
        ReplaceSwapSyncCompletion
    ) -> ReplaceSwapSyncCompletion)? = nil
) -> ExtractionTransaction {
    let selectedFileSystem = fileSystem ?? fixture.task5.fileSystem
    return ExtractionTransaction(
        backend: backend,
        journal: journal ?? fixture.task5.store,
        preparationAborter: ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: selectedFileSystem
        ),
        namespaceProvider: fixture.task5.provider,
        fileSystem: selectedFileSystem,
        stateResolver: ExtractionStateResolver(
            archiveIdentityResolver: ArchiveIdentityResolver(),
            fileSystem: selectedFileSystem
        ),
        quarantine: quarantine,
        archiveSourceBindingBeforeReleaseObserver: archiveSourceBindingBeforeReleaseObserver,
        replaceSwapSyncCompletionBeforeCommit: replaceSwapSyncCompletionBeforeCommit
    )
}

private func replaceLiveStagingRoot(
    namespace: URL,
    detached: URL
) throws -> URL {
    guard let enumerator = FileManager.default.enumerator(
        at: namespace,
        includingPropertiesForKeys: nil
    ), let staging = enumerator.compactMap({ $0 as? URL }).first(where: {
        $0.lastPathComponent == "staging"
            && $0.deletingLastPathComponent().lastPathComponent.hasPrefix("transaction-")
    }) else {
        throw ExtractionTransactionTestError.unexpectedCall("live staging root")
    }
    try FileManager.default.moveItem(at: staging, to: detached)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    return staging
}


private func makeExtractionDescriptor(
    fixture: TransactionExecutionFixture
) -> OperationDescriptor {
    OperationDescriptor(
        operationID: fixture.request.operationID,
        archiveID: fixture.request.archive.archiveID,
        sessionID: fixture.request.sessionID,
        payload: .extract(.init(
            archive: .init(
                identity: fixture.request.archive.archiveID.identity,
                url: fixture.request.archive.url
            ),
            destination: .init(
                identity: nil,
                url: fixture.request.destination
            ),
            selectedEntryPaths: fixture.request.selectedEntries,
            conflictPolicy: fixture.request.conflictPolicy,
            preserveTimestamps: fixture.request.preserveTimestamps
        )),
        resourcePolicy: fixture.request.resourcePolicy,
        ui: fixture.request.ui
    )
}

private func inventory(
    _ entries: [ExtractionInventoryEntry]
) -> ExtractionInventory {
    ExtractionInventory(
        entries: entries,
        implicitDirectories: [],
        advertisedOutputByteCount: 0,
        advertisedDictionaryByteCount: 0
    )
}

private func fileEntry(_ path: String) -> ExtractionInventoryEntry {
    ExtractionInventoryEntry(
        path: path,
        kind: .regularFile,
        size: 1,
        linkTarget: nil,
        isExplicitDirectory: false
    )
}


private func symbolicLinkEntry(
    _ path: String,
    target: String
) -> ExtractionInventoryEntry {
    ExtractionInventoryEntry(
        path: path,
        kind: .symbolicLink,
        size: 0,
        linkTarget: target,
        isExplicitDirectory: false
    )
}

private func directoryEntry(
    _ path: String,
    explicit: Bool = true,
    mode: UInt16? = nil
) -> ExtractionInventoryEntry {
    ExtractionInventoryEntry(
        path: path,
        kind: .directory,
        size: 0,
        linkTarget: nil,
        isExplicitDirectory: explicit,
        posixMode: mode
    )
}

/// The mode of `url` without following symlinks, or nil if it cannot be read.
private func nodeMode(_ url: URL) -> UInt16? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return nil }
    return UInt16(metadata.st_mode & 0o7777)
}

/// The mode a directory gets when the archive recorded none.
///
/// This is a fixed 0755 rather than `0755 & ~umask`: modes the archive *did*
/// record are honoured exactly, so letting the process umask reduce only the
/// mode-less ones would be inconsistent (and would make this test's expectation
/// depend on ambient process state).
private let defaultPublishedDirectoryMode: UInt16 = 0o755

private func pathLess(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: "/").map(String.init)
    let right = rhs.split(separator: "/").map(String.init)
    for (l, r) in zip(left, right) where l != r {
        return l.utf8.lexicographicallyPrecedes(r.utf8)
    }
    return left.count < right.count
}

private actor CancellingExtractionHandler: ArchiveExtractionHandling {
    enum Behavior: Sendable {
        case committed(ArchiveExtractionExecution)
        case rollbackFailed(URL)
        case cancelled
    }

    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func preflight(
        request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight {
        throw ExtractionTransactionTestError.unexpectedCall("preflight")
    }

    func prepare(
        descriptor: OperationDescriptor
    ) async throws -> ArchiveExtractionPreparation {
        .fresh
    }

    func executeFresh(
        payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ArchiveExtractionExecution {
        withUnsafeCurrentTask { task in task?.cancel() }
        switch behavior {
        case let .committed(execution):
            return execution
        case let .rollbackFailed(url):
            // A stub standing in for a failure the runtime would normally
            // describe, so it carries no cause of its own.
            throw ArchiveFailure.rollbackFailed(recoveryURL: url, cause: nil)
        case .cancelled:
            throw CancellationError()
        }
    }
}

private actor ProgressRecorder {
    private(set) var values: [ArchiveProgress] = []

    func record(_ value: ArchiveProgress) {
        values.append(value)
    }
}

private actor PostTerminalProbe {
    private var checker: (@Sendable () async -> Bool)?
    private(set) var observedTerminalState = false
    private(set) var attempts = 0
    private let injectedError: Error?

    init(injectedError: Error? = nil) {
        self.injectedError = injectedError
    }

    func setChecker(_ checker: @escaping @Sendable () async -> Bool) {
        self.checker = checker
    }

    func run() async throws {
        attempts += 1
        observedTerminalState = await checker?() ?? false
        if let injectedError { throw injectedError }
    }
}

private actor ProbingCommittedFinalizer: CommittedExtractionFinalizing {
    private let base: any CommittedExtractionFinalizing
    private let probe: PostTerminalProbe

    init(base: any CommittedExtractionFinalizing, probe: PostTerminalProbe) {
        self.base = base
        self.probe = probe
    }

    func finalizeCommittedExtraction(operationID: OperationID) async throws {
        try await probe.run()
        try await base.finalizeCommittedExtraction(operationID: operationID)
    }
}

private struct OperationBoundaryObserver: FileSystemOperationObserving, Sendable {
    let callback: @Sendable (FileSystemOperationBoundary, String) throws -> Void

    init(
        _ callback: @escaping @Sendable (FileSystemOperationBoundary, String) throws -> Void
    ) {
        self.callback = callback
    }

    func didReach(_ boundary: FileSystemOperationBoundary, component: String) throws {
        try callback(boundary, component)
    }
}

private final class RecoveryRemovalRecorder: FileSystemOperationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var removedComponents: [String] = []

    func didReach(_ boundary: FileSystemOperationBoundary, component: String) throws {
        guard boundary == .afterOwnedDirectRemoval else { return }
        lock.withLock { removedComponents.append(component) }
    }

    func removals() -> [String] {
        lock.withLock { removedComponents }
    }
}

private struct NoFollowManifestQuarantine: PublicationQuarantining, Sendable {
    static let key = "com.xzip.tests.quarantine"
    static let value = Data("xzip-quarantine".utf8)

    let beforeEntry: @Sendable (QuarantineManifestEntry, URL) throws -> Void

    init(
        beforeEntry: @escaping @Sendable (QuarantineManifestEntry, URL) throws -> Void = { _, _ in }
    ) {
        self.beforeEntry = beforeEntry
    }

    func apply(
        to entries: [QuarantineManifestEntry],
        stagingRoot: URL,
        stagingRootIdentity: FileNodeIdentity,
        fileSystem: any FileSystemOperations
    ) throws {
        let root = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: stagingRoot,
            expected: stagingRootIdentity
        )
        defer { root.close() }

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            try beforeEntry(entry, stagingRoot)
            let parent = try fileSystem.openRelativeDirectoryNoFollow(
                root: root,
                components: Array(components.dropLast()),
                expected: nil
            )
            defer { parent.close() }

            if entry.kind == .directory {
                let directory = try fileSystem.openDirectoryNoFollow(
                    parent: parent,
                    name: name,
                    expected: entry.identity
                )
                defer { directory.close() }
                try fileSystem.setExtendedAttribute(
                    on: directory,
                    expected: entry.identity,
                    key: Self.key,
                    value: Self.value
                )
            } else {
                try fileSystem.setExtendedAttributeNoFollow(
                    parent: parent,
                    name: name,
                    expected: entry.identity,
                    key: Self.key,
                    value: Self.value
                )
            }
        }
    }
}


private final class BooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock { storage = true }
    }
}

private final class CapturedSlotReplacementProbe: @unchecked Sendable {
    private let namespace: URL
    private let detached: URL
    private let lock = NSLock()
    private var didReplace = false
    private var storedError: Error?

    init(namespace: URL, detached: URL) {
        self.namespace = namespace
        self.detached = detached
    }

    var error: Error? {
        lock.withLock { storedError }
    }

    func replaceCapturedNode() {
        let shouldReplace = lock.withLock {
            guard !didReplace else { return false }
            didReplace = true
            return true
        }
        guard shouldReplace else { return }
        do {
            guard let enumerator = FileManager.default.enumerator(
                at: namespace,
                includingPropertiesForKeys: nil
            ), let staging = enumerator.compactMap({ $0 as? URL }).first(where: {
                $0.lastPathComponent == "staging"
            }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let captured = staging.appendingPathComponent("file.txt")
            try FileManager.default.moveItem(at: captured, to: detached)
            try Data("foreign".utf8).write(to: captured, options: .withoutOverwriting)
        } catch {
            lock.withLock { storedError = error }
        }
    }
}

private final class OneShotMoveFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private var consumed = false

    init(name: String) {
        self.name = name
    }

    func consumeIfMatches(_ candidate: String) -> Bool {
        lock.withLock {
            guard !consumed, candidate == name else { return false }
            consumed = true
            return true
        }
    }
}

private final class SecondRenameFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func call(
        sourceFD: Int32,
        source: String,
        destinationFD: Int32,
        destination: String
    ) -> Int32 {
        lock.withLock {
            callCount += 1
            guard callCount != 2 else {
                errno = EIO
                return -1
            }
            return renameatx_np(
                sourceFD,
                source,
                destinationFD,
                destination,
                UInt32(RENAME_EXCL)
            )
        }
    }
}

private enum ExtractionTransactionTestBoundary: Sendable {
    case afterReplaceArmed
    case beforeReplaceSwap
    case afterReplaceSwap
    case afterCapturedValidation
    case afterReplaceSourceParentSync
    case afterReplaceDestinationParentSync
    case afterAppliedRegistration
    case afterDurableCommit
}

private final class ExtractionTransactionBoundaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ExtractionTransactionTestBoundary) throws -> Void
    private var replaceSwapCompleted = false
    private var replaceParentSyncCount = 0

    init(
        handler: @escaping @Sendable (ExtractionTransactionTestBoundary) throws -> Void
    ) {
        self.handler = handler
    }

    func reach(_ boundary: ExtractionTransactionTestBoundary) throws {
        try handler(boundary)
    }

    func didCompleteReplaceSwap() throws {
        lock.withLock {
            replaceSwapCompleted = true
            replaceParentSyncCount = 0
        }
        try reach(.afterReplaceSwap)
    }

    func didFsync() throws {
        let boundary: ExtractionTransactionTestBoundary? = lock.withLock {
            guard replaceSwapCompleted else { return nil }
            replaceParentSyncCount += 1
            switch replaceParentSyncCount {
            case 1:
                return .afterReplaceSourceParentSync
            case 2:
                replaceSwapCompleted = false
                return .afterReplaceDestinationParentSync
            default:
                return nil
            }
        }
        if let boundary { try reach(boundary) }
    }
}

private final class ExchangeRenameProbe: @unchecked Sendable {
    typealias Hook = @Sendable (
        _ leftFD: Int32,
        _ leftName: String,
        _ rightFD: Int32,
        _ rightName: String,
        _ call: Int
    ) throws -> Void

    private let lock = NSLock()
    private let beforeExchange: Hook?
    private let afterExchange: Hook?
    private var calls = 0
    private var bothNodesPresentValues: [Bool] = []

    init(beforeExchange: Hook? = nil, afterExchange: Hook? = nil) {
        self.beforeExchange = beforeExchange
        self.afterExchange = afterExchange
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }

    func bothNodesPresent() -> [Bool] {
        lock.withLock { bothNodesPresentValues }
    }

    func call(
        leftFD: Int32,
        leftName: String,
        rightFD: Int32,
        rightName: String
    ) -> Int32 {
        let call = lock.withLock { () -> Int in
            calls += 1
            var left = stat()
            var right = stat()
            bothNodesPresentValues.append(
                fstatat(leftFD, leftName, &left, AT_SYMLINK_NOFOLLOW) == 0
                    && fstatat(rightFD, rightName, &right, AT_SYMLINK_NOFOLLOW) == 0
            )
            return calls
        }
        do {
            try beforeExchange?(leftFD, leftName, rightFD, rightName, call)
            let result = renameatx_np(
                leftFD,
                leftName,
                rightFD,
                rightName,
                UInt32(RENAME_SWAP)
            )
            guard result == 0 else { return result }
            try afterExchange?(leftFD, leftName, rightFD, rightName, call)
            return 0
        } catch {
            errno = EIO
            return -1
        }
    }
}

private struct DestinationEnumerationRejectingFileSystem: FileSystemOperations, Sendable {
    let base: any FileSystemOperations
    let destinationIdentity: FileNodeIdentity
    let rejectDestinationEnumeration: Bool
    let moveFailure: OneShotMoveFailure?
    let identityMismatchMoveFailure: OneShotMoveFailure?
    let beforeForwardingMove:
        (@Sendable (_ fromName: String, _ toName: String) throws -> Void)?
    let afterSuccessfulMove: (@Sendable (String) -> Void)?
    let afterDirectoryModeSet: (@Sendable () -> Void)?
    let beforeFsync: (@Sendable () throws -> Void)?
    let boundaryProbe: ExtractionTransactionBoundaryProbe?

    init(
        base: any FileSystemOperations,
        destinationIdentity: FileNodeIdentity,
        rejectDestinationEnumeration: Bool = true,
        failFirstMoveToName: String? = nil,
        failFirstMoveWithIdentityMismatchToName: String? = nil,
        beforeForwardingMove:
            (@Sendable (_ fromName: String, _ toName: String) throws -> Void)? = nil,
        afterSuccessfulMove: (@Sendable (String) -> Void)? = nil,
        afterDirectoryModeSet: (@Sendable () -> Void)? = nil,
        beforeFsync: (@Sendable () throws -> Void)? = nil,
        boundaryProbe: ExtractionTransactionBoundaryProbe? = nil
    ) {
        self.base = base
        self.destinationIdentity = destinationIdentity
        self.rejectDestinationEnumeration = rejectDestinationEnumeration
        self.moveFailure = failFirstMoveToName.map(OneShotMoveFailure.init)
        self.identityMismatchMoveFailure =
            failFirstMoveWithIdentityMismatchToName.map(OneShotMoveFailure.init)
        self.beforeForwardingMove = beforeForwardingMove
        self.afterSuccessfulMove = afterSuccessfulMove
        self.afterDirectoryModeSet = afterDirectoryModeSet
        self.beforeFsync = beforeFsync
        self.boundaryProbe = boundaryProbe
    }

    func openDirectoryNoFollow(at url: URL) throws -> DirectoryHandle {
        try base.openDirectoryNoFollow(at: url)
    }

    func openDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try base.openDirectoryNoFollow(parent: parent, name: name, expected: expected)
    }

    func openRelativeDirectoryNoFollow(
        root: DirectoryHandle,
        components: [String],
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try base.openRelativeDirectoryNoFollow(
            root: root,
            components: components,
            expected: expected
        )
    }

    func openTransactionOwnedDirectoryNoFollow(
        at url: URL,
        expected: FileNodeIdentity
    ) throws -> DirectoryHandle {
        try base.openTransactionOwnedDirectoryNoFollow(at: url, expected: expected)
    }

    func openTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try base.openTransactionOwnedDirectoryNoFollow(
            parent: parent,
            name: name,
            expected: expected
        )
    }

    func adoptTransactionOwnedDirectoryNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?
    ) throws -> DirectoryHandle {
        try base.adoptTransactionOwnedDirectoryNoFollow(
            parent: parent,
            name: name,
            expected: expected
        )
    }

    func setTransactionOwnedDirectoryMode(
        _ directory: DirectoryHandle,
        mode: UInt16
    ) throws {
        try base.setTransactionOwnedDirectoryMode(directory, mode: mode)
        afterDirectoryModeSet?()
    }

    func identity(of directory: DirectoryHandle) throws -> FileNodeIdentity {
        try base.identity(of: directory)
    }

    func statNoFollow(parent: DirectoryHandle, name: String) throws -> FileNode? {
        try base.statNoFollow(parent: parent, name: name)
    }

    func listNoFollow(_ directory: DirectoryHandle) throws -> [FileNode] {
        if rejectDestinationEnumeration,
           try base.identity(of: directory) == destinationIdentity
        {
            throw ExtractionTransactionTestError.unexpectedCall("destination enumeration")
        }
        return try base.listNoFollow(directory)
    }

    func forEachNodeNoFollow(
        _ directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws {
        if rejectDestinationEnumeration,
           try base.identity(of: directory) == destinationIdentity
        {
            throw ExtractionTransactionTestError.unexpectedCall("destination enumeration")
        }
        try base.forEachNodeNoFollow(directory, body)
    }

    func createDirectoryExclusive(parent: DirectoryHandle, name: String) throws -> FileNodeIdentity {
        try base.createDirectoryExclusive(parent: parent, name: name)
    }

    func createTransactionDirectoryExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DirectoryHandle {
        try base.createTransactionDirectoryExclusive(parent: parent, name: name)
    }

    func createRegularFileExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> DurableFileHandle {
        try base.createRegularFileExclusive(parent: parent, name: name)
    }

    func openRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity?,
        access: DurableFileAccess
    ) throws -> DurableFileHandle {
        try base.openRegularFileNoFollow(
            parent: parent,
            name: name,
            expected: expected,
            access: access
        )
    }

    func replaceRegularFileAtomically(
        parent: DirectoryHandle,
        temporaryName: String,
        destinationName: String,
        expectedTemporary: FileNodeIdentity
    ) throws {
        try base.replaceRegularFileAtomically(
            parent: parent,
            temporaryName: temporaryName,
            destinationName: destinationName,
            expectedTemporary: expectedTemporary
        )
    }

    func fsyncRegularFileNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity
    ) throws {
        try base.fsyncRegularFileNoFollow(parent: parent, name: name, expected: expected)
    }

    func renameExclusive(
        fromParent: DirectoryHandle,
        fromName: String,
        toParent: DirectoryHandle,
        toName: String
    ) throws {
        try base.renameExclusive(
            fromParent: fromParent,
            fromName: fromName,
            toParent: toParent,
            toName: toName
        )
    }

    func moveExclusiveObserved(
        fromParent: DirectoryHandle,
        fromName: String,
        toParent: DirectoryHandle,
        toName: String,
        expectedSource: FileNodeIdentity
    ) throws -> MoveObservation {
        try beforeForwardingMove?(fromName, toName)
        if try base.identity(of: toParent) == destinationIdentity {
            if identityMismatchMoveFailure?.consumeIfMatches(toName) == true {
                throw FileSystemOperationError.identityMismatch(
                    expected: expectedSource,
                    actual: nil
                )
            }
            if moveFailure?.consumeIfMatches(toName) == true {
                throw ExtractionTransactionTestError.unexpectedCall(
                    "injected move failure: \(toName)"
                )
            }
        }
        let observation = try base.moveExclusiveObserved(
            fromParent: fromParent,
            fromName: fromName,
            toParent: toParent,
            toName: toName,
            expectedSource: expectedSource
        )
        afterSuccessfulMove?(toName)
        return observation
    }

    func swapObserved(
        leftParent: DirectoryHandle,
        leftName: String,
        expectedLeft: FileNodeIdentity,
        rightParent: DirectoryHandle,
        rightName: String,
        expectedRight: FileNodeIdentity
    ) throws -> SwapObservation {
        try boundaryProbe?.reach(.beforeReplaceSwap)
        let observation = try base.swapObserved(
            leftParent: leftParent,
            leftName: leftName,
            expectedLeft: expectedLeft,
            rightParent: rightParent,
            rightName: rightName,
            expectedRight: expectedRight
        )
        try boundaryProbe?.didCompleteReplaceSwap()
        return observation
    }

    func removeOwnedNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity
    ) throws {
        try base.removeOwnedNoFollow(parent: parent, name: name, expected: expected)
    }

    func setExtendedAttributeNoFollow(
        parent: DirectoryHandle,
        name: String,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws {
        try base.setExtendedAttributeNoFollow(
            parent: parent,
            name: name,
            expected: expected,
            key: key,
            value: value
        )
    }

    func setExtendedAttribute(
        on directory: DirectoryHandle,
        expected: FileNodeIdentity,
        key: String,
        value: Data
    ) throws {
        try base.setExtendedAttribute(
            on: directory,
            expected: expected,
            key: key,
            value: value
        )
    }

    func fsync(_ directory: DirectoryHandle) throws {
        try beforeFsync?()
        try base.fsync(directory)
        try boundaryProbe?.didFsync()
    }
}

private func freshTransactionStore(
    _ fixture: Task5TestSupport.Fixture,
    fileSystem: (any FileSystemOperations)? = nil
) -> TransactionJournalStore {
    TransactionJournalStore(
        indexDirectory: fixture.indexDirectory,
        indexFileName: "extraction-index.json",
        policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
        fileSystem: fileSystem ?? fixture.fileSystem
    )
}

private func extendedAttribute(
    at url: URL,
    key: String,
    noFollow: Bool
) throws -> Data? {
    let options = noFollow ? XATTR_NOFOLLOW : 0
    let size = getxattr(url.path, key, nil, 0, 0, options)
    if size < 0 {
        if errno == ENOATTR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { bytes in
        getxattr(url.path, key, bytes.baseAddress, bytes.count, 0, options)
    }
    guard read == size else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return data
}

private func setExtendedAttribute(
    at url: URL,
    key: String,
    value: Data,
    noFollow: Bool
) throws {
    let options = noFollow ? XATTR_NOFOLLOW : 0
    let result = value.withUnsafeBytes { bytes in
        setxattr(url.path, key, bytes.baseAddress, bytes.count, 0, options)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

final class ExtractionTransactionTests: XCTestCase {
    func testReplaceConflictWithoutApprovalFailsBeforeStagingOrJournal() async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: false
        )
        try Data("old".utf8).write(
            to: existing.appendingPathComponent("old.txt")
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/new.txt")
            ])
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(
                fixture.request,
                password: nil
            ) { _ in }
        }

        XCTAssertTrue(backend.observations().stagingPasswords.isEmpty)
        let registeredHeaders = await journal.registeredHeaders
        XCTAssertTrue(registeredHeaders.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent("old.txt")),
            Data("old".utf8)
        )
    }

    func testLegacyNonDestructiveRequestBuildsBoundPlanBeforeStaging() async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .fail
        )
        defer { fixture.remove() }
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("new.txt")])
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend
        )

        _ = try await transaction.execute(
            fixture.request,
            password: nil
        ) { _ in }

        XCTAssertEqual(
            backend.observations().stagingPasswords.count,
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL
                    .appendingPathComponent("new.txt")
                    .path
            )
        )
    }

    func testLateChildInvalidatesApprovedReplaceBeforeStaging() async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/new.txt")
            ])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let preflight = try await transaction.preflight(
            fixture.preflightRequest(policy: .replace),
            password: nil
        )

        let late = existing.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: late)
        let request = fixture.makeRequest(
            expectedArchiveRevision: preflight.archiveRevision,
            expectedDestinationIdentity: preflight.destinationIdentity,
            planDigest: preflight.planDigest,
            publicationBinding: preflight.publicationBinding,
            replacementApproval: preflight.makeDestructiveReplacementApproval()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertTrue(backend.observations().stagingPasswords.isEmpty)
        XCTAssertEqual(try Data(contentsOf: late), Data("late".utf8))
    }

    func testLateChildDuringStagingInvalidatesApprovedReplaceBeforePublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        defer { fixture.remove() }
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: false
        )
        let late = existing.appendingPathComponent("new.txt")
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/new.txt")
            ]),
            progressValues: [.indeterminate]
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let preflight = try await transaction.preflight(
            fixture.preflightRequest(policy: .replace),
            password: nil
        )
        let request = fixture.makeRequest(
            expectedArchiveRevision: preflight.archiveRevision,
            expectedDestinationIdentity: preflight.destinationIdentity,
            planDigest: preflight.planDigest,
            publicationBinding: preflight.publicationBinding,
            replacementApproval: preflight.makeDestructiveReplacementApproval()
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in
                try! Data("late".utf8).write(to: late)
            }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(backend.observations().stagingPasswords.count, 1)
        XCTAssertEqual(try Data(contentsOf: late), Data("late".utf8))
    }

    func testLateChildDuringQuarantineInvalidatesApprovedReplaceBeforePublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        defer { fixture.remove() }
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: false
        )
        let late = existing.appendingPathComponent("new.txt")
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/new.txt")
            ])
        )
        let quarantine = RecordingPublicationQuarantine(onApply: {
            try Data("late".utf8).write(to: late)
        })
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            quarantine: quarantine
        )
        let preflight = try await transaction.preflight(
            fixture.preflightRequest(policy: .replace),
            password: nil
        )
        let request = fixture.makeRequest(
            expectedArchiveRevision: preflight.archiveRevision,
            expectedDestinationIdentity: preflight.destinationIdentity,
            planDigest: preflight.planDigest,
            publicationBinding: preflight.publicationBinding,
            replacementApproval: preflight.makeDestructiveReplacementApproval()
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(backend.observations().stagingPasswords.count, 1)
        XCTAssertEqual(try Data(contentsOf: late), Data("late".utf8))
    }

    func testLateChildAfterFinalPlanCheckDuringEarlierJournalAppendInvalidatesReplace()
        async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        defer { fixture.remove() }
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: false
        )
        let first = existing.appendingPathComponent("a.txt")
        let late = existing.appendingPathComponent("new.txt")
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/a.txt"),
                fileEntry("folder/new.txt")
            ])
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .replaceSwap(_, _, destination, _, _, _) = mutation,
                      destination.relativeParentPath.isEmpty,
                      destination.name == "folder"
                else { return }
                try Data("late".utf8).write(to: late)
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(try Data(contentsOf: late), Data("late".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testReplaceIdentityDriftDuringSwapJournalAppendFailsAsPlanChanged()
        async throws {
        let fixture = try await makeTransactionExecutionFixture(
            self,
            conflictPolicy: .replace
        )
        defer { fixture.remove() }
        let target = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("approved".utf8).write(to: target)
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .replaceSwap(_, _, destination, _, _, _) = mutation,
                      destination.relativeParentPath.isEmpty,
                      destination.name == "file.txt"
                else { return }
                try FileManager.default.removeItem(at: target)
                try Data("late".utf8).write(to: target)
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(try Data(contentsOf: target), Data("late".utf8))
    }

    func testLateChildAfterFinalPlanCheckInvalidatesEveryNonDestructivePolicy()
        async throws {
        for policy in [
            OperationConflictPolicy.fail,
            .skip,
            .keepBoth
        ] {
            let fixture = try await makeTransactionExecutionFixture(
                self,
                conflictPolicy: policy
            )
            defer { fixture.remove() }
            let existing = fixture.task5.destinationURL
                .appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(
                at: existing,
                withIntermediateDirectories: false
            )
            let first = existing.appendingPathComponent("a.txt")
            let late = existing.appendingPathComponent("new.txt")
            let keepBoth = existing.appendingPathComponent("new_1.txt")
            let backend = StagingExtractionBackend(
                inventory: inventory([
                    directoryEntry("folder"),
                    fileEntry("folder/a.txt"),
                    fileEntry("folder/new.txt")
                ])
            )
            let journal = RecordingExtractionJournal(
                base: fixture.task5.store,
                afterArm: { mutation in
                    guard case let .publishMove(_, _, destination, _) = mutation,
                          destination.relativeParentPath == "folder",
                          destination.name == "a.txt"
                    else { return }
                    try Data("late".utf8).write(to: late)
                }
            )
            let transaction = makeTransaction(
                fixture: fixture,
                backend: backend,
                journal: journal
            )
            let request = try await fixture.approvedRequest(
                transaction: transaction,
                policy: policy
            )

            do {
                _ = try await transaction.execute(request, password: nil) { _ in }
                XCTFail("Expected extractionPlanChanged for \(policy)")
            } catch let error as ArchiveFailure {
                XCTAssertEqual(error, .extractionPlanChanged, "policy: \(policy)")
            }

            XCTAssertEqual(
                try Data(contentsOf: late),
                Data("late".utf8),
                "policy: \(policy)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: first.path),
                "policy: \(policy)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: keepBoth.path),
                "policy: \(policy)"
            )
        }
    }

    func testApprovedNonDestructivePublicationBindingRejectsPreExecutionDrift()
        async throws {
        for policy in [
            OperationConflictPolicy.fail,
            .skip,
            .keepBoth
        ] {
            let fixture = try await makeTransactionExecutionFixture(self)
            defer { fixture.remove() }
            let destinationFile = fixture.task5.destinationURL
                .appendingPathComponent("file.txt")
            try Data("approved".utf8).write(to: destinationFile)
            let backend = StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            )
            let transaction = makeTransaction(
                fixture: fixture,
                backend: backend
            )
            let request = try await fixture.approvedRequest(
                transaction: transaction,
                policy: policy
            )

            let keepBothCandidate = fixture.task5.destinationURL
                .appendingPathComponent("file_1.txt")
            if policy == .keepBoth {
                try Data("late-candidate".utf8).write(to: keepBothCandidate)
            } else {
                try FileManager.default.removeItem(at: destinationFile)
                try Data("late-target".utf8).write(to: destinationFile)
            }

            do {
                _ = try await transaction.execute(request, password: nil) { _ in }
                XCTFail("Expected extractionPlanChanged for \(policy)")
            } catch let error as ArchiveFailure {
                XCTAssertEqual(error, .extractionPlanChanged, "policy: \(policy)")
            }

            XCTAssertEqual(
                try Data(contentsOf: destinationFile),
                Data(policy == .keepBoth ? "approved".utf8 : "late-target".utf8),
                "policy: \(policy)"
            )
            if policy == .keepBoth {
                XCTAssertEqual(
                    try Data(contentsOf: keepBothCandidate),
                    Data("late-candidate".utf8)
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.task5.destinationURL
                        .appendingPathComponent("file_2.txt").path
                ))
            }
        }
    }

    func testDestinationRootSwapDuringPublishJournalAppendInvalidatesPlan()
        async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL
        let detached = fixture.task5.root.appendingPathComponent(
            "detached-destination",
            isDirectory: true
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .publishMove = mutation else { return }
                try FileManager.default.moveItem(at: destination, to: detached)
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("file.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("file.txt").path
        ))
    }

    func testMergeParentSwapDuringPublishJournalAppendInvalidatesPlan()
        async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let folder = fixture.task5.destinationURL.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        let detached = fixture.task5.destinationURL.appendingPathComponent(
            "detached-folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/file.txt")
            ])
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .publishMove = mutation else { return }
                try FileManager.default.moveItem(at: folder, to: detached)
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: false
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("file.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("file.txt").path
        ))
    }

    func testPartialExpectedTupleFailsBeforeInventoryJournalOrStaging() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("new.txt")])
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let revision = ArchiveRevision(
            archiveID: fixture.archive.archiveID,
            fileSize: 0,
            contentModificationDate: .distantPast,
            boundedContentFingerprint: nil
        )
        let destinationIdentity = ExtractionDestinationIdentity(
            parent: .stable(
                volumeIdentifier: 1,
                fileIdentifier: 2,
                generation: 3
            ),
            root: .stable(
                volumeIdentifier: 4,
                fileIdentifier: 5,
                generation: 6
            )
        )
        let digest = ExtractionPlanDigest(bytes: Data([0]))
        let requests = [
            ExtractionRequest(
                operationID: fixture.request.operationID,
                sessionID: fixture.request.sessionID,
                archive: fixture.archive,
                destination: fixture.task5.destinationURL,
                selectedEntries: [],
                conflictPolicy: .fail,
                preserveTimestamps: true,
                resourcePolicy: .production,
                expectedDestinationIdentity: destinationIdentity,
                planDigest: digest
            ),
            ExtractionRequest(
                operationID: fixture.request.operationID,
                sessionID: fixture.request.sessionID,
                archive: fixture.archive,
                destination: fixture.task5.destinationURL,
                selectedEntries: [],
                conflictPolicy: .fail,
                preserveTimestamps: true,
                resourcePolicy: .production,
                expectedArchiveRevision: revision,
                planDigest: digest
            ),
            ExtractionRequest(
                operationID: fixture.request.operationID,
                sessionID: fixture.request.sessionID,
                archive: fixture.archive,
                destination: fixture.task5.destinationURL,
                selectedEntries: [],
                conflictPolicy: .fail,
                preserveTimestamps: true,
                resourcePolicy: .production,
                expectedArchiveRevision: revision,
                expectedDestinationIdentity: destinationIdentity
            )
        ]

        for request in requests {
            do {
                _ = try await transaction.execute(request, password: nil) { _ in }
                XCTFail("Expected extractionPlanChanged")
            } catch let error as ArchiveFailure {
                XCTAssertEqual(error, .extractionPlanChanged)
            }
        }

        XCTAssertTrue(backend.observations().inventoryPasswords.isEmpty)
        XCTAssertTrue(backend.observations().stagingPasswords.isEmpty)
        let registeredHeaders = await journal.registeredHeaders
        XCTAssertTrue(registeredHeaders.isEmpty)
    }

    func testReplacementApprovalRejectsChangedArchiveRevision() async throws {
        let context = try await makeApprovedDirectoryConflict(self)
        defer { context.fixture.remove() }
        try Data("changed-archive".utf8).write(to: context.fixture.archive.url)

        await XCTAssertThrowsErrorAsync {
            _ = try await context.transaction.execute(
                context.request,
                password: nil
            ) { _ in }
        }

        XCTAssertTrue(context.backend.observations().stagingPasswords.isEmpty)
    }

    func testReplacementApprovalRejectsChangedDestinationIdentity() async throws {
        let context = try await makeApprovedDirectoryConflict(self)
        defer { context.fixture.remove() }
        let detached = context.fixture.task5.root
            .appendingPathComponent("detached", isDirectory: true)
        try FileManager.default.moveItem(
            at: context.fixture.task5.destinationURL,
            to: detached
        )
        try FileManager.default.createDirectory(
            at: context.fixture.task5.destinationURL,
            withIntermediateDirectories: false
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await context.transaction.execute(
                context.request,
                password: nil
            ) { _ in }
        }

        XCTAssertTrue(context.backend.observations().stagingPasswords.isEmpty)
    }

    func testReplacementApprovalRejectsDifferentConflictPolicy() async throws {
        let context = try await makeApprovedDirectoryConflict(self)
        defer { context.fixture.remove() }
        let request = context.fixture.makeRequest(
            conflictPolicy: .skip,
            expectedArchiveRevision: context.preflight.archiveRevision,
            expectedDestinationIdentity: context.preflight.destinationIdentity,
            planDigest: context.preflight.planDigest,
            publicationBinding: context.preflight.publicationBinding,
            replacementApproval: context.preflight.makeDestructiveReplacementApproval()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await context.transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertTrue(context.backend.observations().stagingPasswords.isEmpty)
    }

    func testReplacementApprovalRejectsChangedPlanDigest() async throws {
        let context = try await makeApprovedDirectoryConflict(self)
        defer { context.fixture.remove() }
        var changedDigestBytes = context.preflight.planDigest.bytes
        changedDigestBytes.append(0xFF)
        let changedDigest = ExtractionPlanDigest(bytes: changedDigestBytes)
        let request = context.fixture.makeRequest(
            expectedArchiveRevision: context.preflight.archiveRevision,
            expectedDestinationIdentity: context.preflight.destinationIdentity,
            planDigest: changedDigest,
            publicationBinding: context.preflight.publicationBinding,
            replacementApproval: context.preflight.makeDestructiveReplacementApproval()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await context.transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertTrue(context.backend.observations().stagingPasswords.isEmpty)
    }

    func testReplacementApprovalRejectsDifferentPublicationBindingWithSamePlanDigest()
        async throws
    {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let replaceFile = fixture.task5.destinationURL
            .appendingPathComponent("replace.txt")
        try Data("old".utf8).write(to: replaceFile)
        let mergeContainer = fixture.task5.destinationURL
            .appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mergeContainer,
            withIntermediateDirectories: false
        )
        let mergeDirectory = mergeContainer
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mergeDirectory,
            withIntermediateDirectories: false
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([
                fileEntry("replace.txt"),
                fileEntry("container/folder/new.txt")
            ])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let selectedEntries = ["replace.txt", "container/folder/new.txt"]
        let firstPreflight = try await transaction.preflight(
            fixture.preflightRequest(
                policy: .replace,
                selectedEntries: selectedEntries
            ),
            password: nil
        )
        let staleApproval = firstPreflight.makeDestructiveReplacementApproval()

        let detached = fixture.task5.root
            .appendingPathComponent("detached-folder", isDirectory: true)
        try FileManager.default.moveItem(at: mergeDirectory, to: detached)
        try FileManager.default.createDirectory(
            at: mergeDirectory,
            withIntermediateDirectories: false
        )
        let currentPreflight = try await transaction.preflight(
            fixture.preflightRequest(
                policy: .replace,
                selectedEntries: selectedEntries
            ),
            password: nil
        )
        XCTAssertEqual(
            firstPreflight.archiveRevision,
            currentPreflight.archiveRevision
        )
        XCTAssertEqual(
            firstPreflight.destinationIdentity,
            currentPreflight.destinationIdentity
        )
        XCTAssertEqual(firstPreflight.planDigest, currentPreflight.planDigest)
        XCTAssertNotEqual(
            firstPreflight.publicationBinding,
            currentPreflight.publicationBinding
        )
        let executionPreflight = try await transaction.preflight(
            fixture.preflightRequest(
                policy: .replace,
                selectedEntries: selectedEntries
            ),
            password: nil
        )
        XCTAssertEqual(currentPreflight, executionPreflight)
        let request = fixture.makeRequest(
            conflictPolicy: .replace,
            selectedEntries: selectedEntries,
            expectedArchiveRevision: executionPreflight.archiveRevision,
            expectedDestinationIdentity: executionPreflight.destinationIdentity,
            planDigest: executionPreflight.planDigest,
            publicationBinding: executionPreflight.publicationBinding,
            replacementApproval: staleApproval
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        let observations = backend.observations()
        XCTAssertEqual(observations.inventoryPasswords.count, 4)
        XCTAssertTrue(observations.stagingPasswords.isEmpty)
    }

    private func makeApprovedDirectoryConflict(
        _ test: XCTestCase
    ) async throws -> (
        fixture: TransactionExecutionFixture,
        backend: StagingExtractionBackend,
        transaction: ExtractionTransaction,
        preflight: ExtractionPreflight,
        request: ExtractionRequest
    ) {
        let fixture = try await makeTransactionExecutionFixture(test)
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: false
        )
        try Data("old".utf8).write(
            to: existing.appendingPathComponent("old.txt")
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/new.txt")
            ])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let preflight = try await transaction.preflight(
            fixture.preflightRequest(policy: .replace),
            password: nil
        )
        let request = fixture.makeRequest(
            expectedArchiveRevision: preflight.archiveRevision,
            expectedDestinationIdentity: preflight.destinationIdentity,
            planDigest: preflight.planDigest,
            publicationBinding: preflight.publicationBinding,
            replacementApproval: preflight.makeDestructiveReplacementApproval()
        )
        return (fixture, backend, transaction, preflight, request)
    }

    func testExtractionWrapperDelegatesExactlyOneCredentialFreeDescriptor() async throws {
        let recorder = DescriptorRecorder()
        let archiveID = ArchiveID(identity: .stable(
            volumeIdentifier: 1,
            fileIdentifier: 2,
            generation: 3
        ))
        let request = ExtractionRequest(
            operationID: OperationID(),
            sessionID: ArchiveSessionID(),
            archive: ArchiveLocator(
                archiveID: archiveID,
                url: URL(fileURLWithPath: "/tmp/archive.zip")
            ),
            destination: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
            selectedEntries: ["folder/file.txt"],
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production,
            ui: .init(title: "Extract", detail: "One file")
        )

        try await recorder.extract(request)

        let descriptors = await recorder.descriptors
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertFalse(String(describing: descriptors[0]).contains("secret"))
    }

    func testExtractionWrapperPreservesExactOperationSessionPolicyAndUIMetadata() async throws {
        let recorder = DescriptorRecorder()
        let operationID = OperationID()
        let sessionID = ArchiveSessionID()
        let archiveID = ArchiveID(identity: .stable(
            volumeIdentifier: 4,
            fileIdentifier: 5,
            generation: 6
        ))
        let archive = ArchiveLocator(
            archiveID: archiveID,
            url: URL(fileURLWithPath: "/tmp/source.7z")
        )
        let destination = URL(fileURLWithPath: "/tmp/destination", isDirectory: true)
        let destinationIdentity = ExtractionDestinationIdentity(
            parent: .stable(
                volumeIdentifier: 7,
                fileIdentifier: 8,
                generation: 9
            ),
            root: .stable(
                volumeIdentifier: 7,
                fileIdentifier: 10,
                generation: 11
            )
        )
        let revision = ArchiveRevision(
            archiveID: archiveID,
            fileSize: 12,
            contentModificationDate: Date(timeIntervalSince1970: 13),
            boundedContentFingerprint: Data([14])
        )
        let digest = ExtractionPlanDigest(bytes: Data([15]))
        let publicationBinding = [ExtractionPublicationBindingEntry(
            originalPath: "a",
            expectedIdentity: nil,
            decision: .publish
        )]
        let approval = DestructiveReplacementApproval(
            archiveRevision: revision,
            destinationIdentity: destinationIdentity,
            conflictPolicy: .replace,
            planDigest: digest,
            publicationBinding: publicationBinding
        )
        let ui = OperationUIMetadata(title: "Exact", detail: "Metadata")
        let request = ExtractionRequest(
            operationID: operationID,
            sessionID: sessionID,
            archive: archive,
            destination: destination,
            selectedEntries: ["a", "b/c"],
            conflictPolicy: .replace,
            preserveTimestamps: false,
            resourcePolicy: .production,
            ui: ui,
            expectedArchiveRevision: revision,
            expectedDestinationIdentity: destinationIdentity,
            planDigest: digest,
            publicationBinding: publicationBinding,
            replacementApproval: approval
        )

        try await recorder.extract(request)

        let recordedDescriptor = await recorder.descriptors.first
        let descriptor = try XCTUnwrap(recordedDescriptor)
        XCTAssertEqual(descriptor.operationID, operationID)
        XCTAssertEqual(descriptor.sessionID, sessionID)
        XCTAssertEqual(descriptor.archiveID, archiveID)
        XCTAssertEqual(descriptor.resourcePolicy, .production)
        XCTAssertEqual(descriptor.ui, ui)
        guard case let .extract(payload) = descriptor.payload else {
            return XCTFail("Expected extraction payload")
        }
        XCTAssertEqual(payload.archive, .init(identity: archiveID.identity, url: archive.url))
        XCTAssertEqual(payload.destination, .init(identity: nil, url: destination))
        XCTAssertEqual(payload.selectedEntryPaths, ["a", "b/c"])
        XCTAssertEqual(payload.conflictPolicy, .replace)
        XCTAssertFalse(payload.preserveTimestamps)
        XCTAssertEqual(payload.expectedArchiveRevision, revision)
        XCTAssertEqual(payload.expectedDestinationIdentity, destinationIdentity)
        XCTAssertEqual(payload.planDigest, digest)
        XCTAssertEqual(payload.publicationBinding, publicationBinding)
        XCTAssertEqual(payload.replacementApproval, approval)
    }

    func testTransactionalExtractionDispatchUsesInjectedHandler() async throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.remove() }
        let expected = ExtractionResult(
            transactionID: TransactionID(),
            publishedURLs: [fixture.destination.appendingPathComponent("file.txt")],
            skippedPaths: []
        )
        let finalizer = FinalizerRecorder()
        let execution = ArchiveExtractionExecution(
            result: expected,
            postTerminalFinalizer: { await finalizer.record() }
        )
        let handler = HandlerRecorder(
            preparation: .fresh,
            freshExecution: execution
        )
        let backend = LegacyExtractionBackendSpy()
        let runtime = ArchiveRuntime(
            backend: backend,
            identityResolver: ArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in 7 },
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)

        try await runtime.executeOperation(descriptor)

        let preparedCount = await handler.preparedDescriptors.count
        let freshCount = await handler.freshDescriptors.count
        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let finalizerAttempts = await finalizer.attempts
        XCTAssertEqual(preparedCount, 1)
        XCTAssertEqual(freshCount, 1)
        XCTAssertEqual(backend.extractionCallCount(), 0)
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(extractionResult(result), expected)
        XCTAssertEqual(finalizerAttempts, 1)
    }

    func testPublicRuntimeRejectsExtractionBeforeBackendSideEffects() async throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.remove() }
        let backend = LegacyExtractionBackendSpy()
        let runtime = ArchiveRuntime(
            backend: backend,
            identityResolver: ArchiveIdentityResolver()
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)

        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("expected transactional extraction to be required")
        } catch {
            XCTAssertEqual(
                error as? ArchiveRuntimeValidationError,
                .transactionalExtractionRequired
            )
        }

        let state = await runtime.state(for: descriptor.operationID)
        XCTAssertEqual(backend.extractionCallCount(), 0)
        XCTAssertEqual(state, .failed)
    }

    func testNilTransactionalHandlerRejectsReplaceBeforeBackendSideEffects() async throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.remove() }
        let backend = LegacyExtractionBackendSpy()
        let runtime = ArchiveRuntime(
            backend: backend,
            identityResolver: ArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in 8 },
            extractionHandler: nil
        )
        let descriptor = makeExtractionDescriptor(
            fixture: fixture,
            conflictPolicy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            try await runtime.executeOperation(descriptor)
        }

        let state = await runtime.state(for: descriptor.operationID)
        XCTAssertEqual(backend.extractionCallCount(), 0)
        XCTAssertEqual(state, .failed)
    }

    func testCommittedRuntimePreparationBypassesVolumeArchiveDestinationLeaseBackendAndCredentialSeams() async throws {
        let archiveID = ArchiveID(identity: .stable(
            volumeIdentifier: 11,
            fileIdentifier: 12,
            generation: 13
        ))
        let operationID = OperationID()
        let expected = ExtractionResult(
            transactionID: TransactionID(),
            publishedURLs: [URL(fileURLWithPath: "/not-opened/output/file.txt")],
            skippedPaths: ["skipped.txt"]
        )
        let finalizer = FinalizerRecorder()
        let execution = ArchiveExtractionExecution(
            result: expected,
            postTerminalFinalizer: { await finalizer.record() }
        )
        let handler = HandlerRecorder(
            preparation: .committed(execution),
            freshExecution: execution
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = OperationDescriptor(
            operationID: operationID,
            archiveID: archiveID,
            sessionID: ArchiveSessionID(),
            payload: .extract(.init(
                archive: .init(
                    identity: archiveID.identity,
                    url: URL(fileURLWithPath: "/not-opened/archive.zip")
                ),
                destination: .init(
                    identity: nil,
                    url: URL(fileURLWithPath: "/not-opened/output", isDirectory: true)
                ),
                selectedEntryPaths: [],
                conflictPolicy: .replace,
                preserveTimestamps: true
            )),
            resourcePolicy: .production,
            ui: .init(title: "Restart")
        )

        try await runtime.executeOperation(descriptor)

        let preparedCount = await handler.preparedDescriptors.count
        let freshCount = await handler.freshDescriptors.count
        let state = await runtime.state(for: operationID)
        let result = await runtime.result(for: operationID)
        let finalizerAttempts = await finalizer.attempts
        XCTAssertEqual(preparedCount, 1)
        XCTAssertEqual(freshCount, 0)
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(extractionResult(result), expected)
        XCTAssertEqual(finalizerAttempts, 1)
    }


    func testCommittedReplaceRestartFinalizesWithoutRepeatingOrMutatingDestinationEffects() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .replace)
        let destinationFile = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destinationFile)
        let initialTransaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: fixture.task5.store
        )
        let approvedRequest = try await fixture.approvedRequest(
            transaction: initialTransaction,
            policy: .replace
        )
        let expected = try await initialTransaction.execute(
            approvedRequest,
            password: nil
        ) { _ in }
        let committedBytes = try Data(contentsOf: destinationFile)

        let recordingFileSystem = JournalTestFileSystem(base: fixture.task5.fileSystem)
        let restarted = freshTransactionStore(
            fixture.task5,
            fileSystem: recordingFileSystem
        )
        let storedBeforeRecovery = try await restarted.resolveExtraction(
            for: fixture.request.operationID
        )
        XCTAssertEqual(storedBeforeRecovery, .committed(expected))
        let recovery = ExtractionRecoveryCoordinator(
            journals: restarted,
            fileSystem: recordingFileSystem
        )
        try await recovery.recoverLiveTransactions()
        XCTAssertEqual(try Data(contentsOf: destinationFile), committedBytes)
        let storedAfterRecovery = try await restarted.resolveExtraction(
            for: fixture.request.operationID
        )
        XCTAssertEqual(storedAfterRecovery, .committed(expected))
        recordingFileSystem.resetObservations()

        let credentials = CredentialRecorder()
        let selectedTransaction = ExtractionTransaction(
            backend: UnexpectedExtractionBackend(),
            journal: UnexpectedJournal(),
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: UnexpectedNamespaceProvider(),
            fileSystem: DarwinFileSystemOperations(),
            quarantine: NoopQuarantine()
        )
        let probe = PostTerminalProbe()
        let finalizer = ProbingCommittedFinalizer(base: recovery, probe: probe)
        let handler = TransactionalArchiveExtractionHandler(
            transaction: selectedTransaction,
            durableResolver: restarted,
            committedFinalizer: finalizer,
            credentialResolver: credentials
        )
        let legacyBackend = LegacyExtractionBackendSpy()
        let runtime = ArchiveRuntime(
            backend: legacyBackend,
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = OperationDescriptor(
            operationID: fixture.request.operationID,
            archiveID: fixture.request.archive.archiveID,
            sessionID: fixture.request.sessionID,
            payload: .extract(.init(
                archive: .init(
                    identity: fixture.request.archive.archiveID.identity,
                    url: fixture.request.archive.url
                ),
                destination: .init(identity: nil, url: fixture.request.destination),
                selectedEntryPaths: fixture.request.selectedEntries,
                conflictPolicy: fixture.request.conflictPolicy,
                preserveTimestamps: fixture.request.preserveTimestamps
            )),
            resourcePolicy: fixture.request.resourcePolicy,
            ui: fixture.request.ui
        )
        await probe.setChecker {
            let state = await runtime.state(for: descriptor.operationID)
            let result = await runtime.result(for: descriptor.operationID)
            return state == .completed && extractionResult(result) == expected
        }

        try await runtime.executeOperation(descriptor)

        let credentialCalls = await credentials.calls
        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let terminalBeforeFinalizer = await probe.observedTerminalState
        XCTAssertEqual(credentialCalls, 0)
        XCTAssertEqual(legacyBackend.extractionCallCount(), 0)
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(extractionResult(result), expected)
        XCTAssertTrue(terminalBeforeFinalizer)
        XCTAssertFalse(recordingFileSystem.openedDirectoryURLs().contains(fixture.task5.destinationURL))
        XCTAssertFalse(recordingFileSystem.statNames().contains("file.txt"))
        XCTAssertEqual(try Data(contentsOf: destinationFile), committedBytes)
        let finalResolution = try await restarted.resolveExtraction(for: descriptor.operationID)
        XCTAssertEqual(finalResolution, .absent)
    }

    func testCommittedJournalAbsentPostAuthorityRestartFinalizesWithoutDestinationEffects() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .replace)
        let sentinel = fixture.task5.destinationURL.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel)
        let initialTransaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: fixture.task5.store
        )
        let approvedRequest = try await fixture.approvedRequest(
            transaction: initialTransaction,
            policy: .replace
        )
        let expected = try await initialTransaction.execute(
            approvedRequest,
            password: nil
        ) { _ in }
        let published = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let publishedBytes = try Data(contentsOf: published)
        let live = try await fixture.task5.store.liveTransactions()
        let committed = try XCTUnwrap(live.first)
        let rootIdentity = try XCTUnwrap(committed.rootIdentity)
        let rootURL = fixture.task5.namespace.url.appendingPathComponent(
            committed.rootName,
            isDirectory: true
        )
        let root = try fixture.task5.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: rootIdentity
        )
        let journalNode = try XCTUnwrap(fixture.task5.fileSystem.statNoFollow(
            parent: root,
            name: "journal"
        ))
        try fixture.task5.fileSystem.removeOwnedNoFollow(
            parent: root,
            name: "journal",
            expected: journalNode.identity
        )
        try fixture.task5.fileSystem.fsync(root)
        root.close()

        let recordingFileSystem = JournalTestFileSystem(base: fixture.task5.fileSystem)
        let restarted = freshTransactionStore(
            fixture.task5,
            fileSystem: recordingFileSystem
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: restarted,
            fileSystem: recordingFileSystem
        )
        try await recovery.recoverLiveTransactions()
        let storedAfterRecovery = try await restarted.resolveExtraction(
            for: fixture.request.operationID
        )
        XCTAssertEqual(storedAfterRecovery, .committed(expected))
        XCTAssertEqual(try Data(contentsOf: published), publishedBytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        recordingFileSystem.resetObservations()

        let credentials = CredentialRecorder()
        let selectedTransaction = ExtractionTransaction(
            backend: UnexpectedExtractionBackend(),
            journal: UnexpectedJournal(),
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: UnexpectedNamespaceProvider(),
            fileSystem: DarwinFileSystemOperations(),
            quarantine: NoopQuarantine()
        )
        let probe = PostTerminalProbe()
        let finalizer = ProbingCommittedFinalizer(base: recovery, probe: probe)
        let handler = TransactionalArchiveExtractionHandler(
            transaction: selectedTransaction,
            durableResolver: restarted,
            committedFinalizer: finalizer,
            credentialResolver: credentials
        )
        let legacyBackend = LegacyExtractionBackendSpy()
        let runtime = ArchiveRuntime(
            backend: legacyBackend,
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = OperationDescriptor(
            operationID: fixture.request.operationID,
            archiveID: fixture.request.archive.archiveID,
            sessionID: fixture.request.sessionID,
            payload: .extract(.init(
                archive: .init(
                    identity: fixture.request.archive.archiveID.identity,
                    url: fixture.request.archive.url
                ),
                destination: .init(identity: nil, url: fixture.request.destination),
                selectedEntryPaths: fixture.request.selectedEntries,
                conflictPolicy: fixture.request.conflictPolicy,
                preserveTimestamps: fixture.request.preserveTimestamps
            )),
            resourcePolicy: fixture.request.resourcePolicy,
            ui: fixture.request.ui
        )
        await probe.setChecker {
            let state = await runtime.state(for: descriptor.operationID)
            let result = await runtime.result(for: descriptor.operationID)
            return state == .completed && extractionResult(result) == expected
        }

        try await runtime.executeOperation(descriptor)

        let credentialCalls = await credentials.calls
        let terminalBeforeFinalizer = await probe.observedTerminalState
        XCTAssertEqual(credentialCalls, 0)
        XCTAssertEqual(legacyBackend.extractionCallCount(), 0)
        XCTAssertTrue(terminalBeforeFinalizer)
        XCTAssertFalse(recordingFileSystem.openedDirectoryURLs().contains(fixture.task5.destinationURL))
        XCTAssertFalse(recordingFileSystem.statNames().contains("file.txt"))
        XCTAssertFalse(recordingFileSystem.statNames().contains("sentinel"))
        XCTAssertEqual(try Data(contentsOf: published), publishedBytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        let finalResolution = try await restarted.resolveExtraction(for: descriptor.operationID)
        XCTAssertEqual(finalResolution, .absent)
    }

    func testTransactionalExtractionRequiresSessionBeforeCredentialResolution() async throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.remove() }
        let credentials = CredentialRecorder()
        let transaction = ExtractionTransaction(
            backend: UnexpectedExtractionBackend(),
            journal: UnexpectedJournal(),
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: UnexpectedNamespaceProvider(),
            fileSystem: DarwinFileSystemOperations(),
            quarantine: NoopQuarantine()
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: AbsentDurableResolver(),
            committedFinalizer: NoopCommittedFinalizer(),
            credentialResolver: credentials
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in 9 },
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture, sessionID: nil)

        await XCTAssertThrowsErrorAsync {
            try await runtime.executeOperation(descriptor)
        }

        let credentialCalls = await credentials.calls
        let state = await runtime.state(for: descriptor.operationID)
        XCTAssertEqual(credentialCalls, 0)
        XCTAssertEqual(state, .failed)
    }

    func testAskFailsBeforeResolverProviderInventoryOrRegister() async throws {
        let archiveID = ArchiveID(identity: .stable(
            volumeIdentifier: 21,
            fileIdentifier: 22,
            generation: 23
        ))
        let result = ExtractionResult(
            transactionID: TransactionID(),
            publishedURLs: [],
            skippedPaths: []
        )
        let execution = ArchiveExtractionExecution(
            result: result,
            postTerminalFinalizer: {}
        )
        let handler = HandlerRecorder(
            preparation: .committed(execution),
            freshExecution: execution
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = OperationDescriptor(
            archiveID: archiveID,
            sessionID: ArchiveSessionID(),
            payload: .extract(.init(
                archive: .init(
                    identity: archiveID.identity,
                    url: URL(fileURLWithPath: "/unused/archive.zip")
                ),
                destination: .init(
                    identity: nil,
                    url: URL(fileURLWithPath: "/unused/output", isDirectory: true)
                ),
                selectedEntryPaths: [],
                conflictPolicy: .ask,
                preserveTimestamps: true
            )),
            resourcePolicy: .production,
            ui: .init(title: "Ask")
        )

        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("Expected unresolved conflict policy")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .unresolvedConflictPolicy)
        }

        let preparedCount = await handler.preparedDescriptors.count
        let freshCount = await handler.freshDescriptors.count
        XCTAssertEqual(preparedCount, 0)
        XCTAssertEqual(freshCount, 0)
    }


    func testMultipartArchiveKeepsCompanionLookupAtOriginalBasename() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let companion = fixture.archive.url.deletingPathExtension()
            .appendingPathExtension("z01")
        try Data("companion".utf8).write(to: companion)
        let backend = MultipartArchiveStagingBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        _ = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(
            try Data(contentsOf: fixture.task5.destinationURL.appendingPathComponent("file.txt")),
            Data("archive".utf8)
        )
    }

    func testArchiveSourceReleaseNeverUnlinksForeignReplacement() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let probe = ArchiveReleaseSwapProbe(originalArchive: fixture.archive.url)
        defer { probe.cleanup() }
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            archiveSourceBindingBeforeReleaseObserver: {
                try probe.replaceBoundPathWithForeignFile($0)
            }
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertTrue(probe.foreignFileStillExists())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL.appendingPathComponent("file.txt").path
            )
        )
    }

    func testArchivePathSwapAndRestoreFailsClosedBeforePublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let backend = ArchivePathSwapStagingBackend(
            originalArchive: fixture.archive.url,
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL.appendingPathComponent("file.txt").path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.archive.url),
            Data("archive".utf8)
        )
    }

    func testBoundArchivePathSwapAndRestoreFailsClosedBeforePublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let backend = BoundArchivePathSwapStagingBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL.appendingPathComponent("file.txt").path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.archive.url),
            Data("archive".utf8)
        )
        XCTAssertEqual(try XCTUnwrap(backend.archiveURL()), fixture.archive.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.archive.url.path))
    }

    func testSymlinkArchiveRetargetAndRestoreFailsBeforeJournalOrPublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let archivePath = fixture.archive.url
        let archiveDirectory = archivePath.deletingLastPathComponent()
        let archiveA = archiveDirectory.appendingPathComponent("archive-a.zip")
        let archiveB = archiveDirectory.appendingPathComponent("archive-b.zip")
        try FileManager.default.moveItem(at: archivePath, to: archiveA)
        try Data("compatible-foreign".utf8).write(to: archiveB)
        try FileManager.default.createSymbolicLink(
            at: archivePath,
            withDestinationURL: archiveA
        )
        let backend = SymlinkRetargetStagingBackend(
            symlinkURL: archivePath,
            originalTarget: archiveA,
            replacementTarget: archiveB,
            inventory: inventory([fileEntry("file.txt")])
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )
        let callsBeforeExecute = backend.observations()

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        let callsAfterExecute = backend.observations()
        XCTAssertEqual(callsAfterExecute.inventoryCalls, callsBeforeExecute.inventoryCalls)
        XCTAssertEqual(
            callsAfterExecute.materializationCalls,
            callsBeforeExecute.materializationCalls
        )
        let registeredHeaders = await journal.registeredHeaders
        XCTAssertTrue(registeredHeaders.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL.appendingPathComponent("file.txt").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: archivePath.path),
            archiveA.path
        )
    }

    func testExecutionBuildsDurableStagingCleanupManifestBeforeRegisterAndRootCreate() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/nested/file.txt")
            ]),
            events: events
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store, events: events)
        let aborter = RecordingPreparationAborter(
            base: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            events: events
        )
        let transaction = ExtractionTransaction(
            backend: backend,
            journal: journal,
            preparationAborter: aborter,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let headers = await journal.registeredHeaders
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(
            headers[0].stagingCleanupManifest.entries.map(\.relativePath),
            ["folder", "folder/nested", "folder/nested/file.txt"]
        )
        let values = events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "inventory")),
                          try XCTUnwrap(values.firstIndex(of: "register")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "register")),
                          try XCTUnwrap(values.firstIndex(of: "createRoot")))
    }

    func testExecutionRegistersBeforeRootCreateAndActivatesBeforeStagingOrMutation() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")]),
            events: events
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store, events: events)
        let transaction = ExtractionTransaction(
            backend: backend,
            journal: journal,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let values = events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "register")),
                          try XCTUnwrap(values.firstIndex(of: "createRoot")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "createRoot")),
                          try XCTUnwrap(values.firstIndex(of: "activate")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "activate")),
                          try XCTUnwrap(values.firstIndex(of: "stage")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "stage")),
                          try XCTUnwrap(values.firstIndex(of: "appendStart")))
    }

    func testExecutionConsumesPreEstablishedVerifiedNamespaceWithoutPublicParentBootstrap() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let backend = StagingExtractionBackend(inventory: inventory([]))
        let transaction = ExtractionTransaction(
            backend: backend,
            journal: fixture.task5.store,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.task5.namespace.url.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL
                    .appendingPathComponent("transactions", isDirectory: true).path
            )
        )
    }

    func testExecutionFailsBeforeRegisterWhenNamespaceProviderRejectsDestinationVolume() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(inventory: inventory([])),
            journal: journal,
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: RejectingTransactionNamespaceProvider(),
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let headers = await journal.registeredHeaders
        XCTAssertTrue(headers.isEmpty)
    }

    func testExecutionRejectsMalformedTruncatedOrOverCapManifestBeforeRootCreate() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("../escape")])
            ),
            journal: journal,
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let headers = await journal.registeredHeaders
        XCTAssertTrue(headers.isEmpty)
    }

    func testStagingBackendMayWriteOnlyManifestPaths() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("expected.txt")]),
                extraStagingPath: "extra.txt"
            ),
            journal: fixture.task5.store,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected rollback failure for extra staged node")
        } catch let error as ArchiveFailure {
            guard case .rollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }


    func testRestartDuringStageBeforeFirstPublicationRecordCleansPartialImplicitParent() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "nested", kind: .directory),
            .init(relativePath: "nested/file.txt", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        try FileManager.default.createDirectory(
            at: active.activated.stagingURL.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: false,
            // 0755 reproduces what a real extractor leaves behind when the
            // process dies mid-stream: recovery must adopt (repair) the mode,
            // not require it, or a crashed transaction could never be cleaned up.
            attributes: [.posixPermissions: 0o755]
        )
        active.activated.close()

        let restarted = freshTransactionStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: restarted,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(
                fixture,
                locator: .init(
                    namespace: active.reservation.namespace,
                    rootName: active.reservation.rootName,
                    rootIdentity: active.rootIdentity
                )
            ).path
        ))
        let resolution = try await restarted.resolveExtraction(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .absent)
    }

    func testRestartDuringStageBeforeFirstPublicationRecordCleansPartialRegularFile() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "partial.txt", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        try Data("partial".utf8).write(
            to: active.activated.stagingURL.appendingPathComponent("partial.txt")
        )
        active.activated.close()

        let restarted = freshTransactionStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: restarted,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        let resolution = try await restarted.resolveExtraction(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .absent)
    }

    func testRestartDuringValidationCleansPartialSymlinkNodeDeepestFirst() async throws {
        let recorder = RecoveryRemovalRecorder()
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "nested", kind: .directory),
            .init(relativePath: "nested/link", kind: .symbolicLink),
        ])
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            manifest: manifest,
            operationObserver: recorder
        )
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        let nested = active.activated.stagingURL.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.createSymbolicLink(
            atPath: nested.appendingPathComponent("link").path,
            withDestinationPath: "target"
        )
        active.activated.close()

        let restarted = freshTransactionStore(fixture)
        try await ExtractionRecoveryCoordinator(
            journals: restarted,
            fileSystem: fixture.fileSystem
        ).recoverLiveTransactions()

        let removals = recorder.removals()
        XCTAssertLessThan(
            try XCTUnwrap(removals.firstIndex(of: "link")),
            try XCTUnwrap(removals.firstIndex(of: "nested"))
        )
        let resolution = try await restarted.resolveExtraction(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .absent)
    }

    func testRestartPreservesUnexpectedExtraOrManifestKindMismatch() async throws {
        for variant in ["extra", "kind"] {
            let manifest = StagingCleanupManifest(entries: [
                .init(relativePath: "expected", kind: .regularFile),
            ])
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            let active = try await Task5TestSupport.activateOwner(
                fixture,
                store: fixture.store,
                fileSystem: fixture.fileSystem
            )
            let expected = active.activated.stagingURL.appendingPathComponent("expected")
            if variant == "extra" {
                try Data("expected".utf8).write(to: expected)
                try Data("foreign".utf8).write(
                    to: active.activated.stagingURL.appendingPathComponent("foreign")
                )
            } else {
                try FileManager.default.createDirectory(
                    at: expected,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
            }
            active.activated.close()

            let restarted = freshTransactionStore(fixture)
            do {
                try await ExtractionRecoveryCoordinator(
                    journals: restarted,
                    fileSystem: fixture.fileSystem
                ).recoverLiveTransactions()
                XCTFail("Expected fail-closed recovery for \(variant)")
            } catch ArchiveFailure.rollbackFailed {
            } catch {
                XCTFail("Unexpected error for \(variant): \(error)")
            }

            let rootURL = fixture.namespace.url.appendingPathComponent(
                active.reservation.rootName,
                isDirectory: true
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path), variant)
            let live = try await restarted.liveTransactions()
            XCTAssertEqual(live.count, 1, variant)
            XCTAssertEqual(live.first?.phase, .active, variant)
        }
    }

    func testExecutionOrderIsPrepareStageValidateQuarantineCommit() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")]),
                events: events
            ),
            journal: RecordingExtractionJournal(base: fixture.task5.store, events: events),
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let values = events.values()
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "inventory")),
                          try XCTUnwrap(values.firstIndex(of: "stage")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "stage")),
                          try XCTUnwrap(values.firstIndex(of: "quarantine")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "quarantine")),
                          try XCTUnwrap(values.firstIndex(of: "markCommittedStart")))
    }

    func testExecutionCallsMarkCommittedOnlyAfterForwardLoopCompletes() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("a.txt"), fileEntry("b.txt")]),
                events: events
            ),
            journal: RecordingExtractionJournal(base: fixture.task5.store, events: events),
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let values = events.values()
        let commit = try XCTUnwrap(values.firstIndex(of: "markCommittedStart"))
        let appendReturns = values.indices.filter { values[$0] == "appendReturned" }
        XCTAssertEqual(appendReturns.count, 2)
        XCTAssertTrue(appendReturns.allSatisfy { $0 < commit })
    }

    func testPrepareFailureRemovesUnpublishedTransactionRoot() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let aborter = RecordingPreparationAborter(
            base: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            )
        )
        let failingJournal = FailingActivationJournal(base: journal)
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(inventory: inventory([])),
            journal: failingJournal,
            preparationAborter: aborter,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let abortCount = await aborter.transactionIDs.count
        let relinquishCount = await journal.relinquishCount
        XCTAssertEqual(abortCount, 1)
        XCTAssertEqual(relinquishCount, 1)
    }

    func testStageFailureRemovesUnpublishedTransactionRoot() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let aborter = RecordingPreparationAborter(
            base: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            )
        )
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")]),
                stagingError: ExtractionTransactionTestError.unexpectedCall("stage")
            ),
            journal: fixture.task5.store,
            preparationAborter: aborter,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let resolution = try await fixture.task5.store.resolveExtraction(
            for: fixture.request.operationID
        )
        let abortCount = await aborter.transactionIDs.count
        XCTAssertEqual(resolution, .absent)
        XCTAssertEqual(abortCount, 0)
    }

    func testValidationFailureRemovesUnpublishedTransactionRoot() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let aborter = RecordingPreparationAborter(
            base: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            )
        )
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("missing.txt")]),
                omittedStagingPaths: ["missing.txt"]
            ),
            journal: fixture.task5.store,
            preparationAborter: aborter,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let resolution = try await fixture.task5.store.resolveExtraction(
            for: fixture.request.operationID
        )
        let abortCount = await aborter.transactionIDs.count
        XCTAssertEqual(resolution, .absent)
        XCTAssertEqual(abortCount, 0)
    }

    func testQuarantineFailureRemovesUnpublishedTransactionRoot() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let aborter = RecordingPreparationAborter(
            base: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            )
        )
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            preparationAborter: aborter,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(
                injectedError: ArchiveFailure.rollbackFailed(
                    recoveryURL: fixture.task5.root,
                    cause: nil
                )
            )
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected quarantine failure")
        } catch ArchiveFailure.rollbackFailed(let recoveryURL, _) {
            XCTAssertEqual(recoveryURL, fixture.task5.root)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let resolution = try await fixture.task5.store.resolveExtraction(
            for: fixture.request.operationID
        )
        let abortCount = await aborter.transactionIDs.count
        let rolledBackCount = await journal.markRolledBackCount
        let releasedCount = await journal.releaseRolledBackCount
        XCTAssertEqual(rolledBackCount, 1)
        XCTAssertEqual(releasedCount, 1)
        XCTAssertEqual(resolution, .absent)
        XCTAssertEqual(abortCount, 0)
    }


    func testQuarantineUsesManifestWithoutEnumeratingDestination() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let destination = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(of: destination)
        destination.close()
        let guardedFileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity
        )
        let quarantine = RecordingPublicationQuarantine()
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("nested/file.txt")])
            ),
            journal: fixture.task5.store,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: guardedFileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: guardedFileSystem,
            quarantine: quarantine
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let applications = quarantine.entries()
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(
            applications[0].map(\.relativePath),
            ["nested", "nested/file.txt"]
        )
        XCTAssertEqual(
            applications[0].map(\.kind),
            [.directory, .regularFile]
        )
    }

    func testQuarantineRejectsNodeIdentityChangeBeforeXattr() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let quarantine = NoFollowManifestQuarantine { entry, stagingRoot in
            guard entry.relativePath == "file.txt" else { return }
            let url = stagingRoot.appendingPathComponent(entry.relativePath)
            let replacement = stagingRoot.appendingPathComponent("replacement.tmp")
            try Data("replacement".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
        }
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: fixture.task5.store,
            quarantine: quarantine
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected identity replacement rejection")
        } catch FileSystemOperationError.identityMismatch {
        } catch ArchiveFailure.rollbackFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("file.txt").path
        ))
        let retained = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.phase, .active)
    }

    func testQuarantineRejectsSymlinkParentTraversal() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let outside = fixture.task5.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let quarantine = NoFollowManifestQuarantine { entry, stagingRoot in
            guard entry.relativePath == "parent" else { return }
            let parent = stagingRoot.appendingPathComponent("parent", isDirectory: true)
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createSymbolicLink(
                atPath: parent.path,
                withDestinationPath: outside.path
            )
        }
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("parent/child.txt")])
            ),
            journal: fixture.task5.store,
            quarantine: quarantine
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected symlink parent rejection")
        } catch ArchiveFailure.rollbackFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("child.txt").path
        ))
    }

    func testQuarantineAppliesToExactSymlinkNodeWithoutOpeningTarget() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let target = fixture.task5.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    symbolicLinkEntry("link", target: target.path),
                ])
            ),
            journal: fixture.task5.store,
            quarantine: NoFollowManifestQuarantine()
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let publishedLink = fixture.task5.destinationURL.appendingPathComponent("link")
        XCTAssertEqual(
            try extendedAttribute(
                at: publishedLink,
                key: NoFollowManifestQuarantine.key,
                noFollow: true
            ),
            NoFollowManifestQuarantine.value
        )
        XCTAssertNil(try extendedAttribute(
            at: target,
            key: NoFollowManifestQuarantine.key,
            noFollow: false
        ))
    }

    func testQuarantineDoesNotApplySymlinkAttributeToTarget() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let target = fixture.task5.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    symbolicLinkEntry("link", target: target.path),
                ])
            ),
            journal: fixture.task5.store,
            quarantine: NoFollowManifestQuarantine()
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertNil(try extendedAttribute(
            at: target,
            key: NoFollowManifestQuarantine.key,
            noFollow: false
        ))
        let publishedLink = fixture.task5.destinationURL.appendingPathComponent("link")
        XCTAssertEqual(
            try extendedAttribute(
                at: publishedLink,
                key: NoFollowManifestQuarantine.key,
                noFollow: true
            ),
            NoFollowManifestQuarantine.value
        )
    }

    func testQuarantineDoesNotApplySymlinkAttributeToContainingParent() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let target = fixture.task5.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    symbolicLinkEntry("link", target: target.path),
                ])
            ),
            journal: fixture.task5.store,
            quarantine: NoFollowManifestQuarantine()
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertNil(try extendedAttribute(
            at: fixture.task5.destinationURL,
            key: NoFollowManifestQuarantine.key,
            noFollow: false
        ))
        let publishedLink = fixture.task5.destinationURL.appendingPathComponent("link")
        XCTAssertEqual(
            try extendedAttribute(
                at: publishedLink,
                key: NoFollowManifestQuarantine.key,
                noFollow: true
            ),
            NoFollowManifestQuarantine.value
        )
    }

    func testQuarantinePreservesUnrelatedTargetParentAndLinkXattrs() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let targetParent = fixture.task5.root.appendingPathComponent(
            "target-parent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetParent,
            withIntermediateDirectories: false
        )
        let target = targetParent.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let unrelatedKey = "com.xzip.tests.unrelated"
        let parentValue = Data("parent".utf8)
        let targetValue = Data("target".utf8)
        let linkValue = Data("link".utf8)
        try setExtendedAttribute(
            at: targetParent,
            key: unrelatedKey,
            value: parentValue,
            noFollow: false
        )
        try setExtendedAttribute(
            at: target,
            key: unrelatedKey,
            value: targetValue,
            noFollow: false
        )
        let quarantine = NoFollowManifestQuarantine { entry, stagingRoot in
            guard entry.relativePath == "link" else { return }
            try setExtendedAttribute(
                at: stagingRoot.appendingPathComponent("link"),
                key: unrelatedKey,
                value: linkValue,
                noFollow: true
            )
        }
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    symbolicLinkEntry("link", target: target.path),
                ])
            ),
            journal: fixture.task5.store,
            quarantine: quarantine
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let publishedLink = fixture.task5.destinationURL.appendingPathComponent("link")
        XCTAssertEqual(
            try extendedAttribute(at: targetParent, key: unrelatedKey, noFollow: false),
            parentValue
        )
        XCTAssertEqual(
            try extendedAttribute(at: target, key: unrelatedKey, noFollow: false),
            targetValue
        )
        XCTAssertEqual(
            try extendedAttribute(at: publishedLink, key: unrelatedKey, noFollow: true),
            linkValue
        )
        XCTAssertEqual(
            try extendedAttribute(
                at: publishedLink,
                key: NoFollowManifestQuarantine.key,
                noFollow: true
            ),
            NoFollowManifestQuarantine.value
        )
    }

    func testPreserveTimestampsIsForwardedUnchangedToStagingBackend() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, preserveTimestamps: false)
        let backend = StagingExtractionBackend(inventory: inventory([]))
        let transaction = ExtractionTransaction(
            backend: backend,
            journal: fixture.task5.store,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertEqual(backend.observations().preserveTimestamps, [false])
    }

    func testActualStagingByteCapRejectsBeforePublication() async throws {
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            stagingByteCap: 1
        )
        let fixture = try await makeTransactionExecutionFixture(
            self,
            resourcePolicy: policy
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("oversized.bin")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertEqual(backend.observations().policies, [policy])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("oversized.bin").path
        ))
    }

    func testSparseStagingFileIsChargedByLogicalSize() async throws {
        let logicalSize: UInt64 = 1_048_576
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            stagingByteCap: 65_536
        )
        let fixture = try await makeTransactionExecutionFixture(
            self,
            resourcePolicy: policy
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("sparse.bin")]),
            sparseFileSizes: ["sparse.bin": logicalSize]
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("sparse.bin").path
        ))
    }

    func testStagingChargeUsesAllocatedSizeWhenLargerThanLogical() {
        XCTAssertThrowsError(try StagingByteAccounting.adding(
            current: 0,
            logical: 1,
            allocated: 2,
            limit: 1
        )) { error in
            guard case let ArchiveFailure.resourceLimitExceeded(kind, limit, observed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(kind, .stagingBytes)
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 2)
        }
    }

    func testStagingChargeOverflowReportsUInt64Max() {
        XCTAssertThrowsError(try StagingByteAccounting.adding(
            current: UInt64.max,
            logical: 1,
            allocated: 0,
            limit: UInt64.max
        )) { error in
            guard case let ArchiveFailure.resourceLimitExceeded(kind, limit, observed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(kind, .stagingBytes)
            XCTAssertEqual(limit, UInt64.max)
            XCTAssertEqual(observed, UInt64.max)
        }
    }

    func testSwapPlanDigestAndJournalContainNoPasswordOrCredentialMaterial() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let password = "xzip-task7-password-sentinel"
        let credentialSentinel = "xzip-task7-credential-sentinel"
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        _ = try await transaction.execute(
            request,
            password: password + credentialSentinel
        ) { _ in }

        XCTAssertFalse(String(describing: request.planDigest).contains(password))
        XCTAssertFalse(String(describing: request.planDigest).contains(credentialSentinel))
        var durableBytes = Data()
        for path in try FileManager.default.subpathsOfDirectory(
            atPath: fixture.task5.namespace.url.path
        ) {
            let url = fixture.task5.namespace.url.appendingPathComponent(path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            durableBytes.append(try Data(contentsOf: url))
        }
        let durableText = String(decoding: durableBytes, as: UTF8.self)
        XCTAssertFalse(durableText.contains(password))
        XCTAssertFalse(durableText.contains(credentialSentinel))
    }

    func testSwapExecutionKeepsPasswordOutOfLogsAndProcessArguments() async throws {
        let password = "xzip-task7-process-password"
        let arguments = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/task7.zip"),
            destination: URL(fileURLWithPath: "/tmp/task7-staging"),
            options: ExtractionOptions(password: password, overwrite: true),
            entryListFile: nil
        )
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertFalse(arguments.contains { $0.contains(password) })
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains { $0.contains(password) })

        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let events = TransactionEventLog()
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")]),
            events: events
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            events: events
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        let result = try await transaction.execute(
            request,
            password: password
        ) { _ in }

        XCTAssertFalse(events.values().joined(separator: "\n").contains(password))
        XCTAssertFalse(String(describing: request).contains(password))
        XCTAssertFalse(String(describing: result).contains(password))
    }

    func testEphemeralCredentialClearsAfterBackendStreamAndIsNeverPersisted() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let transaction = ExtractionTransaction(
            backend: backend,
            journal: fixture.task5.store,
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: NoopQuarantine()
        )

        let result = try await transaction.execute(
            fixture.request,
            password: "secret"
        ) { _ in }

        let observations = backend.observations()
        XCTAssertEqual(observations.inventoryPasswords, ["secret", "secret"])
        XCTAssertEqual(observations.stagingPasswords, ["secret"])
        XCTAssertFalse(String(describing: result).contains("secret"))
        let indexData = try Data(
            contentsOf: fixture.task5.namespace.url
                .appendingPathComponent("extraction-index.json")
        )
        XCTAssertFalse(String(decoding: indexData, as: UTF8.self).contains("secret"))
    }

    func testProgressIsAwaitedInBackendOrderBeforeTerminalResultPublication() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let progressValues = [
            ArchiveProgress(fraction: 0.25, currentEntry: "a"),
            ArchiveProgress(fraction: 0.75, currentEntry: "b")
        ]
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([]),
                progressValues: progressValues,
                events: events
            ),
            journal: RecordingExtractionJournal(base: fixture.task5.store, events: events),
            preparationAborter: ExtractionRecoveryCoordinator(
                journals: fixture.task5.store,
                fileSystem: fixture.task5.fileSystem
            ),
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )
        let received = ProgressRecorder()

        _ = try await transaction.execute(fixture.request, password: nil) { value in
            await received.record(value)
            events.append("progress-\(value.currentEntry ?? "nil")")
            await Task.yield()
        }

        let receivedValues = await received.values
        XCTAssertEqual(receivedValues, progressValues)
        let values = events.values()
        let commit = try XCTUnwrap(values.firstIndex(of: "markCommittedStart"))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "progress-a")), commit)
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "progress-b")), commit)
    }

    func testFinishTerminalCompletedWithExactResultPrecedesCommittedFinalizer() async throws {
        let fixture = try makeRuntimeFixture()
        defer { fixture.remove() }
        let operationID = OperationID()
        let expected = ExtractionResult(
            transactionID: TransactionID(),
            publishedURLs: [fixture.destination.appendingPathComponent("file.txt")],
            skippedPaths: []
        )
        let probe = PostTerminalProbe()
        let execution = ArchiveExtractionExecution(
            result: expected,
            postTerminalFinalizer: { try await probe.run() }
        )
        let handler = HandlerRecorder(
            preparation: .committed(execution),
            freshExecution: execution
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)
        await probe.setChecker {
            let state = await runtime.state(for: descriptor.operationID)
            let result = await runtime.result(for: descriptor.operationID)
            return state == .completed && extractionResult(result) == expected
        }

        try await runtime.executeOperation(descriptor)

        let observed = await probe.observedTerminalState
        XCTAssertTrue(observed)
        XCTAssertEqual(operationID == descriptor.operationID, false)
    }

    func testCommittedFinalizerFailureKeepsCompletedResultAndRetainsMarker() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let initialTransaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: fixture.task5.store
        )
        let approvedRequest = try await fixture.approvedRequest(
            transaction: initialTransaction,
            policy: .replace
        )
        let expected = try await initialTransaction.execute(
            approvedRequest,
            password: nil
        ) { _ in }
        let liveBefore = try await fixture.task5.store.liveTransactions()
        let committed = try XCTUnwrap(liveBefore.first)
        let rootURL = fixture.task5.namespace.url.appendingPathComponent(
            committed.rootName,
            isDirectory: true
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: fixture.task5.fileSystem
        )
        let probe = PostTerminalProbe(
            injectedError: ExtractionTransactionTestError.unexpectedCall("finalizer")
        )
        let selectedTransaction = ExtractionTransaction(
            backend: UnexpectedExtractionBackend(),
            journal: UnexpectedJournal(),
            preparationAborter: UnexpectedPreparationAborter(),
            namespaceProvider: UnexpectedNamespaceProvider(),
            fileSystem: DarwinFileSystemOperations(),
            quarantine: NoopQuarantine()
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: selectedTransaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: ProbingCommittedFinalizer(
                base: recovery,
                probe: probe
            ),
            credentialResolver: nil
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ThrowingArchiveIdentityResolver(),
            volumeIdentifierProvider: { _ in
                throw ExtractionTransactionTestError.unexpectedCall("volume")
            },
            extractionHandler: handler
        )
        let descriptor = OperationDescriptor(
            operationID: fixture.request.operationID,
            archiveID: fixture.request.archive.archiveID,
            sessionID: fixture.request.sessionID,
            payload: .extract(.init(
                archive: .init(
                    identity: fixture.request.archive.archiveID.identity,
                    url: fixture.request.archive.url
                ),
                destination: .init(identity: nil, url: fixture.request.destination),
                selectedEntryPaths: fixture.request.selectedEntries,
                conflictPolicy: fixture.request.conflictPolicy,
                preserveTimestamps: fixture.request.preserveTimestamps
            )),
            resourcePolicy: fixture.request.resourcePolicy,
            ui: fixture.request.ui
        )
        await probe.setChecker {
            let state = await runtime.state(for: descriptor.operationID)
            let result = await runtime.result(for: descriptor.operationID)
            return state == .completed && extractionResult(result) == expected
        }

        try await runtime.executeOperation(descriptor)

        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let attempts = await probe.attempts
        let observedTerminal = await probe.observedTerminalState
        let retained = try await fixture.task5.store.resolveExtraction(
            for: descriptor.operationID
        )
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(extractionResult(result), expected)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(observedTerminal)
        XCTAssertEqual(retained, .committed(expected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testCancellationAfterPublishAppendPreventsMutation() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let moveReached = BooleanBox()
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, _ in
                guard fromName == "file.txt" else { return }
                moveReached.setTrue()
            }
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .publishMove = mutation else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(moveReached.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("file.txt").path
        ))
        let rolledBackCount = await journal.markRolledBackCount
        XCTAssertEqual(rolledBackCount, 1)
    }

    func testCancellationDuringDirectoryModeRestorationPreventsPublicationMove() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let firstModeRestored = BooleanBox()
        let moveReached = BooleanBox()
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, _ in
                guard fromName == "folder" else { return }
                moveReached.setTrue()
            },
            afterDirectoryModeSet: {
                guard !firstModeRestored.value else { return }
                firstModeRestored.setTrue()
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    directoryEntry("folder", mode: 0o750),
                    directoryEntry("folder/nested", mode: 0o705),
                    fileEntry("folder/nested/file.txt")
                ])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertTrue(firstModeRestored.value)
        XCTAssertFalse(moveReached.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("folder", isDirectory: true).path
        ))
        let rolledBackCount = await journal.markRolledBackCount
        XCTAssertEqual(rolledBackCount, 1)
    }

    func testPublicationFsyncFailurePreservesArmedRecoveryEvidence() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destinationFile = fixture.task5.destinationURL
            .appendingPathComponent("file.txt")
        let renameFailure = SecondRenameFailure()
        let base = DarwinFileSystemOperations(
            exclusiveRename: { sourceFD, source, destinationFD, destination in
                renameFailure.call(
                    sourceFD: sourceFD,
                    source: source,
                    destinationFD: destinationFD,
                    destination: destination
                )
            }
        )
        let destinationHandle = try base.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let moveCompleted = BooleanBox()
        let failureInjected = BooleanBox()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            afterSuccessfulMove: { name in
                guard name == "file.txt" else { return }
                moveCompleted.setTrue()
            },
            beforeFsync: {
                guard moveCompleted.value, !failureInjected.value else { return }
                failureInjected.setTrue()
                throw ExtractionTransactionTestError.unexpectedCall(
                    "injected post-publication fsync failure"
                )
            }
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertTrue(failureInjected.value)
        XCTAssertEqual(try Data(contentsOf: destinationFile), Data("file.txt".utf8))
        let rolledBackCount = await journal.markRolledBackCount
        let releasedCount = await journal.releaseRolledBackCount
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertEqual(releasedCount, 0)
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testCancellationAfterFinalPublicationBeforeCommitRollsBack() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            afterSuccessfulMove: { name in
                guard name == "file.txt" else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("file.txt").path
        ))
        let committedResults = await journal.committedResults
        let rolledBackCount = await journal.markRolledBackCount
        XCTAssertTrue(committedResults.isEmpty)
        XCTAssertEqual(rolledBackCount, 1)
    }

    func testPublicationSourceIdentityMismatchReportsExtractionPlanChanged()
        async throws
    {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            failFirstMoveWithIdentityMismatchToName: "file.txt"
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("file.txt").path
        ))
        let rolledBackCount = await journal.markRolledBackCount
        XCTAssertEqual(rolledBackCount, 1)
    }

    func testPostMoveIdentityDriftPreservesRecoveryEvidenceAndCurrentDestination()
        async throws
    {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destinationFile = fixture.task5.destinationURL
            .appendingPathComponent("file.txt")
        let movedTransactionNode = fixture.task5.root
            .appendingPathComponent("moved-transaction-file.txt")
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            afterSuccessfulMove: { name in
                guard name == "file.txt" else { return }
                try? FileManager.default.moveItem(
                    at: destinationFile,
                    to: movedTransactionNode
                )
                try? Data("current".utf8).write(to: destinationFile)
            }
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        var observedRecoveryURL: URL?
        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch let error as ArchiveFailure {
            guard case let .rollbackFailed(recoveryURL, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            observedRecoveryURL = recoveryURL
        }

        let recoveryURL = try XCTUnwrap(observedRecoveryURL)
        XCTAssertEqual(
            recoveryURL.deletingLastPathComponent().standardizedFileURL,
            fixture.task5.namespace.url.standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        XCTAssertEqual(try Data(contentsOf: destinationFile), Data("current".utf8))
        XCTAssertEqual(
            try Data(contentsOf: movedTransactionNode),
            Data("file.txt".utf8)
        )
        let rolledBackCount = await journal.markRolledBackCount
        let releaseCount = await journal.releaseRolledBackCount
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: request.operationID
        )
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testDestinationRootReplacementAfterAppendFailsBeforeMove() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let detached = fixture.task5.root
            .appendingPathComponent("detached-destination", isDirectory: true)
        let moveReached = BooleanBox()
        let fileSystem = DarwinFileSystemOperations(
            operationObserver: OperationBoundaryObserver { boundary, _ in
                if boundary == .beforeMoveVerification {
                    moveReached.setTrue()
                }
            }
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .publishMove = mutation else { return }
                try FileManager.default.moveItem(
                    at: fixture.task5.destinationURL,
                    to: detached
                )
                try FileManager.default.createDirectory(
                    at: fixture.task5.destinationURL,
                    withIntermediateDirectories: false
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(moveReached.value)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("file.txt").path
        ))
    }

    func testNestedDestinationParentReplacementAfterPublishArmFailsBeforeMove() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let folder = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        let existing = folder.appendingPathComponent(
            "subfolder",
            isDirectory: true
        )
        let oldFile = existing.appendingPathComponent("old.txt")
        let detached = fixture.task5.root
            .appendingPathComponent("detached-folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldFile)
        let moveReached = BooleanBox()
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, _ in
                guard fromName == "subfolder" else { return }
                moveReached.setTrue()
            }
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .replaceSwap(_, _, destination, _, _, _) = mutation,
                      destination.relativeParentPath == "folder",
                      destination.name == "subfolder"
                else { return }
                try FileManager.default.moveItem(at: folder, to: detached)
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: false
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    directoryEntry("folder/subfolder"),
                    fileEntry("folder/subfolder/new.txt")
                ])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["folder/subfolder"]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(moveReached.value)
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("subfolder/old.txt")),
            Data("old".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("subfolder/new.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("subfolder").path
        ))
    }

    func testDestinationRootReplacementAfterPublishPreservesDetachedTreeAndRecovery() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let detached = fixture.task5.root
            .appendingPathComponent("detached-destination", isDirectory: true)
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, toName in
                guard fromName == "file.txt",
                      toName == "file.txt",
                      !FileManager.default.fileExists(atPath: detached.path)
                else { return }
                try FileManager.default.moveItem(
                    at: fixture.task5.destinationURL,
                    to: detached
                )
                try FileManager.default.createDirectory(
                    at: fixture.task5.destinationURL,
                    withIntermediateDirectories: false
                )
            }
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch {
            guard case ArchiveFailure.rollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("file.txt").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("file.txt")),
            Data("file.txt".utf8),
            "lost pathname authority must not authorize inverse mutation of detached tree"
        )
        let committedResults = await journal.committedResults
        let rolledBackCount = await journal.markRolledBackCount
        let releaseCount = await journal.releaseRolledBackCount
        let retained = try await fixture.task5.store.liveTransactions()
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: request.operationID
        )
        XCTAssertTrue(committedResults.isEmpty)
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.phase, .active)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testRollbackAfterDestinationRootReplacementDoesNotMutateDetachedTree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let detached = fixture.task5.root
            .appendingPathComponent("detached-destination", isDirectory: true)
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .publishMove(_, _, destination, _) = mutation,
                      destination.name == "b.txt"
                else { return }
                try FileManager.default.moveItem(
                    at: fixture.task5.destinationURL,
                    to: detached
                )
                try FileManager.default.createDirectory(
                    at: fixture.task5.destinationURL,
                    withIntermediateDirectories: false
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    fileEntry("a.txt"),
                    fileEntry("b.txt")
                ])
            ),
            journal: journal
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch {
            guard case ArchiveFailure.rollbackFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("a.txt")),
            Data("a.txt".utf8),
            "rollback must freshly resolve destination authority before inverse mutation"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("b.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("a.txt").path
        ))
        let rolledBackCount = await journal.markRolledBackCount
        let releaseCount = await journal.releaseRolledBackCount
        let retained = try await fixture.task5.store.liveTransactions()
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: request.operationID
        )
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.phase, .active)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testRollbackRootReplacementAtInverseBoundaryPreservesRecoveryEvidence() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let detached = fixture.task5.root
            .appendingPathComponent("detached-destination", isDirectory: true)
        let firstMoveCompleted = BooleanBox()
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(
            of: destinationHandle
        )
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, toName in
                guard firstMoveCompleted.value,
                      fromName == "a.txt",
                      toName == "a.txt",
                      !FileManager.default.fileExists(atPath: detached.path)
                else { return }
                try FileManager.default.moveItem(
                    at: fixture.task5.destinationURL,
                    to: detached
                )
                try FileManager.default.createDirectory(
                    at: fixture.task5.destinationURL,
                    withIntermediateDirectories: false
                )
            },
            afterSuccessfulMove: { name in
                if name == "a.txt" {
                    firstMoveCompleted.setTrue()
                }
            }
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .publishMove(_, _, destination, _) = mutation,
                      destination.name == "b.txt"
                else { return }
                throw ExtractionTransactionTestError.unexpectedCall(
                    "second publication"
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    fileEntry("a.txt"),
                    fileEntry("b.txt")
                ])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        var observedRecoveryURL: URL?
        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch let error as ArchiveFailure {
            guard case let .rollbackFailed(recoveryURL, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            observedRecoveryURL = recoveryURL
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("a.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: detached.appendingPathComponent("a.txt").path
        ))
        let recoveryURL = try XCTUnwrap(observedRecoveryURL)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: recoveryURL,
            includingPropertiesForKeys: nil
        ))
        let retainedPublishedNodes = enumerator.compactMap { $0 as? URL }.filter { url in
            (try? Data(contentsOf: url)) == Data("a.txt".utf8)
        }
        let rolledBackCount = await journal.markRolledBackCount
        let releaseCount = await journal.releaseRolledBackCount
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: request.operationID
        )
        XCTAssertEqual(retainedPublishedNodes.count, 1)
        XCTAssertEqual(rolledBackCount, 0)
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testCancellationBeforeCommitRollsBackThenPublishesCancelled() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: fixture.task5.fileSystem
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")]),
                stagingError: CancellationError(),
                cancelTaskOnStaging: true
            ),
            journal: journal
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: recovery,
            credentialResolver: nil
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ArchiveIdentityResolver(),
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)

        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await XCTAssertThrowsErrorAsync {
            try await operation.value
        }

        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let rolledBack = await journal.markRolledBackCount
        let released = await journal.releaseRolledBackCount
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: descriptor.operationID
        )
        XCTAssertEqual(state, .cancelled)
        XCTAssertNil(result)
        XCTAssertEqual(rolledBack, 1)
        XCTAssertEqual(released, 1)
        XCTAssertEqual(resolution, .absent)
    }

    func testCancellationAfterMarkCommittedPublishesCompletedAndFinalizes() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            commitBehavior: .cancelAfterSuccess
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: fixture.task5.fileSystem
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("done.txt")])
            ),
            journal: journal
        )
        let probe = PostTerminalProbe()
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: ProbingCommittedFinalizer(
                base: recovery,
                probe: probe
            ),
            credentialResolver: nil
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ArchiveIdentityResolver(),
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)
        await probe.setChecker {
            await runtime.state(for: descriptor.operationID) == .completed
        }

        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        try await operation.value

        let committedResults = await journal.committedResults
        let expected = try XCTUnwrap(committedResults.first)
        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let attempts = await probe.attempts
        let terminalBeforeFinalizer = await probe.observedTerminalState
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: descriptor.operationID
        )
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(extractionResult(result), expected)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(terminalBeforeFinalizer)
        XCTAssertEqual(resolution, .absent)
    }

    func testRollbackFailureOverridesCancellationAndPublishesFailed() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: fixture.task5.fileSystem
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")]),
                stagingError: CancellationError(),
                cancelTaskOnStaging: true,
                extraStagingPath: "foreign.txt"
            ),
            journal: journal
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: recovery,
            credentialResolver: nil
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ArchiveIdentityResolver(),
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(fixture: fixture)

        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        do {
            try await operation.value
            XCTFail("Expected rollback failure")
        } catch ArchiveFailure.rollbackFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let rolledBack = await journal.markRolledBackCount
        let released = await journal.releaseRolledBackCount
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: descriptor.operationID
        )
        XCTAssertEqual(state, .failed)
        XCTAssertNil(result)
        XCTAssertEqual(rolledBack, 0)
        XCTAssertEqual(released, 0)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testCommitStateUncertainRunsNoInverseOrCleanupAndStartupUsesDurablePhase() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let recoveryURL = fixture.task5.namespace.url.appendingPathComponent("recovery")
        let events = TransactionEventLog()
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            events: events,
            commitBehavior: .uncertainAfterSuccess(recoveryURL)
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.task5.store,
            fileSystem: fixture.task5.fileSystem
        )
        let transaction = ExtractionTransaction(
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("committed.txt")]),
                events: events
            ),
            journal: journal,
            preparationAborter: recovery,
            namespaceProvider: fixture.task5.provider,
            fileSystem: fixture.task5.fileSystem,
            quarantine: RecordingPublicationQuarantine(events: events)
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: recovery,
            credentialResolver: nil
        )
        let runtimeFixture = RuntimeFixture(
            root: fixture.task5.root,
            archive: fixture.archive,
            destination: fixture.task5.destinationURL
        )
        let runtime = ArchiveRuntime(
            backend: LegacyExtractionBackendSpy(),
            identityResolver: ArchiveIdentityResolver(),
            extractionHandler: handler
        )
        let descriptor = makeExtractionDescriptor(
            fixture: runtimeFixture,
            operationID: fixture.request.operationID,
            sessionID: fixture.request.sessionID
        )

        do {
            try await runtime.executeOperation(descriptor)
            XCTFail("Expected uncertain commit failure")
        } catch let error as ArchiveFailure {
            // Destructured rather than compared whole: the cause is built from
            // the real failure, so pinning its exact wording here would test the
            // message instead of the plumbing. That it arrives at all is the
            // point — an uncertain commit used to reach the caller with the
            // reason stripped off.
            guard case let .rollbackFailed(url, cause) = error else {
                return XCTFail("Expected rollbackFailed, got \(error)")
            }
            XCTAssertEqual(url, recoveryURL)
            XCTAssertNotNil(cause, "the reason for the failed rollback must survive")
        }

        let state = await runtime.state(for: descriptor.operationID)
        let result = await runtime.result(for: descriptor.operationID)
        let markRolledBackCount = await journal.markRolledBackCount
        let releaseRolledBackCount = await journal.releaseRolledBackCount
        XCTAssertEqual(state, .failed)
        XCTAssertNil(result)
        XCTAssertEqual(markRolledBackCount, 0)
        XCTAssertEqual(releaseRolledBackCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL
                .appendingPathComponent("committed.txt").path
        ))
        XCTAssertFalse(events.values().contains("markRolledBack"))
        let freshIndexDirectory = try fixture.task5.fileSystem
            .openTransactionOwnedDirectoryNoFollow(
                at: fixture.task5.namespace.url,
                expected: fixture.task5.namespace.identity
            )
        defer { freshIndexDirectory.close() }
        let freshStore = TransactionJournalStore(
            indexDirectory: freshIndexDirectory,
            indexFileName: "extraction-index.json",
            policy: .production,
            fileSystem: fixture.task5.fileSystem
        )
        guard case let .committed(durableResult) = try await freshStore.resolveExtraction(
            for: fixture.request.operationID
        ) else {
            return XCTFail("Expected durable committed phase")
        }
        XCTAssertEqual(durableResult.publishedURLs.map(\.lastPathComponent), ["committed.txt"])
    }


    func testAbsentOperationResolvesCredentialExactlyOnceImmediatelyBeforeTransaction() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let credential = CredentialRecorder(events: events)
        let backend = StagingExtractionBackend(inventory: inventory([]), events: events)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            journal: fixture.task5.store
        )
        let handler = TransactionalArchiveExtractionHandler(
            transaction: transaction,
            durableResolver: fixture.task5.store,
            committedFinalizer: NoopCommittedFinalizer(),
            credentialResolver: credential
        )
        let runtimeFixture = RuntimeFixture(
            root: fixture.task5.root,
            archive: fixture.archive,
            destination: fixture.task5.destinationURL
        )
        let descriptor = makeExtractionDescriptor(
            fixture: runtimeFixture,
            operationID: fixture.request.operationID,
            sessionID: fixture.request.sessionID
        )
        guard case .fresh = try await handler.prepare(descriptor: descriptor) else {
            return XCTFail("Expected fresh preparation")
        }
        guard case let .extract(payload) = descriptor.payload else {
            return XCTFail("Expected extraction payload")
        }

        _ = try await handler.executeFresh(
            payload: payload,
            descriptor: descriptor
        ) { _ in }

        let calls = await credential.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Array(events.values().prefix(2)), ["credential", "inventory"])
    }

    func testEveryForwardDestinationEffectWaitsForAppendBeforeMutationReturn() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let events = TransactionEventLog()
        let journal = RecordingExtractionJournal(base: fixture.task5.store, events: events)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("a.txt"), fileEntry("b.txt")]),
                events: events
            ),
            journal: journal,
            quarantine: RecordingPublicationQuarantine(events: events)
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let records = await journal.armedMutations
        let values = events.values()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(values.filter { $0 == "appendReturned" }.count, 2)
        XCTAssertLessThan(
            try XCTUnwrap(values.lastIndex(of: "appendReturned")),
            try XCTUnwrap(values.firstIndex(of: "markCommittedStart"))
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("a.txt").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("b.txt").path
        ))
    }

    func testFailConflictMutatesNoConflictingLeafAndRollsBackEarlierEffects() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .fail)
        let conflicting = fixture.task5.destinationURL.appendingPathComponent("b.txt")
        try Data("original".utf8).write(to: conflicting)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("a.txt"), fileEntry("b.txt")])
            ),
            journal: journal
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected destination conflict")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: "b.txt"))
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("a.txt").path
        ))
        XCTAssertEqual(try Data(contentsOf: conflicting), Data("original".utf8))
        let records = await journal.armedMutations
        XCTAssertEqual(records.count, 1)
    }

    func testSkipDirectoryLeafConflictSkipsEntireExplicitSubtree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .skip)
        let conflicting = fixture.task5.destinationURL.appendingPathComponent("folder")
        try Data("original".utf8).write(to: conflicting)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/nested/file.txt")
            ])),
            journal: fixture.task5.store
        )

        let result = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertTrue(result.publishedURLs.isEmpty)
        XCTAssertEqual(result.skippedPaths, ["folder", "folder/nested/file.txt"])
        XCTAssertEqual(try Data(contentsOf: conflicting), Data("original".utf8))
    }

    func testApprovedReplacementUsesOneAtomicSwapWithoutDestinationAbsence() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe()
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        _ = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(exchange.callCount(), 1)
        XCTAssertEqual(exchange.bothNodesPresent(), [true])
        XCTAssertEqual(try Data(contentsOf: destination), Data("file.txt".utf8))
    }

    func testSourceReplacementInsideSwapRestoresForeignNodeAndFailsPlanChanged() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let detached = fixture.task5.destinationURL.appendingPathComponent("approved-detached")
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe(beforeExchange: { _, _, rightFD, rightName, call in
            guard call == 1 else { return }
            guard renameat(rightFD, rightName, rightFD, "approved-detached") == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            let descriptor = openat(rightFD, rightName, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { _ = close(descriptor) }
            let bytes = Array("foreign".utf8)
            guard write(descriptor, bytes, bytes.count) == bytes.count else {
                throw CocoaError(.fileWriteUnknown)
            }
        })
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(exchange.callCount(), 2)
        XCTAssertEqual(try Data(contentsOf: destination), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: detached), Data("old".utf8))
    }

    func testForeignCaptureWithChangedPublicDestinationPreservesRecoveryEvidence() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let approvedDetached = fixture.task5.destinationURL.appendingPathComponent("approved-detached")
        let replacementDetached = fixture.task5.destinationURL.appendingPathComponent("replacement-detached")
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe(
            beforeExchange: { _, _, rightFD, rightName, call in
                guard call == 1 else { return }
                guard renameat(rightFD, rightName, rightFD, "approved-detached") == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let descriptor = openat(rightFD, rightName, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = close(descriptor) }
                let bytes = Array("captured-foreign".utf8)
                guard write(descriptor, bytes, bytes.count) == bytes.count else {
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            afterExchange: { _, _, rightFD, rightName, call in
                guard call == 1 else { return }
                guard renameat(rightFD, rightName, rightFD, "replacement-detached") == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let descriptor = openat(rightFD, rightName, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = close(descriptor) }
                let bytes = Array("occupied".utf8)
                guard write(descriptor, bytes, bytes.count) == bytes.count else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("occupied".utf8))
        XCTAssertEqual(try Data(contentsOf: approvedDetached), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: replacementDetached), Data("file.txt".utf8))
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testDirectoryReplacementSwapsWholeSubtreeWithoutMerge() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let existing = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: existing.appendingPathComponent("unrelated.txt"))
        let exchange = ExchangeRenameProbe()
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("folder/new.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        _ = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(exchange.callCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("unrelated.txt").path))
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent("new.txt")),
            Data("folder/new.txt".utf8)
        )
    }

    func testCapturedAddedRemovedAndReplacedDescendantsReverseWholeSwap() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let existing = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("remove".utf8).write(to: existing.appendingPathComponent("remove.txt"))
        try Data("replace-old".utf8).write(to: existing.appendingPathComponent("replace.txt"))
        let exchange = ExchangeRenameProbe(beforeExchange: { _, _, _, _, call in
            guard call == 1 else { return }
            try FileManager.default.removeItem(at: existing.appendingPathComponent("remove.txt"))
            try FileManager.default.removeItem(at: existing.appendingPathComponent("replace.txt"))
            try Data("replace-new".utf8).write(to: existing.appendingPathComponent("replace.txt"))
            try Data("added".utf8).write(to: existing.appendingPathComponent("added.txt"))
        })
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("folder/new.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected extractionPlanChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .extractionPlanChanged)
        }

        XCTAssertEqual(exchange.callCount(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("remove.txt").path))
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("replace.txt")), Data("replace-new".utf8))
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("added.txt")), Data("added".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("new.txt").path))
    }

    func testStagedParentReplacementAfterArmedRecordFailsBeforeSwap() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destinationParent = fixture.task5.destinationURL
            .appendingPathComponent("root", isDirectory: true)
        let destination = destinationParent.appendingPathComponent("selected.txt")
        let detachedStagedParent = fixture.task5.root
            .appendingPathComponent("detached-staged-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParent,
            withIntermediateDirectories: false
        )
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe()
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case let .replaceSwap(_, staged, _, _, _, _) = mutation,
                      staged.relativeParentPath == "root",
                      staged.name == "selected.txt",
                      let enumerator = FileManager.default.enumerator(
                          at: fixture.task5.namespace.url,
                          includingPropertiesForKeys: nil
                      ),
                      let stagedParent = enumerator.compactMap({ $0 as? URL }).first(where: {
                          $0.lastPathComponent == "root"
                              && (try? Data(contentsOf: $0.appendingPathComponent("selected.txt")))
                                  == Data("root/selected.txt".utf8)
                      })
                else {
                    throw ExtractionTransactionTestError.unexpectedCall(
                        "staged replacement parent"
                    )
                }
                try FileManager.default.moveItem(
                    at: stagedParent,
                    to: detachedStagedParent
                )
                try FileManager.default.createDirectory(
                    at: stagedParent,
                    withIntermediateDirectories: false
                )
                try Data("foreign".utf8).write(
                    to: stagedParent.appendingPathComponent("selected.txt")
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("root/selected.txt")])
            ),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["root/selected.txt"]
        )

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertEqual(exchange.callCount(), 0)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(
            try Data(contentsOf: detachedStagedParent.appendingPathComponent("selected.txt")),
            Data("root/selected.txt".utf8)
        )
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testWholeStagingRootReplacementAfterReplaceArmFailsBeforeSwap() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let detached = fixture.task5.root.appendingPathComponent("detached-staging")
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe()
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .replaceSwap = mutation else { return }
                let replacement = try replaceLiveStagingRoot(
                    namespace: fixture.task5.namespace.url,
                    detached: detached
                )
                try Data("foreign".utf8).write(
                    to: replacement.appendingPathComponent("file.txt")
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertEqual(exchange.callCount(), 0)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("file.txt")),
            Data("file.txt".utf8)
        )
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testWholeStagingRootReplacementAfterPublishArmFailsBeforeMove() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let detached = fixture.task5.root.appendingPathComponent("detached-staging")
        let moveReached = BooleanBox()
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { fromName, _ in
                guard fromName == "file.txt" else { return }
                moveReached.setTrue()
            }
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            afterArm: { mutation in
                guard case .publishMove = mutation else { return }
                let replacement = try replaceLiveStagingRoot(
                    namespace: fixture.task5.namespace.url,
                    detached: detached
                )
                try Data("foreign".utf8).write(
                    to: replacement.appendingPathComponent("file.txt")
                )
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertFalse(moveReached.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("file.txt")),
            Data("file.txt".utf8)
        )
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testWholeStagingRootReplacementBeforeCommitGateRejectsCommit() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let detached = fixture.task5.root.appendingPathComponent("detached-staging")
        try Data("old".utf8).write(to: destination)
        let boundary = ExtractionTransactionBoundaryProbe { reached in
            guard reached == .afterAppliedRegistration,
                  !FileManager.default.fileExists(atPath: detached.path)
            else { return }
            _ = try replaceLiveStagingRoot(
                namespace: fixture.task5.namespace.url,
                detached: detached
            )
        }
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            boundaryProbe: boundary
        )
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try fixture.task5.fileSystem.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            boundaryProbe: boundary
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("file.txt".utf8))
        XCTAssertEqual(
            try Data(contentsOf: detached.appendingPathComponent("file.txt")),
            Data("old".utf8)
        )
        let committed = await journal.committedResults
        XCTAssertTrue(committed.isEmpty)
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testCommitGateRejectsIncompleteReplaceParentSyncCompletion() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            replaceSwapSyncCompletionBeforeCommit: { completion in
                var incomplete = completion
                incomplete.destinationParentSynced = false
                return incomplete
            }
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        let committed = await journal.committedResults
        XCTAssertTrue(committed.isEmpty)
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: request.operationID
        )
        XCTAssertEqual(resolution, .absent)
    }

    func testIncompleteSyncRollbackRejectsForeignCapturedStagedNode() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let detached = fixture.task5.root.appendingPathComponent("detached-captured")
        let replacement = CapturedSlotReplacementProbe(
            namespace: fixture.task5.namespace.url,
            detached: detached
        )
        let journal = RecordingExtractionJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")])
            ),
            journal: journal,
            replaceSwapSyncCompletionBeforeCommit: { completion in
                replacement.replaceCapturedNode()
                var incomplete = completion
                incomplete.destinationParentSynced = false
                return incomplete
            }
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertNil(replacement.error)
        XCTAssertEqual(try Data(contentsOf: destination), Data("file.txt".utf8))
        XCTAssertEqual(try Data(contentsOf: detached), Data("old".utf8))
        let committed = await journal.committedResults
        XCTAssertTrue(committed.isEmpty)
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testReplaceParentSyncFailuresRollbackUsingRegisteredMutation() async throws {
        for target in [
            ExtractionTransactionTestBoundary.afterReplaceSourceParentSync,
            .afterReplaceDestinationParentSync,
        ] {
            let fixture = try await makeTransactionExecutionFixture(self)
            defer { fixture.remove() }
            let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
            try Data("old".utf8).write(to: destination)
            let gateReached = BooleanBox()
            let injected = BooleanBox()
            let boundary = ExtractionTransactionBoundaryProbe { reached in
                if reached == target, !injected.value {
                    injected.setTrue()
                    throw ExtractionTransactionTestError.unexpectedCall("injected parent sync crash")
                }
                if reached == .afterAppliedRegistration {
                    gateReached.setTrue()
                }
            }
            let journal = RecordingExtractionJournal(
                base: fixture.task5.store,
                boundaryProbe: boundary
            )
            let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(
                at: fixture.task5.destinationURL
            )
            let destinationIdentity = try fixture.task5.fileSystem.identity(of: destinationHandle)
            destinationHandle.close()
            let fileSystem = DestinationEnumerationRejectingFileSystem(
                base: fixture.task5.fileSystem,
                destinationIdentity: destinationIdentity,
                rejectDestinationEnumeration: false,
                boundaryProbe: boundary
            )
            let transaction = makeTransaction(
                fixture: fixture,
                backend: StagingExtractionBackend(
                    inventory: inventory([fileEntry("file.txt")])
                ),
                journal: journal,
                fileSystem: fileSystem
            )
            let request = try await fixture.approvedRequest(
                transaction: transaction,
                policy: .replace
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await transaction.execute(request, password: nil) { _ in }
            }

            XCTAssertFalse(gateReached.value)
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
            let resolution = try await fixture.task5.store.resolveExtraction(
                for: request.operationID
            )
            XCTAssertEqual(resolution, .absent)
        }
    }

    func testCancellationAfterArmedRecordBeforeSwapLeavesDestinationUnchanged() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let boundary = ExtractionTransactionBoundaryProbe { reached in
            if reached == .afterReplaceArmed {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let journal = RecordingExtractionJournal(base: fixture.task5.store, boundaryProbe: boundary)
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try fixture.task5.fileSystem.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            boundaryProbe: boundary
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testRuntimeNeverCallsLegacyVerifiedMoveForReplacementOrRollback() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let boundary = ExtractionTransactionBoundaryProbe { reached in
            if reached == .afterReplaceSwap {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let journal = RecordingExtractionJournal(base: fixture.task5.store, boundaryProbe: boundary)
        let destinationHandle = try fixture.task5.fileSystem.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try fixture.task5.fileSystem.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: fixture.task5.fileSystem,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            boundaryProbe: boundary
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        let resolution = try await fixture.task5.store.resolveExtraction(for: request.operationID)
        XCTAssertEqual(resolution, .absent)
    }

    func testCommitGateRejectsUnaccountedArmedSwap() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            recoveryMutationTransform: { mutations in
                guard case let .replaceSwap(_, staged, publicNode, replacement, captured, _)? = mutations.first else {
                    return mutations
                }
                return mutations + [.replaceSwap(
                    mutationID: JournalMutationID(rawValue: UUID()),
                    staged: staged,
                    destination: publicNode,
                    replacementIdentity: replacement,
                    expectedCaptured: captured,
                    recoveryCapturedIdentity: nil
                )]
            }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testPublicDestinationChangeBeforeCommitPreservesRecoveryEvidence() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        let detached = fixture.task5.destinationURL.appendingPathComponent("replacement-detached")
        try Data("old".utf8).write(to: destination)
        let boundary = ExtractionTransactionBoundaryProbe { reached in
            guard reached == .afterAppliedRegistration,
                  FileManager.default.fileExists(atPath: destination.path),
                  !FileManager.default.fileExists(atPath: detached.path)
            else { return }
            try FileManager.default.moveItem(at: destination, to: detached)
            try Data("foreign".utf8).write(to: destination)
        }
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            boundaryProbe: boundary
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        do {
            _ = try await transaction.execute(request, password: nil) { _ in }
            XCTFail("Expected rollbackFailed")
        } catch ArchiveFailure.rollbackFailed {
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: detached), Data("file.txt".utf8))
        let live = try await fixture.task5.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
    }

    func testCancellationAfterDurableCommitDoesNotRollbackPublicEffects() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let exchange = ExchangeRenameProbe()
        let boundary = ExtractionTransactionBoundaryProbe { reached in
            if reached == .afterDurableCommit {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let base = DarwinFileSystemOperations(
            exclusiveRename: { renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL)) },
            exchangeRename: exchange.call
        )
        let destinationHandle = try base.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try base.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: base,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            boundaryProbe: boundary
        )
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            boundaryProbe: boundary
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: journal,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        _ = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(exchange.callCount(), 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("file.txt".utf8))
        guard case .committed = try await fixture.task5.store.resolveExtraction(for: request.operationID) else {
            return XCTFail("Expected committed resolution")
        }
    }

    func testUnsupportedSwapDoesNotInvokeBackendFinalDestinationFallback() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("file.txt")])
        )
        let unsupported = JournalTestFileSystem(base: fixture.task5.fileSystem)
        let destinationHandle = try unsupported.openDirectoryNoFollow(
            at: fixture.task5.destinationURL
        )
        let destinationIdentity = try unsupported.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: unsupported,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend,
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        let stagingDestinations = backend.observations().stagingDestinations
        XCTAssertEqual(stagingDestinations.count, 1)
        XCTAssertNotEqual(stagingDestinations.first, fixture.task5.destinationURL)
        XCTAssertTrue(stagingDestinations.allSatisfy {
            $0.path.hasPrefix(fixture.task5.namespace.url.path + "/")
                && $0.lastPathComponent == "staging"
        })
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testSwapUnsupportedFailsWithoutMoveOrPublicationFallback() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        defer { fixture.remove() }
        let destination = fixture.task5.destinationURL.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: destination)
        let moved = BooleanBox()
        let unsupported = JournalTestFileSystem(base: fixture.task5.fileSystem)
        let destinationHandle = try unsupported.openDirectoryNoFollow(at: fixture.task5.destinationURL)
        let destinationIdentity = try unsupported.identity(of: destinationHandle)
        destinationHandle.close()
        let fileSystem = DestinationEnumerationRejectingFileSystem(
            base: unsupported,
            destinationIdentity: destinationIdentity,
            rejectDestinationEnumeration: false,
            beforeForwardingMove: { _, _ in moved.setTrue() }
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            fileSystem: fileSystem
        )
        let request = try await fixture.approvedRequest(transaction: transaction, policy: .replace)

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(request, password: nil) { _ in }
        }

        XCTAssertFalse(moved.value)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testApprovedReplaceReplacesWholeExistingDirectorySubtree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("old".utf8).write(
            to: existing.appendingPathComponent("unrelated.txt")
        )
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("folder/new.txt")])
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("unrelated.txt").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent("new.txt")),
            Data("folder/new.txt".utf8)
        )
    }

    func testApprovedReplaceReplacesSelectedImplicitDirectorySubtree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("old".utf8).write(
            to: existing.appendingPathComponent("unrelated.txt")
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("folder/new.txt")])
            )
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["folder"]
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("unrelated.txt").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent("new.txt")),
            Data("folder/new.txt".utf8)
        )
    }

    func testApprovedReplaceMergesImplicitAncestorForSelectedDescendant() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let folder = fixture.task5.destinationURL
            .appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sibling = folder.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sibling)
        let selected = folder.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: selected)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("folder/new.txt")])
            )
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["folder/new.txt"]
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertEqual(
            try Data(contentsOf: selected),
            Data("folder/new.txt".utf8)
        )
    }

    func testApprovedReplaceReplacesFileWithFullImplicitDirectorySubtree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let folder = fixture.task5.destinationURL.appendingPathComponent("folder")
        try Data("old".utf8).write(to: folder)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("folder/new.txt")])
            )
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("new.txt")),
            Data("folder/new.txt".utf8)
        )
    }

    func testApprovedReplaceReplacesSymlinkWithFullImplicitDirectorySubtree() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let folder = fixture.task5.destinationURL.appendingPathComponent("folder")
        try FileManager.default.createSymbolicLink(
            atPath: folder.path,
            withDestinationPath: "target"
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("folder/new.txt")])
            )
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("new.txt")),
            Data("folder/new.txt".utf8)
        )
    }

    func testApprovedReplaceNormalizesSelectedImplicitDirectoryRoot() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let composed = "fólder"
        let decomposed = "fo\u{301}lder"
        let folder = fixture.task5.destinationURL
            .appendingPathComponent(composed, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("old".utf8).write(
            to: folder.appendingPathComponent("unrelated.txt")
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("\(composed)/new.txt")])
            )
        )
        let preflight = try await transaction.preflight(
            fixture.preflightRequest(
                policy: .replace,
                selectedEntries: [decomposed]
            ),
            password: nil
        )

        XCTAssertEqual(preflight.destructiveReplacementPaths, [composed])
        XCTAssertEqual(preflight.publicationBinding.map(\.originalPath), [composed])
        XCTAssertEqual(preflight.publicationBinding.map(\.decision), [.replace])
    }

    func testApprovedReplaceReplacesSelectedNestedSubtreeWithoutDeletingSibling() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let root = fixture.task5.destinationURL
            .appendingPathComponent("root", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        let old = nested.appendingPathComponent("old.txt")
        try Data("old".utf8).write(to: old)
        let backend = StagingExtractionBackend(
            inventory: inventory([
                directoryEntry("root/nested"),
                fileEntry("root/nested/new.txt")
            ])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["root/nested"]
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(
            try Data(contentsOf: nested.appendingPathComponent("new.txt")),
            Data("root/nested/new.txt".utf8)
        )
    }

    func testApprovedReplaceReplacesSelectedFileWithoutDeletingDirectorySibling() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let root = fixture.task5.destinationURL
            .appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        let selected = root.appendingPathComponent("selected.txt")
        try Data("old".utf8).write(to: selected)
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("root/selected.txt")])
        )
        let transaction = makeTransaction(fixture: fixture, backend: backend)
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace,
            selectedEntries: ["root/selected.txt"]
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertEqual(
            try Data(contentsOf: selected),
            Data("root/selected.txt".utf8)
        )
    }

    func testPublishRestoresArchiveDirectoryModeIncludingNestedDirectories() async throws {
        // The transaction adopts staged directories at 0700 so it can operate on
        // them privately, but the user must receive the mode the archive
        // recorded. 0750 and 0705 are chosen because they differ from both the
        // extractor's staging mode (0755) and the transaction's own 0700, so a
        // pass can only come from reading the inventory.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder", mode: 0o750),
                directoryEntry("folder/nested", mode: 0o705),
                fileEntry("folder/nested/file.txt")
            ])),
            journal: fixture.task5.store
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let folder = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        XCTAssertEqual(nodeMode(folder), 0o750, "published directory must carry the archive mode")
        // Publication renames the whole subtree in one step, so a nested
        // directory never gets its own publish step. Restoring only the top node
        // would leave this one at 0700.
        XCTAssertEqual(nodeMode(nested), 0o705, "nested published directory must carry its own mode")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: nested.appendingPathComponent("file.txt").path
        ))
    }

    func testPublishStripsGroupAndOtherWriteFromArchiveDirectoryMode() async throws {
        // R1: an archive controls the mode it declares, and the transaction used
        // to apply it verbatim (it only OR-ed owner rwx in). A directory
        // declaring 0777 therefore published as 0777, letting any other local
        // account write into the tree the user just extracted.
        //
        // Three modes, each carrying a different write bit to strip. 0770 -> 0750
        // and 0707 -> 0705 differ from both the staging mode (0755) and the
        // transaction's own 0700, so neither can pass by accident.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("wide", mode: 0o777),
                directoryEntry("wide/group", mode: 0o770),
                directoryEntry("wide/group/other", mode: 0o707),
                fileEntry("wide/group/other/file.txt")
            ])),
            journal: fixture.task5.store
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let wide = fixture.task5.destinationURL
            .appendingPathComponent("wide", isDirectory: true)
        let group = wide.appendingPathComponent("group", isDirectory: true)
        let other = group.appendingPathComponent("other", isDirectory: true)

        XCTAssertEqual(
            nodeMode(wide), 0o755,
            "0777 must lose group/other write but keep read+execute"
        )
        XCTAssertEqual(
            nodeMode(group), 0o750,
            "0770 must lose group write"
        )
        XCTAssertEqual(
            nodeMode(other), 0o705,
            "0707 must lose other write"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: other.appendingPathComponent("file.txt").path
        ))
    }

    func testPublishUsesDefaultModeWhenArchiveRecordedNone() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder", mode: nil),
                fileEntry("folder/file.txt")
            ])),
            journal: fixture.task5.store
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let folder = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        XCTAssertEqual(
            nodeMode(folder), defaultPublishedDirectoryMode,
            "a mode-less archive entry must not leak the transaction's private 0700"
        )
    }

    func testPublishAddsOwnerAccessToUnopenableArchiveDirectoryMode() async throws {
        // A directory recorded as 0000 would be unopenable after its mode is
        // restored. Restoration happens before the publishing rename, and the
        // transaction may still need to reach the subtree afterwards (keepBoth
        // retry, skip, cleanup, rollback), so owner rwx is forced on. Without
        // this the transaction would lock itself out of its own staged tree.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder", mode: 0o000),
                directoryEntry("folder/readonly", mode: 0o555),
                fileEntry("folder/readonly/file.txt")
            ])),
            journal: fixture.task5.store
        )

        _ = try await transaction.execute(fixture.request, password: nil) { _ in }

        let folder = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        let readonly = folder.appendingPathComponent("readonly", isDirectory: true)
        XCTAssertEqual(nodeMode(folder), 0o700, "0000 must gain owner rwx")
        XCTAssertEqual(nodeMode(readonly), 0o755, "0555 must gain owner write")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: readonly.appendingPathComponent("file.txt").path
        ))
    }

    func testKeepBothRepublishesDirectoryWithRestrictiveArchiveModeAfterNameCollision()
        async throws {
        // Publication restores modes before renaming, and keepBoth retries the
        // rename under a new name. The retry must still be able to open the
        // staged subtree it just relaxed.
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .keepBoth)
        let occupied = fixture.task5.destinationURL.appendingPathComponent("folder")
        try Data("existing".utf8).write(to: occupied)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder", mode: 0o555),
                fileEntry("folder/file.txt")
            ])),
            journal: fixture.task5.store
        )

        let result = try await transaction.execute(fixture.request, password: nil) { _ in }

        // Publishing a directory reports the directory and the files beneath it.
        XCTAssertEqual(
            result.publishedURLs.map(\.lastPathComponent),
            ["folder_1", "file.txt"]
        )
        let published = fixture.task5.destinationURL
            .appendingPathComponent("folder_1", isDirectory: true)
        XCTAssertEqual(nodeMode(published), 0o755)
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing".utf8))
    }

    func testPasswordRequiredPropagatesVerbatimThroughTheTransactionalPath() async throws {
        // Wave 9C routing sends an archive through the transactional path when no
        // password is known yet — which is exactly the state of an encrypted
        // archive on its FIRST extraction attempt. The app's prompt-and-retry UX
        // keys off `ArchiveEngineError.passwordRequired` reaching
        // AppModel.run's catch block, so the transaction must rethrow the
        // engine's error verbatim rather than wrapping it in an ArchiveFailure.
        // If this regresses, encrypted archives fail silently instead of
        // prompting, and rollback would mask the cause.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("file.txt")]),
                stagingError: ArchiveEngineError.passwordRequired
            ),
            journal: fixture.task5.store
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected the password requirement to surface")
        } catch let error as ArchiveEngineError {
            // ArchiveEngineError is not Equatable; pattern-match rather than
            // adding a conformance to a production type just for this test.
            guard case .passwordRequired = error else {
                return XCTFail("expected .passwordRequired, got \(error)")
            }
        } catch {
            XCTFail("password requirement must not be wrapped: \(error)")
        }
    }

    func testExecuteRequiresTheDestinationToAlreadyExist() async throws {
        // Contract test, not a wish: the transaction opens the destination with
        // `openDirectoryNoFollow` (no O_CREAT) as its very first action, so it
        // deliberately has no directory-creation authority. Callers must create
        // the destination themselves.
        //
        // This is pinned because the app's default destination is a subfolder
        // named after the archive, which does NOT exist yet. The legacy engine
        // path gets it for free (7zz's -o creates it), so whoever adapts this
        // transaction for that caller has to make up the difference.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry("file.txt")])),
            journal: fixture.task5.store
        )
        try FileManager.default.removeItem(at: fixture.request.destination)

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected a missing destination to fail")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileNoSuchFile)
        }
    }

    func testPasswordRequiredSurvivesRollbackWhenNothingWasStaged() async throws {
        // The companion test above stages nodes before failing, so rollback has
        // something to clean and the original error survives. The harder case is
        // an extractor that fails BEFORE creating anything, which the injected
        // error and `omittedStagingPaths` below simulate.
        //
        // Note this is a *synthetic* shape, not what the real 7zz does: 7zz
        // creates each output file before it discovers it cannot decrypt the
        // data, so it leaves 0-byte files behind rather than refusing outright
        // (see SevenZipEngineIntegrationTests.testFailedPasswordLeavesNoPartial-
        // Files). The shape is still worth pinning, because any staging extractor
        // that fails early must not have its error masked by rollback.
        //
        // With a nested inventory, cleanup iterates the manifest (derived from
        // the inventory, not from what was actually staged) and looks for the
        // parent directory `a/`. If a missing parent is treated as corruption,
        // the original `passwordRequired` is replaced by `rollbackFailed` and the
        // app's password prompt never opens.
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([
                    directoryEntry("a"),
                    fileEntry("a/b.txt")
                ]),
                stagingError: ArchiveEngineError.passwordRequired,
                // Nothing reaches staging, mirroring an immediate refusal.
                omittedStagingPaths: ["a", "a/b.txt"]
            ),
            journal: fixture.task5.store
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected the password requirement to surface")
        } catch let error as ArchiveEngineError {
            guard case .passwordRequired = error else {
                return XCTFail("expected .passwordRequired, got \(error)")
            }
        } catch {
            XCTFail("an empty staging rollback must not mask the cause: \(error)")
        }
    }

    func testRollbackSucceedsAfterModeRestoreRelaxedAStagedDirectory() async throws {
        // Pins the ordering the mode-restore safety argument depends on.
        //
        // Restoration relaxes a staged directory away from the transaction's
        // private 0700 *before* the publishing rename. Rollback then moves that
        // directory back into staging and cleans it up — and cleanup's
        // `removeOwnedNoFollow` requires exactly 0700, which only holds because
        // `validateStaging` re-adopts (and re-repairs) the whole tree first.
        //
        // Two top-level nodes are used so the first is published (and relaxed)
        // before the second fails: the directory is ordered first both
        // alphabetically and in the inventory, so it publishes regardless of
        // iteration order. If a future change let a strict-0700 consumer run
        // before that adopt pass, this surfaces as `rollbackFailed` instead of
        // the conflict the caller actually asked about.
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .fail)
        let occupied = fixture.task5.destinationURL.appendingPathComponent("z-conflict.txt")
        try Data("existing".utf8).write(to: occupied)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("a-folder", mode: 0o555),
                fileEntry("a-folder/file.txt"),
                fileEntry("z-conflict.txt")
            ])),
            journal: fixture.task5.store
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected the destination conflict to fail the extraction")
        } catch let error as ArchiveFailure {
            // The conflict must surface, NOT a rollback failure: reaching
            // `rollbackFailed` here would mean the relaxed staged directory
            // bricked its own rollback.
            XCTAssertEqual(error, .destinationConflict(path: "z-conflict.txt"))
        }

        // Rollback must leave the destination exactly as the user had it.
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.task5.destinationURL
                    .appendingPathComponent("a-folder").path
            ),
            "the published directory must be rolled back out of the destination"
        )
    }

    func testDirectoryMergeLeavesExistingDestinationModeUntouched() async throws {
        // Merging into a directory the user already owns must not restyle their
        // permissions: only directories XZIP itself publishes carry archive modes.
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .fail)
        let folder = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o711]
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder", mode: 0o750),
                fileEntry("folder/new.txt")
            ])),
            journal: fixture.task5.store
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        _ = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(nodeMode(folder), 0o711, "merge must preserve the user's directory mode")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("new.txt").path
        ))
    }

    func testApprovedReplaceReplacesExistingDirectoryWithFile() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let existing = fixture.task5.destinationURL
            .appendingPathComponent("node", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: existing.appendingPathComponent("child"))
        let backend = StagingExtractionBackend(
            inventory: inventory([fileEntry("node")])
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: backend
        )
        let approved = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .replace
        )

        _ = try await transaction.execute(approved, password: nil) { _ in }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: existing.path,
            isDirectory: &isDirectory
        ))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testKeepBothUsesUnderscoreSuffixAndPreservesLastExtension() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .keepBoth)
        let original = fixture.task5.destinationURL.appendingPathComponent("archive.tar.gz")
        try Data("original".utf8).write(to: original)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("archive.tar.gz")])
            ),
            journal: fixture.task5.store
        )

        let result = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertEqual(result.publishedURLs.map(\.lastPathComponent), ["archive.tar_1.gz"])
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testKeepBothDotAndTrailingDotNamingTable() async throws {
        let table = [
            ("archive.tar.gz", "archive.tar_1.gz"),
            ("name", "name_1"),
            (".env", ".env_1"),
            ("name.", "name._1"),
            ("a..b", "a._1.b")
        ]

        for (originalName, expectedName) in table {
            let fileFixture = try await makeTransactionExecutionFixture(
                self,
                conflictPolicy: .keepBoth
            )
            try Data("existing".utf8).write(
                to: fileFixture.task5.destinationURL.appendingPathComponent(originalName)
            )
            let fileTransaction = makeTransaction(
                fixture: fileFixture,
                backend: StagingExtractionBackend(
                    inventory: inventory([fileEntry(originalName)])
                ),
                journal: fileFixture.task5.store
            )
            let fileResult = try await fileTransaction.execute(
                fileFixture.request,
                password: nil
            ) { _ in }
            XCTAssertEqual(fileResult.publishedURLs.map(\.lastPathComponent), [expectedName])

            let directoryFixture = try await makeTransactionExecutionFixture(
                self,
                conflictPolicy: .keepBoth
            )
            try Data("existing".utf8).write(
                to: directoryFixture.task5.destinationURL.appendingPathComponent(originalName)
            )
            let directoryTransaction = makeTransaction(
                fixture: directoryFixture,
                backend: StagingExtractionBackend(
                    inventory: inventory([directoryEntry(originalName)])
                ),
                journal: directoryFixture.task5.store
            )
            let directoryResult = try await directoryTransaction.execute(
                directoryFixture.request,
                password: nil
            ) { _ in }
            XCTAssertEqual(
                directoryResult.publishedURLs.map(\.lastPathComponent),
                [expectedName]
            )
        }
    }

    func testKeepBothExhaustsExactlyTenThousandCandidatesThenFails() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .keepBoth)
        let originalName = "item.txt"
        try Data().write(to: fixture.task5.destinationURL.appendingPathComponent(originalName))
        for index in 1...10_000 {
            let name = "item_\(index).txt"
            try Data().write(to: fixture.task5.destinationURL.appendingPathComponent(name))
        }
        let journal = CollisionCountingJournal(base: fixture.task5.store)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([fileEntry(originalName)])),
            journal: journal
        )

        do {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
            XCTFail("Expected candidate exhaustion")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: originalName))
        }

        // Reaching `destinationConflict` at all is what proves the loop examined
        // every candidate: the throw sits after the final iteration, so an early
        // exit would surface as a different error or a published file.
        //
        // Zero appends is the point of the probe. Each append costs two fsyncs,
        // and a journal record exists to describe a mutation that is about to be
        // attempted; a name rejected by `statNoFollow` is never touched, so there
        // is nothing to record and nothing to roll back. This assertion used to
        // read 10_000, which measured the wasted durable writes rather than any
        // guarantee.
        let appendCount = await journal.appendCount
        XCTAssertEqual(
            appendCount, 0,
            "names rejected without being touched must not cost durable journal writes"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent(originalName).path
        ))
    }


    func testKeepBothFirstCandidateCollisionRetriesWithoutPoisoningRollback() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .keepBoth)
        let original = fixture.task5.destinationURL.appendingPathComponent("item.txt")
        let foreignCollision = fixture.task5.destinationURL.appendingPathComponent("item_1.txt")
        try Data("original".utf8).write(to: original)
        try Data("foreign".utf8).write(to: foreignCollision)
        let journal = RecordingExtractionJournal(
            base: fixture.task5.store,
            commitBehavior: .failBeforeCommit
        )
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(
                inventory: inventory([fileEntry("item.txt")])
            ),
            journal: journal
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await transaction.execute(fixture.request, password: nil) { _ in }
        }

        let records = await journal.armedMutations
        let rolledBack = await journal.markRolledBackCount
        let released = await journal.releaseRolledBackCount
        // One record, not two: `item_1.txt` is occupied by the foreign file, so
        // the probe skips it without journalling, and only the `item_2.txt`
        // publish that is actually attempted gets recorded. The rollback
        // assertions below are the substance of this test and are unchanged.
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(rolledBack, 1)
        XCTAssertEqual(released, 1)
        XCTAssertEqual(try Data(contentsOf: foreignCollision), Data("foreign".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.task5.destinationURL.appendingPathComponent("item_2.txt").path
        ))
        let resolution = try await fixture.task5.store.resolveExtraction(
            for: fixture.request.operationID
        )
        XCTAssertEqual(resolution, .absent)
    }

    func testResultIncludesOnlyPublishedExplicitEntriesInFinalPathOrder() async throws {
        let fixture = try await makeTransactionExecutionFixture(self)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                fileEntry("z.txt"),
                fileEntry("folder/nested/file.txt"),
                directoryEntry("folder")
            ])),
            journal: fixture.task5.store
        )

        let result = try await transaction.execute(fixture.request, password: nil) { _ in }
        let relative = result.publishedURLs.map {
            $0.path.replacingOccurrences(
                of: fixture.task5.destinationURL.path + "/",
                with: ""
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        XCTAssertEqual(relative, ["folder", "folder/nested/file.txt", "z.txt"])
    }

    func testResultExcludesMergedAndImplicitDirectories() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .fail)
        let folder = fixture.task5.destinationURL.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("folder"),
                fileEntry("folder/implicit/new.txt")
            ])),
            journal: fixture.task5.store
        )
        let request = try await fixture.approvedRequest(
            transaction: transaction,
            policy: .fail
        )

        let result = try await transaction.execute(request, password: nil) { _ in }

        XCTAssertEqual(result.publishedURLs.map(\.lastPathComponent), ["new.txt"])
        XCTAssertFalse(result.publishedURLs.contains(folder))
    }

    func testSkippedPathsContainExplicitSubtreeOnlyInOriginalPathOrder() async throws {
        let fixture = try await makeTransactionExecutionFixture(self, conflictPolicy: .skip)
        try Data().write(to: fixture.task5.destinationURL.appendingPathComponent("a"))
        try Data().write(to: fixture.task5.destinationURL.appendingPathComponent("z"))
        let transaction = makeTransaction(
            fixture: fixture,
            backend: StagingExtractionBackend(inventory: inventory([
                directoryEntry("z"),
                fileEntry("z/child.txt"),
                directoryEntry("a"),
                fileEntry("a/implicit/child.txt")
            ])),
            journal: fixture.task5.store
        )

        let result = try await transaction.execute(fixture.request, password: nil) { _ in }

        XCTAssertTrue(result.publishedURLs.isEmpty)
        XCTAssertEqual(
            result.skippedPaths,
            ["a", "a/implicit/child.txt", "z", "z/child.txt"]
        )
    }
}

private struct RuntimeFixture {
    let root: URL
    let archive: ArchiveLocator
    let destination: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeRuntimeFixture() throws -> RuntimeFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SafetyTask6B-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = root.appendingPathComponent("archive.zip")
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("archive".utf8).write(to: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let archive = try ArchiveIdentityResolver().resolve(archiveURL).locator
    return RuntimeFixture(root: root, archive: archive, destination: destination)
}

private func makeExtractionDescriptor(
    fixture: RuntimeFixture,
    operationID: OperationID = OperationID(),
    sessionID: ArchiveSessionID? = ArchiveSessionID(),
    conflictPolicy: OperationConflictPolicy = .fail
) -> OperationDescriptor {
    OperationDescriptor(
        operationID: operationID,
        archiveID: fixture.archive.archiveID,
        sessionID: sessionID,
        payload: .extract(.init(
            archive: .init(
                identity: fixture.archive.archiveID.identity,
                url: fixture.archive.url
            ),
            destination: .init(identity: nil, url: fixture.destination),
            selectedEntryPaths: [],
            conflictPolicy: conflictPolicy,
            preserveTimestamps: true
        )),
        resourcePolicy: .production,
        ui: .init(title: "Extract")
    )
}

private func extractionResult(_ result: OperationResult?) -> ExtractionResult? {
    guard case let .extraction(value) = result else { return nil }
    return value
}
