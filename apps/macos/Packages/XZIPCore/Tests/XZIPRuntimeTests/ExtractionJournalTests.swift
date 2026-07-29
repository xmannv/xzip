import Darwin
import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

enum Task5TestSupport {
    struct Fixture {
        let root: URL
        let applicationSupport: URL
        let destinationURL: URL
        let fileSystem: DarwinFileSystemOperations
        let provider: AppSupportTransactionNamespaceProvider
        let namespace: TransactionNamespaceLocator
        let indexDirectory: DirectoryHandle
        let store: TransactionJournalStore
        let header: ExtractionJournalHeader
    }

    static func makeFixture(
        _ test: XCTestCase,
        manifest: StagingCleanupManifest = .init(entries: []),
        maximumJournalBytes: Int = 1_048_576,
        operationObserver: (any FileSystemOperationObserving)? = nil,
        mutationObserver: (any JournalMutationObserving)? = nil,
        manifestPreparationObserver: (any JournalManifestPreparationObserving)? = nil
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafetyTask5Tests-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let fileSystem: DarwinFileSystemOperations
        if let operationObserver {
            fileSystem = DarwinFileSystemOperations(
                operationObserver: operationObserver
            )
        } else {
            fileSystem = DarwinFileSystemOperations()
        }
        let provider = try AppSupportTransactionNamespaceProvider(
            applicationSupportDirectory: applicationSupport,
            namespaceName: "transactions",
            fileSystem: fileSystem
        )
        let namespace = await provider.trustedNamespace()
        let indexDirectory = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: namespace.url,
            expected: namespace.identity
        )
        let destinationHandle = try fileSystem.openDirectoryNoFollow(at: destinationURL)
        let destinationIdentity = try fileSystem.identity(of: destinationHandle)
        destinationHandle.close()
        let transactionID = TransactionID()
        let header = ExtractionJournalHeader(
            transactionID: transactionID,
            operationID: OperationID(),
            archiveID: ArchiveID(identity: .stable(
                volumeIdentifier: destinationIdentity.device,
                fileIdentifier: destinationIdentity.inode,
                generation: destinationIdentity.generation
            )),
            destinationURL: destinationURL,
            destinationIdentity: destinationIdentity,
            stagingCleanupManifest: manifest,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = TransactionJournalStore(
            indexDirectory: indexDirectory,
            indexFileName: "extraction-index.json",
            policy: policy(maximumJournalBytes: maximumJournalBytes),
            fileSystem: fileSystem,
            mutationObserver: mutationObserver,
            manifestPreparationObserver: manifestPreparationObserver
        )
        return Fixture(
            root: root,
            applicationSupport: applicationSupport,
            destinationURL: destinationURL,
            fileSystem: fileSystem,
            provider: provider,
            namespace: namespace,
            indexDirectory: indexDirectory,
            store: store,
            header: header
        )
    }

    static func policy(
        maximumJournalBytes: Int,
        maximumRecoveryCountPerLaunch: Int? = nil
    ) -> ArchiveResourcePolicy {
        let base = ArchiveResourcePolicy.production
        return ArchiveResourcePolicy(
            listing: base.listing,
            output: base.output,
            process: base.process,
            cache: base.cache,
            split: base.split,
            command: base.command,
            journal: .init(
                maximumJournalBytes: maximumJournalBytes,
                retention: base.journal.retention,
                maximumRecoveryCountPerLaunch: maximumRecoveryCountPerLaunch
                    ?? base.journal.maximumRecoveryCountPerLaunch,
                maximumPruneCountPerPass: base.journal.maximumPruneCountPerPass
            ),
            scheduling: base.scheduling
        )
    }

    static func activate(_ fixture: Fixture) async throws -> TransactionRootLocator {
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let identity = try await fixture.store.createTransactionRoot(reservation)
        let activated = try await fixture.store.activate(reservation)
        activated.close()
        return TransactionRootLocator(
            namespace: reservation.namespace,
            rootName: reservation.rootName,
            rootIdentity: identity
        )
    }


    static func activateOwner(
        _ fixture: Fixture,
        store: TransactionJournalStore,
        fileSystem: any FileSystemOperations
    ) async throws -> (
        reservation: TransactionRootReservation,
        rootIdentity: FileNodeIdentity,
        activated: ActivatedExtractionTransaction
    ) {
        let reservation = try await store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await store.createTransactionRoot(reservation)
        let activated = try await store.activate(reservation)
        return (reservation, rootIdentity, activated)
    }

    static func result(
        _ fixture: Fixture,
        published: [(path: String, isDirectory: Bool)] = [],
        skippedPaths: [String] = []
    ) -> ExtractionResult {
        ExtractionResult(
            transactionID: fixture.header.transactionID,
            publishedURLs: published.map {
                fixture.destinationURL.appendingPathComponent(
                    $0.path,
                    isDirectory: $0.isDirectory
                )
            },
            skippedPaths: skippedPaths
        )
    }

    static func rootURL(_ fixture: Fixture, locator: TransactionRootLocator) -> URL {
        fixture.namespace.url.appendingPathComponent(locator.rootName, isDirectory: true)
    }

    static func nodeReference(
        root: TransactionRootKind,
        parent: DirectoryHandle,
        relativeParentPath: String = "",
        name: String,
        fileSystem: any FileSystemOperations
    ) throws -> JournalNodeReference {
        JournalNodeReference(
            root: root,
            relativeParentPath: relativeParentPath,
            parentIdentity: try fileSystem.identity(of: parent),
            name: name
        )
    }
}

private final class ThrowOnceJournalComponentObserver:
    FileSystemOperationObserving,
    @unchecked Sendable
{
    private let boundary: FileSystemOperationBoundary
    private let component: String
    private var didThrow = false

    init(
        boundary: FileSystemOperationBoundary,
        component: String
    ) {
        self.boundary = boundary
        self.component = component
    }

    func didReach(
        _ boundary: FileSystemOperationBoundary,
        component: String
    ) throws {
        guard boundary == self.boundary,
              component == self.component,
              !didThrow
        else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}


private final class ThrowOnceLegacyRecoveryObserver:
    ExtractionRecoveryObserving,
    @unchecked Sendable
{
    private let boundary: ExtractionRecoveryBoundary
    private var didThrow = false

    init(_ boundary: ExtractionRecoveryBoundary) {
        self.boundary = boundary
    }

    func didReach(_ boundary: ExtractionRecoveryBoundary) throws {
        guard boundary == self.boundary, !didThrow else { return }
        didThrow = true
        throw CocoaError(.fileWriteUnknown)
    }
}


final class FileSystemCallGate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func block() {
        reached.signal()
        resume.wait()
    }

    func waitUntilBlocked(timeout: DispatchTime) -> DispatchTimeoutResult {
        reached.wait(timeout: timeout)
    }

    func release() {
        resume.signal()
    }
}

final class JournalTestFileSystem: FileSystemOperations, @unchecked Sendable {
    private let base: any FileSystemOperations
    private let lock = NSLock()
    private var transactionOpenFailureName: String?
    private var failReplacementBeforeMutation = false
    private var forwardSwapOperations = false
    private var shouldMismatchNextSwapObservation = false
    private var failPostReplacementDirectoryFsync = false
    private var failDirectoryFsync = false
    private var replacementAwaitingDirectoryFsync = false
    private var replacementCalls = 0
    private var directoryFsyncCalls = 0
    private var openedDirectoryURLValues: [URL] = []
    private var statNameValues: [String] = []
    private var blockedStatName: String?
    private var blockedStatGate: FileSystemCallGate?
    private var blockedStatAfterResultName: String?
    private var blockedStatAfterResultGate: FileSystemCallGate?
    private var replacementBeforeIndexMutationName: String?
    private var replacementBeforeIndexMutationData: Data?
    private var replacementBeforeStat = false
    private var injectedReplacementIdentity: FileNodeIdentity?
    private let streamedNodes: [FileNode]?
    private let failIfListCalled: Bool
    private var streamedNodeCountValue = 0

    init(
        base: any FileSystemOperations = DarwinFileSystemOperations(),
        streamedNodes: [FileNode]? = nil,
        failIfListCalled: Bool = false
    ) {
        self.base = base
        self.streamedNodes = streamedNodes
        self.failIfListCalled = failIfListCalled
    }

    func failNextTransactionOpen(named name: String) {
        lock.lock()
        transactionOpenFailureName = name
        lock.unlock()
    }


    func failNextReplacementBeforeMutation() {
        lock.lock()
        failReplacementBeforeMutation = true
        lock.unlock()
    }

    func enableSwapForwarding() {
        lock.lock()
        forwardSwapOperations = true
        lock.unlock()
    }

    func mismatchNextSwapObservation() {
        lock.lock()
        shouldMismatchNextSwapObservation = true
        lock.unlock()
    }

    func failNextPostReplacementDirectoryFsync() {
        lock.lock()
        failPostReplacementDirectoryFsync = true
        lock.unlock()
    }

    func failNextDirectoryFsync() {
        lock.lock()
        failDirectoryFsync = true
        lock.unlock()
    }


    func blockNextStat(named name: String) -> FileSystemCallGate {
        let gate = FileSystemCallGate()
        lock.lock()
        blockedStatName = name
        blockedStatGate = gate
        lock.unlock()
        return gate
    }

    func blockNextStatAfterResult(named name: String) -> FileSystemCallGate {
        let gate = FileSystemCallGate()
        lock.lock()
        blockedStatAfterResultName = name
        blockedStatAfterResultGate = gate
        lock.unlock()
        return gate
    }

    func replaceNodeBeforeNextIndexMutation(
        named name: String,
        with data: Data,
        beforeStat: Bool = false
    ) {
        lock.lock()
        replacementBeforeIndexMutationName = name
        replacementBeforeIndexMutationData = data
        replacementBeforeStat = beforeStat
        lock.unlock()
    }

    func lastInjectedReplacementIdentity() -> FileNodeIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return injectedReplacementIdentity
    }

    func resetObservations() {
        lock.lock()
        replacementCalls = 0
        directoryFsyncCalls = 0
        openedDirectoryURLValues = []
        statNameValues = []
        lock.unlock()
    }

    func replacementCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return replacementCalls
    }

    func directoryFsyncCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return directoryFsyncCalls
    }

    func openedDirectoryURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedDirectoryURLValues
    }

    func statNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return statNameValues
    }

    func streamedNodeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return streamedNodeCountValue
    }

    private func consumeTransactionOpenFailure(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard transactionOpenFailureName == name else { return false }
        transactionOpenFailureName = nil
        return true
    }

    private func injectReplacementIfNeeded(
        parent: DirectoryHandle,
        name: String,
        beforeStat: Bool?
    ) throws {
        lock.lock()
        let data: Data?
        if replacementBeforeIndexMutationName == name,
           beforeStat == nil || replacementBeforeStat == beforeStat {
            data = replacementBeforeIndexMutationData
            replacementBeforeIndexMutationName = nil
            replacementBeforeIndexMutationData = nil
            replacementBeforeStat = false
        } else {
            data = nil
        }
        lock.unlock()
        guard let data else { return }

        let temporaryName = ".test-drift-\(UUID().uuidString).tmp"
        let temporary = try base.createRegularFileExclusive(
            parent: parent,
            name: temporaryName
        )
        try temporary.write(data)
        try temporary.fsync()
        temporary.close()
        let identity = try XCTUnwrap(
            base.statNoFollow(parent: parent, name: temporaryName)
        ).identity
        try base.replaceRegularFileAtomically(
            parent: parent,
            temporaryName: temporaryName,
            destinationName: name,
            expectedTemporary: identity
        )
        try base.fsync(parent)
        lock.lock()
        injectedReplacementIdentity = identity
        lock.unlock()
    }

    func openDirectoryNoFollow(at url: URL) throws -> DirectoryHandle {
        lock.lock()
        openedDirectoryURLValues.append(url)
        lock.unlock()
        return try base.openDirectoryNoFollow(at: url)
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
        if consumeTransactionOpenFailure(named: name) {
            throw CocoaError(.fileReadUnknown)
        }
        return try base.openTransactionOwnedDirectoryNoFollow(
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
        // Adoption is an owned-directory open, so it must honour the same
        // injected-failure hook as `openTransactionOwnedDirectoryNoFollow`.
        // Otherwise tests that inject a staged-directory open failure would
        // silently stop exercising that path.
        if consumeTransactionOpenFailure(named: name) {
            throw CocoaError(.fileReadUnknown)
        }
        return try base.adoptTransactionOwnedDirectoryNoFollow(
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
    }

    func identity(of directory: DirectoryHandle) throws -> FileNodeIdentity {
        try base.identity(of: directory)
    }

    func statNoFollow(parent: DirectoryHandle, name: String) throws -> FileNode? {
        try injectReplacementIfNeeded(
            parent: parent,
            name: name,
            beforeStat: true
        )
        lock.lock()
        statNameValues.append(name)
        let gate: FileSystemCallGate?
        if blockedStatName == name {
            gate = blockedStatGate
            blockedStatName = nil
            blockedStatGate = nil
        } else {
            gate = nil
        }
        lock.unlock()
        gate?.block()
        let result = try base.statNoFollow(parent: parent, name: name)
        lock.lock()
        let afterResultGate: FileSystemCallGate?
        if blockedStatAfterResultName == name {
            afterResultGate = blockedStatAfterResultGate
            blockedStatAfterResultName = nil
            blockedStatAfterResultGate = nil
        } else {
            afterResultGate = nil
        }
        lock.unlock()
        afterResultGate?.block()
        return result
    }

    func listNoFollow(_ directory: DirectoryHandle) throws -> [FileNode] {
        if failIfListCalled {
            throw CocoaError(.fileReadUnknown)
        }
        return try base.listNoFollow(directory)
    }

    func forEachNodeNoFollow(
        _ directory: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws {
        guard let streamedNodes else {
            try base.forEachNodeNoFollow(directory, body)
            return
        }
        for node in streamedNodes {
            lock.lock()
            streamedNodeCountValue += 1
            lock.unlock()
            try body(node)
        }
    }

    func createDirectoryExclusive(
        parent: DirectoryHandle,
        name: String
    ) throws -> FileNodeIdentity {
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
        lock.lock()
        let shouldFail = failReplacementBeforeMutation
        failReplacementBeforeMutation = false
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try injectReplacementIfNeeded(
            parent: parent,
            name: destinationName,
            beforeStat: false
        )
        try base.replaceRegularFileAtomically(
            parent: parent,
            temporaryName: temporaryName,
            destinationName: destinationName,
            expectedTemporary: expectedTemporary
        )
        lock.lock()
        replacementCalls += 1
        replacementAwaitingDirectoryFsync = true
        lock.unlock()
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

    func swapObserved(
        leftParent: DirectoryHandle,
        leftName: String,
        expectedLeft: FileNodeIdentity,
        rightParent: DirectoryHandle,
        rightName: String,
        expectedRight: FileNodeIdentity
    ) throws -> SwapObservation {
        lock.lock()
        let shouldForward = forwardSwapOperations
        let shouldFail = failReplacementBeforeMutation
        failReplacementBeforeMutation = false
        lock.unlock()
        guard shouldForward else {
            throw FileSystemOperationError.unsupportedTransactionalSwap
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try injectReplacementIfNeeded(
            parent: leftParent,
            name: leftName,
            beforeStat: nil
        )
        try injectReplacementIfNeeded(
            parent: rightParent,
            name: rightName,
            beforeStat: nil
        )
        let observation = try base.swapObserved(
            leftParent: leftParent,
            leftName: leftName,
            expectedLeft: expectedLeft,
            rightParent: rightParent,
            rightName: rightName,
            expectedRight: expectedRight
        )
        lock.lock()
        let shouldMismatch = shouldMismatchNextSwapObservation
        shouldMismatchNextSwapObservation = false
        lock.unlock()
        if shouldMismatch {
            return SwapObservation(
                leftIdentity: nil,
                rightIdentity: observation.rightIdentity
            )
        }
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
        lock.lock()
        directoryFsyncCalls += 1
        let afterReplacement = replacementAwaitingDirectoryFsync
        replacementAwaitingDirectoryFsync = false
        let shouldFail = failDirectoryFsync
            || (afterReplacement && failPostReplacementDirectoryFsync)
        if failDirectoryFsync {
            failDirectoryFsync = false
        }
        if afterReplacement && failPostReplacementDirectoryFsync {
            failPostReplacementDirectoryFsync = false
        }
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.fsync(directory)
    }
}

private final class RecordingJournalMutationObserver:
    JournalMutationObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [JournalMutationEvent] = []

    var events: [JournalMutationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func didReach(_ event: JournalMutationEvent) throws {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class RecordingJournalManifestPreparationObserver:
    JournalManifestPreparationObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var preparedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func didPrepareManifestEntry() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private struct ReplaceJournalMutationFixture {
    let staged: JournalNodeReference
    let destination: JournalNodeReference
    let replacementIdentity: FileNodeIdentity
    let expectedCaptured: CapturedTreeManifest
}

private struct DurableRootCreatedFixture {
    let fixture: Task5TestSupport.Fixture
    let reservation: TransactionRootReservation
    let rootURL: URL
    let rootIdentity: FileNodeIdentity
    let journalIdentity: FileNodeIdentity
}

final class ExtractionJournalTests: XCTestCase {
    private func makeReplaceJournalMutation(
        _ fixture: Task5TestSupport.Fixture,
        locator: TransactionRootLocator,
        descendantCount: Int = 0
    ) throws -> ReplaceJournalMutationFixture {
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: Task5TestSupport.rootURL(fixture, locator: locator),
            expected: locator.rootIdentity
        )
        defer { root.close() }
        let staging = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        defer { staging.close() }
        let destination = try fixture.fileSystem.openDirectoryNoFollow(
            at: fixture.destinationURL
        )
        defer { destination.close() }

        let replacementIdentity = try fixture.fileSystem.createDirectoryExclusive(
            parent: staging,
            name: "replacement"
        )
        let capturedRootIdentity = try fixture.fileSystem.createDirectoryExclusive(
            parent: destination,
            name: "target"
        )

        var entries = [CapturedTreeManifestEntry(
            relativePath: "",
            identity: capturedRootIdentity,
            byteCount: 0,
            allocatedByteCount: 0,
            timestamps: nil
        )]
        for index in (0..<descendantCount).reversed() {
            let identity = FileNodeIdentity(
                device: capturedRootIdentity.device,
                inode: UInt64(1_000_000 + index),
                generation: 1,
                kind: .regularFile
            )
            entries.append(CapturedTreeManifestEntry(
                relativePath: String(format: "child-%05d", index),
                identity: identity,
                byteCount: UInt64(index),
                allocatedByteCount: UInt64(index),
                timestamps: nil
            ))
        }
        let expectedCaptured = try CapturedTreeManifest(
            rootPath: "target",
            entries: entries
        )
        return ReplaceJournalMutationFixture(
            staged: try Task5TestSupport.nodeReference(
                root: .staging,
                parent: staging,
                name: "replacement",
                fileSystem: fixture.fileSystem
            ),
            destination: try Task5TestSupport.nodeReference(
                root: .destination,
                parent: destination,
                name: "target",
                fileSystem: fixture.fileSystem
            ),
            replacementIdentity: replacementIdentity,
            expectedCaptured: expectedCaptured
        )
    }

    private func replaceArmedRecord(
        mutationID: JournalMutationID,
        mutation: ReplaceJournalMutationFixture,
        manifestEntryCount: Int? = nil,
        manifestDigest: Data? = nil,
        expectedCapturedRootIdentity: FileNodeIdentity? = nil
    ) -> ExtractionJournalRecord {
        .replaceSwapArmed(
            mutationID: mutationID,
            staged: mutation.staged,
            destination: mutation.destination,
            replacementIdentity: mutation.replacementIdentity,
            expectedCapturedRootIdentity: expectedCapturedRootIdentity
                ?? mutation.expectedCaptured.entries[0].identity,
            manifestEntryCount: manifestEntryCount
                ?? mutation.expectedCaptured.entries.count,
            manifestDigest: manifestDigest ?? mutation.expectedCaptured.digest
        )
    }

    private func writeJournal(
        _ records: [ExtractionJournalRecord],
        trailingBytes: Data = Data(),
        fixture: Task5TestSupport.Fixture,
        locator: TransactionRootLocator
    ) throws {
        var data = Data()
        for record in records {
            data.append(JournalFrame.encode(payload: try JSONEncoder().encode(record)))
        }
        data.append(trailingBytes)
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private func makeDurableRootCreatedFixture() async throws -> DurableRootCreatedFixture {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)
        let namespace = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: reservation.rootName,
            expected: rootIdentity
        )
        let conflictingJournal = try fixture.fileSystem.createTransactionDirectoryExclusive(
            parent: root,
            name: "journal"
        )
        let journalIdentity = try fixture.fileSystem.identity(
            of: conflictingJournal
        )
        conflictingJournal.close()
        try fixture.fileSystem.fsync(root)
        try fixture.fileSystem.fsync(namespace)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.activate(reservation)
        }
        root.close()
        namespace.close()
        return DurableRootCreatedFixture(
            fixture: fixture,
            reservation: reservation,
            rootURL: Task5TestSupport.rootURL(
                fixture,
                locator: TransactionRootLocator(
                    namespace: reservation.namespace,
                    rootName: reservation.rootName,
                    rootIdentity: rootIdentity
                )
            ),
            rootIdentity: rootIdentity,
            journalIdentity: journalIdentity
        )
    }

    private func removeTransactionRootDurably(
        _ fixture: Task5TestSupport.Fixture,
        locator: TransactionRootLocator
    ) throws {
        let namespace = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        defer { namespace.close() }
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: locator.rootName,
            expected: locator.rootIdentity
        )
        for name in ["journal", "staging"] {
            let node = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(
                    parent: root,
                    name: name
                )
            )
            if node.identity.kind == .directory {
                let child = try fixture.fileSystem
                    .openTransactionOwnedDirectoryNoFollow(
                        parent: root,
                        name: name,
                        expected: node.identity
                    )
                XCTAssertTrue(try fixture.fileSystem.listNoFollow(child).isEmpty)
                child.close()
            }
            try fixture.fileSystem.removeOwnedNoFollow(
                parent: root,
                name: name,
                expected: node.identity
            )
        }
        root.close()
        try fixture.fileSystem.removeOwnedNoFollow(
            parent: namespace,
            name: locator.rootName,
            expected: locator.rootIdentity
        )
        try fixture.fileSystem.fsync(namespace)
        XCTAssertNil(
            try fixture.fileSystem.statNoFollow(
                parent: namespace,
                name: locator.rootName
            )
        )
    }


    private func indexObject(
        _ fixture: Task5TestSupport.Fixture,
        indexFileName: String = "extraction-index.json"
    ) throws -> [String: Any] {
        let url = fixture.namespace.url.appendingPathComponent(indexFileName)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func replaceIndexObject(
        _ object: [String: Any],
        fixture: Task5TestSupport.Fixture,
        indexFileName: String = "extraction-index.json"
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let temporaryName = ".test-index-\(UUID().uuidString).tmp"
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        try temporary.write(data)
        try temporary.fsync()
        temporary.close()
        let temporaryIdentity = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
        ).identity
        try fixture.fileSystem.replaceRegularFileAtomically(
            parent: fixture.indexDirectory,
            temporaryName: temporaryName,
            destinationName: indexFileName,
            expectedTemporary: temporaryIdentity
        )
        try fixture.fileSystem.fsync(fixture.indexDirectory)
    }

    private func emptyIndexObject(schemaVersion: Int) -> [String: Any] {
        [
            "entries": [],
            "schemaVersion": schemaVersion,
        ]
    }

    private func replacementTemporaryURL(
        _ fixture: Task5TestSupport.Fixture
    ) -> URL {
        fixture.namespace.url.appendingPathComponent(
            ".extraction-index.json.replacement.tmp"
        )
    }

    private func rewriteIndexAsV1WithoutOutcomes(
        _ fixture: Task5TestSupport.Fixture,
        indexFileName: String = "extraction-index.json"
    ) throws {
        var object = try indexObject(fixture, indexFileName: indexFileName)
        object["schemaVersion"] = 1
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        for index in entries.indices {
            var header = try XCTUnwrap(entries[index]["header"] as? [String: Any])
            header["schemaVersion"] = 1
            entries[index]["header"] = header
            entries[index].removeValue(forKey: "committedOutcome")
            entries[index].removeValue(forKey: "stagingIdentity")
        }
        object["entries"] = entries
        try replaceIndexObject(
            object,
            fixture: fixture,
            indexFileName: indexFileName
        )
    }

    func testArmReplaceSwapWritesCanonicalChunksThenOneDurableArmedRecord() async throws {
        let observer = RecordingJournalMutationObserver()
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            mutationObserver: observer
        )
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(
            fixture,
            locator: locator,
            descendantCount: 800
        )
        let mutationID = JournalMutationID(rawValue: try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        ))

        try await fixture.store.armReplaceSwap(
            mutationID: mutationID,
            staged: mutation.staged,
            destination: mutation.destination,
            replacementIdentity: mutation.replacementIdentity,
            expectedCaptured: mutation.expectedCaptured,
            transactionID: fixture.header.transactionID
        )

        let liveTransactions = try await fixture.store.liveTransactions()
        let persisted = try XCTUnwrap(liveTransactions.first)
        XCTAssertGreaterThan(persisted.records.count, 2)
        var flattenedEntries: [CapturedTreeManifestEntry] = []
        for (sequence, record) in persisted.records.dropLast().enumerated() {
            guard case let .replaceManifestChunk(
                recordedID,
                recordedSequence,
                entries
            ) = record else {
                return XCTFail("expected only manifest chunks before the armed record")
            }
            XCTAssertEqual(recordedID, mutationID)
            XCTAssertEqual(recordedSequence, sequence)
            XCTAssertFalse(entries.isEmpty)
            flattenedEntries.append(contentsOf: entries)
        }
        XCTAssertEqual(flattenedEntries, mutation.expectedCaptured.entries)
        guard case let .replaceSwapArmed(
            recordedID,
            staged,
            destination,
            replacementIdentity,
            expectedCapturedRootIdentity,
            manifestEntryCount,
            manifestDigest
        ) = persisted.records.last else {
            return XCTFail("expected one final armed record")
        }
        XCTAssertEqual(recordedID, mutationID)
        XCTAssertEqual(staged, mutation.staged)
        XCTAssertEqual(destination, mutation.destination)
        XCTAssertEqual(replacementIdentity, mutation.replacementIdentity)
        XCTAssertEqual(
            expectedCapturedRootIdentity,
            mutation.expectedCaptured.entries[0].identity
        )
        XCTAssertEqual(manifestEntryCount, mutation.expectedCaptured.entries.count)
        XCTAssertEqual(manifestDigest, mutation.expectedCaptured.digest)

        let recovered = try await fixture.store.recordsForRecovery(
            fixture.header.transactionID
        )
        XCTAssertEqual(recovered, [
            .replaceSwap(
                mutationID: mutationID,
                staged: mutation.staged,
                destination: mutation.destination,
                replacementIdentity: mutation.replacementIdentity,
                expectedCaptured: mutation.expectedCaptured,
                recoveryCapturedIdentity: nil
            ),
        ])
        XCTAssertEqual(observer.events.suffix(2), [
            .journalFileSynced,
            .transactionRootSynced,
        ])
    }

    func testReplaceManifestRejectsMissingDuplicateAndReorderedChunks() async throws {
        enum Scenario: CaseIterable {
            case missing
            case duplicate
            case reordered
        }

        for scenario in Scenario.allCases {
            let fixture = try await Task5TestSupport.makeFixture(self)
            let locator = try await Task5TestSupport.activate(fixture)
            let mutation = try makeReplaceJournalMutation(
                fixture,
                locator: locator,
                descendantCount: 2
            )
            let mutationID = JournalMutationID(rawValue: UUID())
            let entries = mutation.expectedCaptured.entries
            let records: [ExtractionJournalRecord]
            switch scenario {
            case .missing:
                records = [
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 0,
                        entries: [entries[0]]
                    ),
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 2,
                        entries: Array(entries[1...])
                    ),
                    replaceArmedRecord(
                        mutationID: mutationID,
                        mutation: mutation
                    ),
                ]
            case .duplicate:
                records = [
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 0,
                        entries: [entries[0]]
                    ),
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 1,
                        entries: [entries[1]]
                    ),
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 1,
                        entries: [entries[2]]
                    ),
                    replaceArmedRecord(
                        mutationID: mutationID,
                        mutation: mutation
                    ),
                ]
            case .reordered:
                records = [
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 0,
                        entries: [entries[0]]
                    ),
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 2,
                        entries: [entries[1]]
                    ),
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 1,
                        entries: [entries[2]]
                    ),
                    replaceArmedRecord(
                        mutationID: mutationID,
                        mutation: mutation
                    ),
                ]
            }
            try writeJournal(
                records,
                fixture: fixture,
                locator: locator
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.store.recordsForRecovery(
                    fixture.header.transactionID
                )
            }
        }
    }

    func testReplaceManifestRejectsWrongCountAndDigest() async throws {
        enum Scenario: CaseIterable {
            case count
            case digest
        }

        for scenario in Scenario.allCases {
            let fixture = try await Task5TestSupport.makeFixture(self)
            let locator = try await Task5TestSupport.activate(fixture)
            let mutation = try makeReplaceJournalMutation(
                fixture,
                locator: locator,
                descendantCount: 2
            )
            let mutationID = JournalMutationID(rawValue: UUID())
            let armed: ExtractionJournalRecord
            switch scenario {
            case .count:
                armed = replaceArmedRecord(
                    mutationID: mutationID,
                    mutation: mutation,
                    manifestEntryCount: mutation.expectedCaptured.entries.count + 1
                )
            case .digest:
                armed = replaceArmedRecord(
                    mutationID: mutationID,
                    mutation: mutation,
                    manifestDigest: Data(repeating: 0xA5, count: 32)
                )
            }
            try writeJournal(
                [
                    .replaceManifestChunk(
                        mutationID: mutationID,
                        sequence: 0,
                        entries: mutation.expectedCaptured.entries
                    ),
                    armed,
                ],
                fixture: fixture,
                locator: locator
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.store.recordsForRecovery(
                    fixture.header.transactionID
                )
            }
        }
    }

    func testTruncatedUnarmedManifestTailDoesNotCreateReplayableMutation() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(
            fixture,
            locator: locator,
            descendantCount: 1
        )
        let mutationID = JournalMutationID(rawValue: UUID())
        let firstChunk = ExtractionJournalRecord.replaceManifestChunk(
            mutationID: mutationID,
            sequence: 0,
            entries: [mutation.expectedCaptured.entries[0]]
        )
        let incompleteChunk = ExtractionJournalRecord.replaceManifestChunk(
            mutationID: mutationID,
            sequence: 1,
            entries: [mutation.expectedCaptured.entries[1]]
        )
        let incompleteFrame = JournalFrame.encode(
            payload: try JSONEncoder().encode(incompleteChunk)
        )
        try writeJournal(
            [firstChunk],
            trailingBytes: incompleteFrame.prefix(incompleteFrame.count / 2),
            fixture: fixture,
            locator: locator
        )

        let recovered = try await fixture.store.recordsForRecovery(
            fixture.header.transactionID
        )
        XCTAssertTrue(recovered.isEmpty)
        let live = try await fixture.store.liveTransactions()
        XCTAssertEqual(live.first?.records, [firstChunk])
    }

    func testArmReplaceSwapRejectsJournalCapBeforeJournalWriteOrMutationObserver() async throws {
        let maximumJournalBytes = 70_000
        let observer = RecordingJournalMutationObserver()
        let preparationObserver = RecordingJournalManifestPreparationObserver()
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            maximumJournalBytes: maximumJournalBytes,
            mutationObserver: observer,
            manifestPreparationObserver: preparationObserver
        )
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(
            fixture,
            locator: locator,
            descendantCount: 5_000
        )
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        let before = try Data(contentsOf: journalURL)

        do {
            try await fixture.store.armReplaceSwap(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: mutation.staged,
                destination: mutation.destination,
                replacementIdentity: mutation.replacementIdentity,
                expectedCaptured: mutation.expectedCaptured,
                transactionID: fixture.header.transactionID
            )
            XCTFail("Expected journal capacity rejection")
        } catch let TransactionJournalError.capacityExceeded(limit, observed) {
            XCTAssertEqual(limit, maximumJournalBytes)
            XCTAssertLessThanOrEqual(
                observed,
                maximumJournalBytes + 64 * 1_024,
                "Encoding must stop within one bounded chunk of the journal cap"
            )
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), before)
        XCTAssertTrue(observer.events.isEmpty)
        XCTAssertLessThan(
            preparationObserver.preparedEntryCount,
            mutation.expectedCaptured.entries.count,
            "Capacity rejection must stop manifest preparation before the tail"
        )
    }

    func testArmReplaceSwapRejectsUnsupportedManifestKindBeforeJournalWriteOrMutationObserver() async throws {
        let observer = RecordingJournalMutationObserver()
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            mutationObserver: observer
        )
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(fixture, locator: locator)
        let rootEntry = mutation.expectedCaptured.entries[0]
        let unsupportedEntry = CapturedTreeManifestEntry(
            relativePath: "pipe",
            identity: FileNodeIdentity(
                device: rootEntry.identity.device,
                inode: rootEntry.identity.inode ^ 2,
                generation: rootEntry.identity.generation,
                kind: .fifo
            ),
            byteCount: 0,
            allocatedByteCount: 0,
            timestamps: nil
        )
        let unsupportedManifest = try CapturedTreeManifest(
            rootPath: mutation.expectedCaptured.rootPath,
            entries: [rootEntry, unsupportedEntry]
        )
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        let before = try Data(contentsOf: journalURL)

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.armReplaceSwap(
                mutationID: JournalMutationID(rawValue: UUID()),
                staged: mutation.staged,
                destination: mutation.destination,
                replacementIdentity: mutation.replacementIdentity,
                expectedCaptured: unsupportedManifest,
                transactionID: fixture.header.transactionID
            )
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), before)
        XCTAssertTrue(observer.events.isEmpty)
    }

    func testArmReplaceSwapFsyncsJournalAndRootAfterArmedFrame() async throws {
        let observer = RecordingJournalMutationObserver()
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            mutationObserver: observer
        )
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(fixture, locator: locator)

        try await fixture.store.armReplaceSwap(
            mutationID: JournalMutationID(rawValue: UUID()),
            staged: mutation.staged,
            destination: mutation.destination,
            replacementIdentity: mutation.replacementIdentity,
            expectedCaptured: mutation.expectedCaptured,
            transactionID: fixture.header.transactionID
        )

        XCTAssertEqual(observer.events.suffix(2), [
            .journalFileSynced,
            .transactionRootSynced,
        ])
    }

    func testDuplicateMutationIDFailsClosed() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(fixture, locator: locator)
        let mutationID = JournalMutationID(rawValue: UUID())
        try await fixture.store.armReplaceSwap(
            mutationID: mutationID,
            staged: mutation.staged,
            destination: mutation.destination,
            replacementIdentity: mutation.replacementIdentity,
            expectedCaptured: mutation.expectedCaptured,
            transactionID: fixture.header.transactionID
        )
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        let beforeRetry = try Data(contentsOf: journalURL)

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.armReplaceSwap(
                mutationID: mutationID,
                staged: mutation.staged,
                destination: mutation.destination,
                replacementIdentity: mutation.replacementIdentity,
                expectedCaptured: mutation.expectedCaptured,
                transactionID: fixture.header.transactionID
            )
        }

        XCTAssertEqual(try Data(contentsOf: journalURL), beforeRetry)
    }

    func testReplaceManifestRejectsChunkAfterArmedRecord() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(
            fixture,
            locator: locator,
            descendantCount: 1
        )
        let mutationID = JournalMutationID(rawValue: UUID())
        try writeJournal(
            [
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: 0,
                    entries: mutation.expectedCaptured.entries
                ),
                replaceArmedRecord(
                    mutationID: mutationID,
                    mutation: mutation
                ),
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: 1,
                    entries: [mutation.expectedCaptured.entries[1]]
                ),
            ],
            fixture: fixture,
            locator: locator
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.recordsForRecovery(
                fixture.header.transactionID
            )
        }
    }

    func testConflictingMutationRecordTypeFailsClosed() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(fixture, locator: locator)
        let mutationID = JournalMutationID(rawValue: UUID())
        try writeJournal(
            [
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: 0,
                    entries: mutation.expectedCaptured.entries
                ),
                .publishMoveArmed(
                    mutationID: mutationID,
                    staged: mutation.staged,
                    destination: mutation.destination,
                    publishedIdentity: mutation.replacementIdentity
                ),
            ],
            fixture: fixture,
            locator: locator
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.recordsForRecovery(
                fixture.header.transactionID
            )
        }
    }

    func testReplaceManifestRejectsManifestWithoutRootEntry() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(
            fixture,
            locator: locator,
            descendantCount: 1
        )
        let mutationID = JournalMutationID(rawValue: UUID())
        let rootlessEntries = Array(mutation.expectedCaptured.entries.dropFirst())
        try writeJournal(
            [
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: 0,
                    entries: rootlessEntries
                ),
                replaceArmedRecord(
                    mutationID: mutationID,
                    mutation: mutation,
                    manifestEntryCount: rootlessEntries.count
                ),
            ],
            fixture: fixture,
            locator: locator
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.recordsForRecovery(
                fixture.header.transactionID
            )
        }
    }

    func testReplaceManifestRejectsMismatchedRootIdentity() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let mutation = try makeReplaceJournalMutation(fixture, locator: locator)
        let mutationID = JournalMutationID(rawValue: UUID())
        let rootIdentity = mutation.expectedCaptured.entries[0].identity
        let wrongRootIdentity = FileNodeIdentity(
            device: rootIdentity.device,
            inode: rootIdentity.inode ^ 1,
            generation: rootIdentity.generation,
            kind: rootIdentity.kind
        )
        try writeJournal(
            [
                .replaceManifestChunk(
                    mutationID: mutationID,
                    sequence: 0,
                    entries: mutation.expectedCaptured.entries
                ),
                replaceArmedRecord(
                    mutationID: mutationID,
                    mutation: mutation,
                    expectedCapturedRootIdentity: wrongRootIdentity
                ),
            ],
            fixture: fixture,
            locator: locator
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.recordsForRecovery(
                fixture.header.transactionID
            )
        }
    }

    func testRegisterPersistsReservedAndReturnsDeterministicRootNameWithoutCreatingRoot() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)

        let first = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let retry = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.transactionID, fixture.header.transactionID)
        XCTAssertTrue(first.rootName.contains(fixture.header.transactionID.rawValue.uuidString.lowercased()))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.namespace.url.appendingPathComponent(first.rootName).path
        ))
        let live = try await fixture.store.liveTransactions()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].phase, .reserved)
        XCTAssertEqual(live[0].header, fixture.header)
        XCTAssertEqual(live[0].records, [])
    }

    func testRegisterRejectsInvalidManifestAndCapacityBeforeRootCreation() async throws {
        let invalidManifests: [StagingCleanupManifest] = [
            .init(entries: [.init(relativePath: "../escape", kind: .regularFile)]),
            .init(entries: [.init(relativePath: "/absolute", kind: .regularFile)]),
            .init(entries: [
                .init(relativePath: "folder/file", kind: .regularFile),
            ]),
            .init(entries: [
                .init(relativePath: "a", kind: .regularFile),
                .init(relativePath: "A", kind: .regularFile),
            ]),
            .init(entries: [
                .init(relativePath: "ς", kind: .regularFile),
                .init(relativePath: "σ", kind: .regularFile),
            ]),
            .init(entries: [.init(relativePath: "   ", kind: .regularFile)]),
            .init(entries: [.init(relativePath: "line\nbreak", kind: .regularFile)]),
            .init(entries: [.init(relativePath: "nul\0byte", kind: .regularFile)]),
            .init(entries: [.init(relativePath: "device", kind: .blockDevice)]),
        ]

        for manifest in invalidManifests {
            let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.store.register(
                    transaction: fixture.header,
                    namespace: fixture.namespace
                )
            }
            XCTAssertEqual(try fixture.fileSystem.listNoFollow(fixture.indexDirectory).map(\.name), [])
        }

        let oversized = StagingCleanupManifest(entries: [
            .init(relativePath: String(repeating: "a", count: 512), kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            manifest: oversized,
            maximumJournalBytes: 128
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.register(
                transaction: fixture.header,
                namespace: fixture.namespace
            )
        }
        XCTAssertEqual(try fixture.fileSystem.listNoFollow(fixture.indexDirectory).map(\.name), [])
    }

    func testActivateCreatesOnlyJournalAndStaging() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)
        let activated = try await fixture.store.activate(reservation)
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url.appendingPathComponent(
                reservation.rootName,
                isDirectory: true
            ),
            expected: rootIdentity
        )
        defer { root.close() }

        let children = try fixture.fileSystem.listNoFollow(root)
        XCTAssertEqual(Set(children.map(\.name)), Set(["journal", "staging"]))
        XCTAssertEqual(
            children.first(where: { $0.name == "journal" })?.identity.kind,
            .regularFile
        )
        XCTAssertEqual(
            children.first(where: { $0.name == "staging" })?.identity,
            activated.stagingIdentity
        )

        activated.close()
    }

    func testActivateProvisionsInfrastructureAndAcceptsExactRetry() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)

        let first = try await fixture.store.activate(reservation)
        let retryReservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let retry = try await fixture.store.activate(retryReservation)

        XCTAssertEqual(first.stagingIdentity, retry.stagingIdentity)
        let reopened = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url.appendingPathComponent(
                reservation.rootName,
                isDirectory: true
            ),
            expected: rootIdentity
        )
        let children = try fixture.fileSystem.listNoFollow(reopened)
        XCTAssertEqual(Set(children.map(\.name)), Set(["journal", "staging"]))
        XCTAssertEqual(
            children.first(where: { $0.name == "journal" })?.identity.kind,
            .regularFile
        )
        XCTAssertEqual(
            children.first(where: { $0.name == "staging" })?.identity,
            first.stagingIdentity
        )
        let live = try await fixture.store.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
        first.close()
        retry.close()
        reopened.close()
    }

    func testRootCreatedFreshStoreActivationResumesAfterProvisionFailure() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)
        let namespace = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: namespace,
            name: reservation.rootName,
            expected: rootIdentity
        )
        let conflictingJournal = try fixture.fileSystem.createTransactionDirectoryExclusive(
            parent: root,
            name: "journal"
        )
        let conflictingIdentity = try fixture.fileSystem.identity(of: conflictingJournal)
        conflictingJournal.close()
        try fixture.fileSystem.fsync(root)
        try fixture.fileSystem.fsync(namespace)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.activate(reservation)
        }
        let interrupted = try await fixture.store.liveTransactions()
        XCTAssertEqual(interrupted.first?.phase, .rootCreated)

        try fixture.fileSystem.removeOwnedNoFollow(
            parent: root,
            name: "journal",
            expected: conflictingIdentity
        )
        root.close()
        namespace.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let freshReservation = try await fresh.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let activated = try await fresh.activate(freshReservation)
        let retryReservation = try await fresh.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let retry = try await fresh.activate(retryReservation)
        XCTAssertEqual(activated.stagingIdentity, retry.stagingIdentity)
        let live = try await fresh.liveTransactions()
        XCTAssertEqual(live.first?.phase, .active)
        activated.close()
        retry.close()
    }

    func testActivateReturnsOpaqueExactCapabilitiesOnlyAfterDurableActive() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)
        let activated = try await fixture.store.activate(reservation)

        XCTAssertEqual(activated.transactionID, fixture.header.transactionID)
        XCTAssertEqual(
            activated.stagingURL,
            fixture.namespace.url
                .appendingPathComponent(reservation.rootName, isDirectory: true)
                .appendingPathComponent("staging", isDirectory: true)
        )
        XCTAssertEqual(
            try fixture.fileSystem.identity(of: activated.stagingHandle),
            activated.stagingIdentity
        )
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let freshLive = try await fresh.liveTransactions()
        XCTAssertEqual(freshLive.first?.phase, .active)
        XCTAssertEqual(freshLive.first?.rootIdentity, rootIdentity)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.createTransactionRoot(reservation)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.activate(reservation)
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.store.relinquishPreparation(reservation)
        }

        activated.close()
        activated.close()
    }

    func testActivateRetryReopensCapabilitiesAndRejectsIdentityReplacement() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let rootIdentity = try await fixture.store.createTransactionRoot(reservation)
        let first = try await fixture.store.activate(reservation)
        let stagingIdentity = first.stagingIdentity
        first.close()

        let retryStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await retryStore.activate(reservation)
        }
        let retryReservation = try await retryStore.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let retry = try await retryStore.activate(retryReservation)
        XCTAssertEqual(retry.stagingIdentity, stagingIdentity)
        XCTAssertEqual(
            try fixture.fileSystem.identity(of: retry.stagingHandle),
            stagingIdentity
        )
        retry.close()

        let reopenedNamespace = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        let reopenedRoot = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: reopenedNamespace,
            name: reservation.rootName,
            expected: rootIdentity
        )
        try fixture.fileSystem.removeOwnedNoFollow(
            parent: reopenedRoot,
            name: "staging",
            expected: stagingIdentity
        )
        let replacement = try fixture.fileSystem.createTransactionDirectoryExclusive(
            parent: reopenedRoot,
            name: "staging"
        )
        let replacementIdentity = try fixture.fileSystem.identity(of: replacement)
        replacement.close()
        try fixture.fileSystem.fsync(reopenedRoot)
        reopenedRoot.close()
        reopenedNamespace.close()
        XCTAssertNotEqual(replacementIdentity, stagingIdentity)

        let replacementStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let replacementReservation = try await replacementStore.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await replacementStore.activate(replacementReservation)
        }
        let activeLive = try await replacementStore.liveTransactions()
        XCTAssertEqual(activeLive.first?.phase, .active)
    }

    func testRootCreatedRejectsEveryIllegalOperationWithoutMutation() async throws {
        let interrupted = try await makeDurableRootCreatedFixture()
        let fresh = TransactionJournalStore(
            indexDirectory: interrupted.fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: interrupted.fixture.fileSystem
        )
        let indexURL = interrupted.fixture.namespace.url
            .appendingPathComponent("extraction-index.json")
        let indexBefore = try Data(contentsOf: indexURL)

        for operation in [
            "markCommitted",
            "markRolledBack",
            "releaseCommitted",
            "releaseRolledBack",
        ] {
            switch operation {
            case "markCommitted":
                await XCTAssertThrowsErrorAsync {
                    try await fresh.markCommitted(
                        transactionID: interrupted.fixture.header.transactionID,
                        result: Task5TestSupport.result(interrupted.fixture)
                    )
                }
            case "markRolledBack":
                await XCTAssertThrowsErrorAsync {
                    try await fresh.markRolledBack(
                        interrupted.fixture.header.transactionID
                    )
                }
            case "releaseCommitted":
                await XCTAssertThrowsErrorAsync {
                    try await fresh.releaseCommitted(
                        operationID: interrupted.fixture.header.operationID
                    )
                }
            case "releaseRolledBack":
                await XCTAssertThrowsErrorAsync {
                    try await fresh.releaseRolledBack(
                        interrupted.fixture.header.transactionID
                    )
                }
            default:
                XCTFail("Unexpected operation")
            }

            let live = try await fresh.liveTransactions()
            XCTAssertEqual(live.count, 1)
            XCTAssertEqual(live[0].phase, .rootCreated)
            XCTAssertEqual(live[0].rootIdentity, interrupted.rootIdentity)
            XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
            let root = try interrupted.fixture.fileSystem
                .openTransactionOwnedDirectoryNoFollow(
                    at: interrupted.rootURL,
                    expected: interrupted.rootIdentity
                )
            let nodes = try interrupted.fixture.fileSystem.listNoFollow(root)
            XCTAssertEqual(nodes.map(\.name), ["journal"])
            XCTAssertEqual(nodes[0].identity, interrupted.journalIdentity)
            root.close()
        }
    }

    func testMatchingTerminalReleasesRemoveEntryAndFreshRetryIsNoop() async throws {
        for terminalPhase in [
            TransactionRecoveryPhase.rolledBack,
            .committed,
        ] {
            let fixture = try await Task5TestSupport.makeFixture(self)
            let locator = try await Task5TestSupport.activate(fixture)
            if terminalPhase == .rolledBack {
                try await fixture.store.markRolledBack(
                    fixture.header.transactionID
                )
            } else {
                try await fixture.store.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: Task5TestSupport.result(fixture)
                )
            }
            try removeTransactionRootDurably(
                fixture,
                locator: locator
            )

            if terminalPhase == .rolledBack {
                try await fixture.store.releaseRolledBack(
                    fixture.header.transactionID
                )
            } else {
                try await fixture.store.releaseCommitted(
                    operationID: fixture.header.operationID
                )
            }
            let released = try await fixture.store.resolution(
                for: fixture.header.operationID
            )
            XCTAssertEqual(released, .absent)

            let fresh = TransactionJournalStore(
                indexDirectory: fixture.indexDirectory,
                indexFileName: "extraction-index.json",
                policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
                fileSystem: fixture.fileSystem
            )
            if terminalPhase == .rolledBack {
                try await fresh.releaseRolledBack(
                    fixture.header.transactionID
                )
            } else {
                try await fresh.releaseCommitted(
                    operationID: fixture.header.operationID
                )
            }
            let retry = try await fresh.resolution(
                for: fixture.header.operationID
            )
            XCTAssertEqual(retry, .absent)
            let live = try await fresh.liveTransactions()
            XCTAssertTrue(live.isEmpty)
        }
    }

    func testCorruptFinalFrameIsDroppedAsAnIncompleteAppend() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        let (first, second) = try await Self.armTwoPublishMoves(
            fixture,
            locator: locator
        )
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        var bytes = try Data(contentsOf: journalURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: journalURL)

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let loaded = try await fresh.liveTransactions()
        XCTAssertEqual(loaded.first?.records, [first])
        XCTAssertNotEqual(loaded.first?.records, [first, second])
    }

    func testRewrittenEarlierFrameIsAHardFailureEvenThoughItStillDecodes() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        _ = try await Self.armTwoPublishMoves(fixture, locator: locator)
        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        var bytes = try Data(contentsOf: journalURL)
        let header = try XCTUnwrap(
            JournalFrame.decodeHeader(
                in: bytes,
                at: 0,
                maximumPayloadLength: 1_048_576
            )
        )
        let payloadStart = JournalFrame.headerSize
        let payloadEnd = payloadStart + header.payloadLength
        var payload = bytes.subdata(in: payloadStart..<payloadEnd)
        let original = Data("item-a".utf8)
        let replacement = Data("item-x".utf8)
        var searchFrom = payload.startIndex
        var replacements = 0
        while let found = payload.range(
            of: original,
            in: searchFrom..<payload.endIndex
        ) {
            payload.replaceSubrange(found, with: replacement)
            searchFrom = found.upperBound
            replacements += 1
        }
        XCTAssertGreaterThan(replacements, 0)
        bytes.replaceSubrange(payloadStart..<payloadEnd, with: payload)
        try bytes.write(to: journalURL)
        XCTAssertNoThrow(
            try JSONDecoder().decode(ExtractionJournalRecord.self, from: payload)
        )

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await fresh.liveTransactions()
        }
    }

    private static func armTwoPublishMoves(
        _ fixture: Task5TestSupport.Fixture,
        locator: TransactionRootLocator
    ) async throws -> (ExtractionJournalRecord, ExtractionJournalRecord) {
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: Task5TestSupport.rootURL(fixture, locator: locator),
            expected: locator.rootIdentity
        )
        defer { root.close() }
        let staging = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            parent: root,
            name: "staging",
            expected: nil
        )
        defer { staging.close() }
        let destination = try fixture.fileSystem.openDirectoryNoFollow(
            at: fixture.destinationURL
        )
        defer { destination.close() }
        var records: [ExtractionJournalRecord] = []
        for name in ["item-a", "item-b"] {
            let file = try fixture.fileSystem.createRegularFileExclusive(
                parent: staging,
                name: name
            )
            try file.write(Data(name.utf8))
            try file.fsync()
            file.close()
            let identity = try XCTUnwrap(
                fixture.fileSystem.statNoFollow(parent: staging, name: name)
            ).identity
            let mutationID = JournalMutationID(rawValue: UUID())
            let staged = try Task5TestSupport.nodeReference(
                root: .staging,
                parent: staging,
                name: name,
                fileSystem: fixture.fileSystem
            )
            let publicNode = try Task5TestSupport.nodeReference(
                root: .destination,
                parent: destination,
                name: name,
                fileSystem: fixture.fileSystem
            )
            try await fixture.store.armPublishMove(
                mutationID: mutationID,
                staged: staged,
                destination: publicNode,
                publishedIdentity: identity,
                transactionID: fixture.header.transactionID
            )
            records.append(.publishMoveArmed(
                mutationID: mutationID,
                staged: staged,
                destination: publicNode,
                publishedIdentity: identity
            ))
        }
        return (records[0], records[1])
    }

    /// R3: releasing an entry whose root is still on disk must fail, and must
    /// leave the entry in the index.
    ///
    /// Recovery is driven entirely by the index and never scans the namespace, so
    /// an entry dropped while its root still exists strands that root forever:
    /// nothing will ever look at it again. The two sibling release paths
    /// (`releaseRolledBack`, `releaseCommitted`) already refused this.
    func testReleasingAnEntryWhoseRootSurvivesFailsAndKeepsTheEntry() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        _ = try await fixture.store.createTransactionRoot(reservation)

        // Root deliberately left in place.
        do {
            try await fixture.store.releaseRecoveryEntry(fixture.header.transactionID)
            XCTFail("Expected the surviving root to block the release")
        } catch let error as TransactionJournalError {
            guard case .unsafeRecoveryState = error else {
                return XCTFail("expected .unsafeRecoveryState, got \(error)")
            }
        }

        let remaining = try await fixture.store.recoveryEntries()
        XCTAssertEqual(
            remaining.map(\.header.transactionID), [fixture.header.transactionID],
            "the entry must survive a refused release, or the root is stranded"
        )
    }

    /// The counterpart: once the root is genuinely gone the release proceeds and
    /// the entry is dropped. Without this, the check above could be satisfied by
    /// refusing every release, which would leak index entries instead of roots.
    func testReleasingAnEntryWhoseRootIsGoneSucceeds() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let reservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        _ = try await fixture.store.createTransactionRoot(reservation)

        let rootURL = fixture.namespace.url.appendingPathComponent(
            reservation.rootName,
            isDirectory: true
        )
        try FileManager.default.removeItem(at: rootURL)

        try await fixture.store.releaseRecoveryEntry(fixture.header.transactionID)
        let remaining = try await fixture.store.recoveryEntries()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// A `.reserved` entry has no root identity, because the name was reserved but
    /// no root was ever created. That is legitimate, so the durability check must
    /// treat a missing identity here as "nothing to verify" rather than as a
    /// corrupt index — otherwise recovery of a reserved entry would fail closed
    /// and never be able to clean itself up.
    func testReleasingAReservedEntryWithNoRootSucceeds() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        _ = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )

        try await fixture.store.releaseRecoveryEntry(fixture.header.transactionID)
        let remaining = try await fixture.store.recoveryEntries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testIllegalTransitionsFailClosedAndReleaseAbsentIsUniversalNoop() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try await fixture.store.releaseCommitted(operationID: OperationID())
        try await fixture.store.releaseRolledBack(TransactionID())
        _ = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.markCommitted(
                transactionID: fixture.header.transactionID,
                result: Task5TestSupport.result(fixture)
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.store.markRolledBack(fixture.header.transactionID)
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.store.releaseCommitted(operationID: fixture.header.operationID)
        }
        let resolution = try await fixture.store.resolution(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .unfinished)
    }


    func testPhaseMatrixFreshStoreAbsentReleaseAndTerminalRows() async throws {
        let absentFixture = try await Task5TestSupport.makeFixture(self)
        let absentFresh = TransactionJournalStore(
            indexDirectory: absentFixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: absentFixture.fileSystem
        )
        try await absentFresh.releaseRolledBack(TransactionID())
        try await absentFresh.releaseCommitted(operationID: OperationID())
        let absentResolution = try await absentFresh.resolution(
            for: OperationID()
        )
        XCTAssertEqual(absentResolution, .absent)

        for terminalPhase in [
            TransactionRecoveryPhase.rolledBack,
            .committed,
        ] {
            let fixture = try await Task5TestSupport.makeFixture(self)
            let reservation = try await fixture.store.register(
                transaction: fixture.header,
                namespace: fixture.namespace
            )
            _ = try await Task5TestSupport.activate(fixture)

            switch terminalPhase {
            case .rolledBack:
                try await fixture.store.markRolledBack(
                    fixture.header.transactionID
                )
                try await fixture.store.markRolledBack(
                    fixture.header.transactionID
                )
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.markCommitted(
                        transactionID: fixture.header.transactionID,
                        result: Task5TestSupport.result(fixture)
                    )
                }
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.releaseCommitted(
                        operationID: fixture.header.operationID
                    )
                }
            case .committed:
                try await fixture.store.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: Task5TestSupport.result(fixture)
                )
                try await fixture.store.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: Task5TestSupport.result(fixture)
                )
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.markRolledBack(
                        fixture.header.transactionID
                    )
                }
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.releaseRolledBack(
                        fixture.header.transactionID
                    )
                }
            default:
                XCTFail("Unexpected phase")
            }
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.store.activate(reservation)
            }
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.store.register(
                    transaction: fixture.header,
                    namespace: fixture.namespace
                )
            }
            let resolution = try await fixture.store.resolution(
                for: fixture.header.operationID
            )
            XCTAssertEqual(
                resolution,
                terminalPhase == .rolledBack ? .rolledBack : .committed
            )
        }
    }

    func testPhaseMatrixReservedAndActiveRejectNonmatchingRelease() async throws {
        for phase in [
            TransactionRecoveryPhase.reserved,
            .active,
        ] {
            let fixture = try await Task5TestSupport.makeFixture(self)
            _ = try await fixture.store.register(
                transaction: fixture.header,
                namespace: fixture.namespace
            )
            if phase == .active {
                _ = try await Task5TestSupport.activate(fixture)
            }

            await XCTAssertThrowsErrorAsync {
                try await fixture.store.releaseRolledBack(
                    fixture.header.transactionID
                )
            }
            await XCTAssertThrowsErrorAsync {
                try await fixture.store.releaseCommitted(
                    operationID: fixture.header.operationID
                )
            }
            if phase == .reserved {
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.markCommitted(
                        transactionID: fixture.header.transactionID,
                        result: Task5TestSupport.result(fixture)
                    )
                }
                await XCTAssertThrowsErrorAsync {
                    try await fixture.store.markRolledBack(
                        fixture.header.transactionID
                    )
                }
            }
            let resolution = try await fixture.store.resolution(
                for: fixture.header.operationID
            )
            XCTAssertEqual(resolution, .unfinished)
        }
    }

    func testDeterministicIndexTemporarySymlinkFailsClosedAndIsPreserved() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let target = fixture.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let temporary = fixture.namespace.url.appendingPathComponent(".extraction-index.json.replacement.tmp")
        try FileManager.default.createSymbolicLink(
            atPath: temporary.path,
            withDestinationPath: target.path
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.register(
                transaction: fixture.header,
                namespace: fixture.namespace
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
    }


    func testDeterministicIndexTemporaryDirectRemovalBoundariesResume() async throws {
        let temporaryName = ".extraction-index.json.replacement.tmp"
        for boundary in [
            FileSystemOperationBoundary.afterOwnedFinalVerification,
            .afterOwnedDirectRemoval,
            .afterOwnedParentSync,
        ] {
            let observer = ThrowOnceJournalComponentObserver(
                boundary: boundary,
                component: temporaryName
            )
            let fixture = try await Task5TestSupport.makeFixture(
                self,
                operationObserver: observer
            )
            let temporary = try fixture.fileSystem.createRegularFileExclusive(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
            try temporary.write(Data("temporary".utf8))
            try temporary.fsync()
            temporary.close()
            let first = TransactionJournalStore(
                indexDirectory: fixture.indexDirectory,
                indexFileName: "extraction-index.json",
                policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
                fileSystem: fixture.fileSystem
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await first.liveTransactions()
            }
            let observed = try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
            XCTAssertEqual(
                observed != nil,
                boundary == .afterOwnedFinalVerification
            )

            let resumed = TransactionJournalStore(
                indexDirectory: fixture.indexDirectory,
                indexFileName: "extraction-index.json",
                policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
                fileSystem: fixture.fileSystem
            )
            let live = try await resumed.liveTransactions()
            XCTAssertEqual(live, [])
            XCTAssertNil(
                try fixture.fileSystem.statNoFollow(
                    parent: fixture.indexDirectory,
                    name: temporaryName
                )
            )
        }
    }


    func testExactRetriesRespectDurablePhaseAndReverifyActiveInfrastructure() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let staleReservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let locator = try await Task5TestSupport.activate(fixture)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.activate(staleReservation)
        }
        let retryReservation = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )

        let journalURL = Task5TestSupport.rootURL(fixture, locator: locator)
            .appendingPathComponent("journal")
        XCTAssertEqual(chmod(journalURL.path, 0o644), 0)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.activate(retryReservation)
        }
        let resolution = try await fixture.store.resolution(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .unfinished)
    }

    func testReleaseRolledBackRequiresDurableRootAbsence() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        _ = try await Task5TestSupport.activate(fixture)
        try await fixture.store.markRolledBack(fixture.header.transactionID)

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.releaseRolledBack(fixture.header.transactionID)
        }
        let resolution = try await fixture.store.resolution(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .rolledBack)
    }

    func testReleaseCommittedRejectsReplacementAtTrackedRootName() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let locator = try await Task5TestSupport.activate(fixture)
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: Task5TestSupport.result(fixture)
        )
        let recovery = ExtractionRecoveryCoordinator(
            journals: fixture.store,
            fileSystem: fixture.fileSystem
        )
        try await recovery.recoverLiveTransactions()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Task5TestSupport.rootURL(fixture, locator: locator).path
        ))

        let namespace = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        let replacement = try fixture.fileSystem.createTransactionDirectoryExclusive(
            parent: namespace,
            name: locator.rootName
        )
        replacement.close()
        namespace.close()

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.releaseCommitted(operationID: fixture.header.operationID)
        }
        let resolution = try await fixture.store.resolution(for: fixture.header.operationID)
        XCTAssertEqual(resolution, .committed)
    }

    func testFreshStoreRejectsPhaseAndRootIdentityMismatchAsMalformedIndex() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        _ = try await fixture.store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        let indexURL = fixture.namespace.url.appendingPathComponent("extraction-index.json")
        let data = try Data(contentsOf: indexURL)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        entries[0]["phase"] = "active"
        entries[0]["rootIdentity"] = NSNull()
        document["entries"] = entries
        let malformed = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: indexURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: malformed)
        try handle.synchronize()
        try handle.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            _ = try await fresh.liveTransactions()
            XCTFail("Expected malformed index")
        } catch {
            XCTAssertEqual(error as? TransactionJournalError, .malformedIndex)
        }
    }


    func testReadChunkSizingIsOverflowSafeAtIntMax() {
        XCTAssertEqual(TransactionJournalStore.readChunkCount(forLimit: Int.max), 64 * 1_024)
        XCTAssertEqual(TransactionJournalStore.readChunkCount(forLimit: 0), 1)
    }


    func testRecoveryCountCapFailsBeforeProcessingAnyEntry() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let limitedStore = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "limited-extraction-index.json",
            policy: Task5TestSupport.policy(
                maximumJournalBytes: 8_192,
                maximumRecoveryCountPerLaunch: 1
            ),
            fileSystem: fixture.fileSystem
        )
        let secondHeader = ExtractionJournalHeader(
            transactionID: TransactionID(),
            operationID: OperationID(),
            archiveID: fixture.header.archiveID,
            destinationURL: fixture.header.destinationURL,
            destinationIdentity: fixture.header.destinationIdentity,
            stagingCleanupManifest: fixture.header.stagingCleanupManifest,
            createdAt: fixture.header.createdAt
        )
        _ = try await limitedStore.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        _ = try await limitedStore.register(
            transaction: secondHeader,
            namespace: fixture.namespace
        )

        let coordinator = ExtractionRecoveryCoordinator(
            journals: limitedStore,
            fileSystem: fixture.fileSystem
        )
        do {
            try await coordinator.recoverLiveTransactions()
            XCTFail("Expected recovery count cap rejection")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .capacityExceeded(limit: 1, observed: 2)
            )
        }

        let firstResolution = try await limitedStore.resolution(
            for: fixture.header.operationID
        )
        let secondResolution = try await limitedStore.resolution(
            for: secondHeader.operationID
        )
        XCTAssertEqual(firstResolution, .unfinished)
        XCTAssertEqual(secondResolution, .unfinished)
    }


    func testHeaderInitializerStampsStoreOwnedSchemaWithoutCallerVersion() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)

        let header = ExtractionJournalHeader(
            transactionID: TransactionID(),
            operationID: OperationID(),
            archiveID: fixture.header.archiveID,
            destinationURL: fixture.header.destinationURL,
            destinationIdentity: fixture.header.destinationIdentity,
            stagingCleanupManifest: fixture.header.stagingCleanupManifest,
            createdAt: fixture.header.createdAt
        )

        XCTAssertEqual(header.schemaVersion, 2)
    }

    func testActivateCapabilityReopenFailureRemainsRootCreatedAndPreparationAbortSucceeds() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let reservation = try await store.register(
            transaction: fixture.header,
            namespace: fixture.namespace
        )
        _ = try await store.createTransactionRoot(reservation)
        fileSystem.failNextTransactionOpen(named: "staging")

        await XCTAssertThrowsErrorAsync {
            _ = try await store.activate(reservation)
        }
        let interruptedLive = try await store.liveTransactions()
        XCTAssertEqual(interruptedLive.first?.phase, .rootCreated)

        fileSystem.failNextPostReplacementDirectoryFsync()
        await XCTAssertThrowsErrorAsync {
            _ = try await store.activate(reservation)
        }
        let failedHandoffLive = try await store.liveTransactions()
        XCTAssertEqual(failedHandoffLive.first?.phase, .rootCreated)

        let recovery = ExtractionRecoveryCoordinator(
            journals: store,
            fileSystem: fileSystem
        )
        await XCTAssertThrowsErrorAsync {
            try await recovery.abortPreparation(
                transactionID: fixture.header.transactionID
            )
        }
        try await store.relinquishPreparation(reservation)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.activate(reservation)
        }
        try await recovery.abortPreparation(
            transactionID: fixture.header.transactionID
        )

        let remainingLive = try await store.liveTransactions()
        XCTAssertTrue(remainingLive.isEmpty)
        let reopenedNamespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: fixture.namespace.url,
            expected: fixture.namespace.identity
        )
        XCTAssertNil(
            try fileSystem.statNoFollow(
                parent: reopenedNamespace,
                name: reservation.rootName
            )
        )
        reopenedNamespace.close()
    }


    func testMarkCommittedPersistsRelativeOutcomeAtomicallyWithCommittedPhase() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "alpha", kind: .regularFile),
            .init(relativePath: "folder", kind: .directory),
            .init(relativePath: "skip", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: store,
            fileSystem: fileSystem
        )
        active.activated.close()
        let result = Task5TestSupport.result(
            fixture,
            published: [("alpha", false), ("folder", true)],
            skippedPaths: ["skip"]
        )
        fileSystem.resetObservations()

        try await store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )

        XCTAssertEqual(fileSystem.replacementCallCount(), 1)
        let object = try indexObject(fixture)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["phase"] as? String, "committed")
        let outcome = try XCTUnwrap(entries[0]["committedOutcome"] as? [String: Any])
        let published = try XCTUnwrap(outcome["published"] as? [[String: Any]])
        XCTAssertEqual(published.compactMap { $0["relativePath"] as? String }, ["alpha", "folder"])
        XCTAssertEqual(published.compactMap { $0["isDirectory"] as? Bool }, [false, true])
        XCTAssertEqual(outcome["skippedPaths"] as? [String], ["skip"])
        let resolved = try await store.resolveExtraction(
            for: fixture.header.operationID
        )
        XCTAssertEqual(resolved, .committed(result))
    }

    func testMarkCommittedPostReplacementIndexFsyncFailureReportsCommitStateUncertain() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "published", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let store = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: store,
            fileSystem: fileSystem
        )
        active.activated.close()
        let result = Task5TestSupport.result(
            fixture,
            published: [("published", false)]
        )
        let recoveryURL = fixture.namespace.url.appendingPathComponent(
            active.reservation.rootName,
            isDirectory: true
        )
        fileSystem.resetObservations()
        fileSystem.failNextPostReplacementDirectoryFsync()

        do {
            try await store.markCommitted(
                transactionID: fixture.header.transactionID,
                result: result
            )
            XCTFail("Expected commit state uncertainty")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .commitStateUncertain(recoveryURL: recoveryURL)
            )
        }

        XCTAssertEqual(fileSystem.replacementCallCount(), 1)
        let reloaded = try await store.liveTransactions()
        XCTAssertEqual(reloaded.first?.phase, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let freshResolution = try await fresh.resolveExtraction(
            for: fixture.header.operationID
        )
        XCTAssertEqual(freshResolution, .committed(result))
    }

    func testMarkCommittedExactCommittedRetryFsyncsIndexDirectoryBeforeSuccess() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "published", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        active.activated.close()
        let result = Task5TestSupport.result(
            fixture,
            published: [("published", false)]
        )
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )

        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        fileSystem.resetObservations()
        try await fresh.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )
        XCTAssertEqual(fileSystem.replacementCallCount(), 0)
        XCTAssertEqual(fileSystem.directoryFsyncCallCount(), 1)

        fileSystem.resetObservations()
        fileSystem.failNextDirectoryFsync()
        do {
            try await fresh.markCommitted(
                transactionID: fixture.header.transactionID,
                result: result
            )
            XCTFail("Expected retry durability uncertainty")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .commitStateUncertain(
                    recoveryURL: fixture.namespace.url.appendingPathComponent(
                        active.reservation.rootName,
                        isDirectory: true
                    )
                )
            )
        }
        XCTAssertEqual(fileSystem.replacementCallCount(), 0)
        XCTAssertEqual(fileSystem.directoryFsyncCallCount(), 1)
    }

    func testMarkCommittedExactRetrySucceedsAndMismatchedRetryFailsClosed() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "a", kind: .regularFile),
            .init(relativePath: "b", kind: .regularFile),
            .init(relativePath: "folder", kind: .directory),
            .init(relativePath: "skip", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        active.activated.close()
        let result = Task5TestSupport.result(
            fixture,
            published: [("a", false), ("folder", true)],
            skippedPaths: ["skip"]
        )
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        try await fresh.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )

        let mismatches = [
            Task5TestSupport.result(
                fixture,
                published: [("b", false), ("folder", true)],
                skippedPaths: ["skip"]
            ),
            Task5TestSupport.result(
                fixture,
                published: [("a", false), ("folder", false)],
                skippedPaths: ["skip"]
            ),
            Task5TestSupport.result(
                fixture,
                published: [("a", false), ("folder", true)],
                skippedPaths: ["b"]
            ),
            Task5TestSupport.result(
                fixture,
                published: [("folder", true), ("a", false)],
                skippedPaths: ["skip"]
            ),
        ]
        for mismatch in mismatches {
            do {
                try await fresh.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: mismatch
                )
                XCTFail("Expected committed outcome mismatch")
            } catch {
                XCTAssertEqual(
                    error as? TransactionJournalError,
                    .committedOutcomeMismatch
                )
            }
        }
        let freshResolution = try await fresh.resolveExtraction(
            for: fixture.header.operationID
        )
        XCTAssertEqual(freshResolution, .committed(result))
    }

    func testDurableExtractionResolverJoinsDestinationWithoutDestinationOpenOrStat() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "file", kind: .regularFile),
            .init(relativePath: "folder", kind: .directory),
            .init(relativePath: "skipped", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(self, manifest: manifest)
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        active.activated.close()
        let result = Task5TestSupport.result(
            fixture,
            published: [("file", false), ("folder", true)],
            skippedPaths: ["skipped"]
        )
        try await fixture.store.markCommitted(
            transactionID: fixture.header.transactionID,
            result: result
        )
        try FileManager.default.removeItem(at: fixture.destinationURL)

        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )
        fileSystem.resetObservations()
        let resolved = try await fresh.resolveExtraction(
            for: fixture.header.operationID
        )

        XCTAssertEqual(resolved, .committed(result))
        XCTAssertTrue(fileSystem.openedDirectoryURLs().isEmpty)
        XCTAssertFalse(fileSystem.statNames().contains("file"))
        XCTAssertFalse(fileSystem.statNames().contains("folder"))
        XCTAssertFalse(fileSystem.statNames().contains("skipped"))

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildEnumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: packageRoot.appendingPathComponent(".build"),
                includingPropertiesForKeys: nil
            )
        )
        var compiledModulesDirectory: URL?
        while let candidate = buildEnumerator.nextObject() as? URL {
            if candidate.lastPathComponent == "XZIPRuntime.swiftmodule",
               candidate.deletingLastPathComponent().lastPathComponent == "Modules",
               !candidate.path.contains("/index-build/") {
                compiledModulesDirectory = candidate.deletingLastPathComponent()
                break
            }
        }
        let modulesDirectory = try XCTUnwrap(compiledModulesDirectory)
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: probeDirectory) }

        let recoveryProbe = probeDirectory.appendingPathComponent("RecoverySurfaceProbe.swift")
        try """
        import XZIPRuntime

        func probe(
            _ store: TransactionJournalStore
        ) async throws -> PersistedExtractionJournal? {
            try await store.liveTransactions().first
        }
        """.write(to: recoveryProbe, atomically: true, encoding: .utf8)
        let recoveryCompiler = Process()
        let recoveryCompilerError = Pipe()
        recoveryCompiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        recoveryCompiler.arguments = [
            "swiftc",
            "-typecheck",
            "-I",
            modulesDirectory.path,
            recoveryProbe.path,
        ]
        recoveryCompiler.standardError = recoveryCompilerError
        try recoveryCompiler.run()
        recoveryCompiler.waitUntilExit()
        let recoveryDiagnostics = String(
            data: recoveryCompilerError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertNotEqual(
            recoveryCompiler.terminationStatus,
            0,
            recoveryDiagnostics
        )
        XCTAssertTrue(
            recoveryDiagnostics.contains("PersistedExtractionJournal"),
            recoveryDiagnostics
        )
        XCTAssertTrue(
            recoveryDiagnostics.contains("liveTransactions"),
            recoveryDiagnostics
        )

        let reservationProbe = probeDirectory.appendingPathComponent(
            "ReservationSurfaceProbe.swift"
        )
        try """
        import XZIPRuntime

        func probe(
            _ reservation: TransactionRootReservation
        ) -> (TransactionNamespaceLocator, String) {
            (reservation.namespace, reservation.rootName)
        }
        """.write(to: reservationProbe, atomically: true, encoding: .utf8)
        let reservationCompiler = Process()
        let reservationCompilerError = Pipe()
        reservationCompiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        reservationCompiler.arguments = [
            "swiftc",
            "-typecheck",
            "-I",
            modulesDirectory.path,
            reservationProbe.path,
        ]
        reservationCompiler.standardError = reservationCompilerError
        try reservationCompiler.run()
        reservationCompiler.waitUntilExit()
        let reservationDiagnostics = String(
            data: reservationCompilerError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertNotEqual(
            reservationCompiler.terminationStatus,
            0,
            reservationDiagnostics
        )
        XCTAssertTrue(
            reservationDiagnostics.contains("namespace"),
            reservationDiagnostics
        )
        XCTAssertTrue(
            reservationDiagnostics.contains("rootName"),
            reservationDiagnostics
        )
    }

    func testFreshStoreMigratesCleanEmptySchemaTwoIndex() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )

        let live = try await fresh.liveTransactions()
        XCTAssertEqual(live, [])
        let migrated = try indexObject(fixture)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 3)
        XCTAssertEqual(
            try XCTUnwrap(migrated["entries"] as? [[String: Any]]).count,
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replacementTemporaryURL(fixture).path
        ))
    }

    func testFreshStoreRejectsNonemptySchemaTwoIndexWithoutMutation() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let owner = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        owner.activated.close()
        var object = try indexObject(fixture)
        object["schemaVersion"] = 2
        try replaceIndexObject(object, fixture: fixture)

        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)
        let rootURL = fixture.namespace.url.appendingPathComponent(
            owner.reservation.rootName,
            isDirectory: true
        )
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        let originalChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(root).map {
                ($0.name, $0.identity)
            }
        )
        root.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            _ = try await fresh.liveTransactions()
            XCTFail("Expected incompatible schema")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .incompatibleSchema(found: 2, expected: 3)
            )
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        let unchangedRoot = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        defer { unchangedRoot.close() }
        let unchangedChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(unchangedRoot).map {
                ($0.name, $0.identity)
            }
        )
        XCTAssertEqual(unchangedChildren, originalChildren)
    }

    func testFreshStoreRejectsEmptySchemaTwoIndexWithOrphanRootWithoutMutation()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let orphanName = UUID().uuidString
        let orphan = try fixture.fileSystem.createTransactionDirectoryExclusive(
            parent: fixture.indexDirectory,
            name: orphanName
        )
        let orphanIdentity = try fixture.fileSystem.identity(of: orphan)
        orphan.close()
        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            _ = try await fresh.liveTransactions()
            XCTFail("Expected incompatible schema")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .incompatibleSchema(found: 2, expected: 3)
            )
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: orphanName
            )?.identity,
            orphanIdentity
        )
    }

    func testFreshStoreRejectsEmptySchemaTwoIndexWithNoncanonicalReplacementTemporary()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let temporaryName = ".extraction-index.json.replacement.tmp"
        let temporaryData = Data("foreign".utf8)
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        try temporary.write(temporaryData)
        try temporary.fsync()
        temporary.close()
        let temporaryIdentity = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
        ).identity
        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            _ = try await fresh.liveTransactions()
            XCTFail("Expected incompatible schema")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .incompatibleSchema(found: 2, expected: 3)
            )
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )?.identity,
            temporaryIdentity
        )
        XCTAssertEqual(
            try Data(contentsOf: replacementTemporaryURL(fixture)),
            temporaryData
        )
    }

    func testFreshStoreRejectsIndexIdentityDriftDuringEmptySchemaTwoMigration()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let driftedIndex = try JSONSerialization.data(
            withJSONObject: [
                "entries": [["evidence": "must survive"]],
                "schemaVersion": 2,
            ],
            options: [.sortedKeys]
        )
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        fileSystem.enableSwapForwarding()
        fileSystem.replaceNodeBeforeNextIndexMutation(
            named: "extraction-index.json",
            with: driftedIndex
        )
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fresh.liveTransactions()
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.namespace.url.appendingPathComponent(
                "extraction-index.json"
            )),
            driftedIndex
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: "extraction-index.json"
            )?.identity,
            fileSystem.lastInjectedReplacementIdentity()
        )
    }

    func testFreshStoreRejectsCanonicalTemporaryDriftDuringSchemaTwoMigration()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)
        let temporaryName = ".extraction-index.json.replacement.tmp"
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        let canonical = try JSONSerialization.data(
            withJSONObject: emptyIndexObject(schemaVersion: 3),
            options: [.sortedKeys]
        )
        try temporary.write(canonical)
        try temporary.fsync()
        temporary.close()
        let driftedTemporary = Data("foreign-after-validation".utf8)
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        fileSystem.enableSwapForwarding()
        fileSystem.replaceNodeBeforeNextIndexMutation(
            named: temporaryName,
            with: driftedTemporary,
            beforeStat: true
        )
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fresh.liveTransactions()
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertEqual(
            try Data(contentsOf: replacementTemporaryURL(fixture)),
            driftedTemporary
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )?.identity,
            fileSystem.lastInjectedReplacementIdentity()
        )
    }

    func testSchemaTwoMigrationFsyncsRollbackWithCanonicalTemporary()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)
        let originalIndexIdentity = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: "extraction-index.json"
            )
        ).identity
        let temporaryName = ".extraction-index.json.replacement.tmp"
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        let canonical = try JSONSerialization.data(
            withJSONObject: emptyIndexObject(schemaVersion: 3),
            options: [.sortedKeys]
        )
        try temporary.write(canonical)
        try temporary.fsync()
        temporary.close()
        let temporaryIdentity = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
        ).identity
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        fileSystem.enableSwapForwarding()
        fileSystem.mismatchNextSwapObservation()
        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fresh.liveTransactions()
        }
        XCTAssertEqual(fileSystem.directoryFsyncCallCount(), 1)
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertEqual(
            try Data(contentsOf: replacementTemporaryURL(fixture)),
            canonical
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: "extraction-index.json"
            )?.identity,
            originalIndexIdentity
        )
        XCTAssertEqual(
            try fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )?.identity,
            temporaryIdentity
        )
    }

    func testFreshStoreResumesEmptySchemaTwoMigrationWithCanonicalTemporary()
        async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: ".extraction-index.json.replacement.tmp"
        )
        let canonical = try JSONSerialization.data(
            withJSONObject: emptyIndexObject(schemaVersion: 3),
            options: [.sortedKeys]
        )
        try temporary.write(canonical)
        try temporary.fsync()
        temporary.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )

        let live = try await fresh.liveTransactions()
        XCTAssertEqual(live, [])
        XCTAssertEqual(try indexObject(fixture)["schemaVersion"] as? Int, 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replacementTemporaryURL(fixture).path
        ))
    }

    func testInterruptedEmptySchemaTwoMigrationResumesWithFreshStore() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        try replaceIndexObject(
            emptyIndexObject(schemaVersion: 2),
            fixture: fixture
        )
        let fileSystem = JournalTestFileSystem(base: fixture.fileSystem)
        fileSystem.enableSwapForwarding()
        fileSystem.failNextReplacementBeforeMutation()
        let interrupted = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fileSystem
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await interrupted.liveTransactions()
        }
        XCTAssertEqual(try indexObject(fixture)["schemaVersion"] as? Int, 2)
        let temporaryData = try Data(contentsOf: replacementTemporaryURL(fixture))
        let canonical = try JSONSerialization.data(
            withJSONObject: emptyIndexObject(schemaVersion: 3),
            options: [.sortedKeys]
        )
        XCTAssertEqual(temporaryData, canonical)

        let freshIndexDirectory = try fixture.fileSystem
            .openTransactionOwnedDirectoryNoFollow(
                at: fixture.namespace.url,
                expected: fixture.namespace.identity
            )
        defer { freshIndexDirectory.close() }
        let fresh = TransactionJournalStore(
            indexDirectory: freshIndexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        let live = try await fresh.liveTransactions()

        XCTAssertEqual(live, [])
        XCTAssertEqual(try indexObject(fixture)["schemaVersion"] as? Int, 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replacementTemporaryURL(fixture).path
        ))
    }

    func testFreshStoreRejectsLegacySchemaWithoutMutatingLegacyRoot() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let owner = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        owner.activated.close()
        try rewriteIndexAsV1WithoutOutcomes(fixture)

        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)
        let rootURL = fixture.namespace.url.appendingPathComponent(
            owner.reservation.rootName,
            isDirectory: true
        )
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        let originalChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(root).map {
                ($0.name, $0.identity)
            }
        )
        root.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            try await ExtractionRecoveryCoordinator(
                journals: fresh,
                fileSystem: fixture.fileSystem
            ).recoverLiveTransactions()
            XCTFail("Expected incompatible legacy schema")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .incompatibleSchema(found: 1, expected: 3)
            )
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        let unchangedRoot = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        defer { unchangedRoot.close() }
        let unchangedChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(unchangedRoot).map {
                ($0.name, $0.identity)
            }
        )
        XCTAssertEqual(unchangedChildren, originalChildren)
    }

    func testFreshStoreRejectsOldHeaderSchemaBeforeAnyMutation() async throws {
        let fixture = try await Task5TestSupport.makeFixture(self)
        let owner = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        owner.activated.close()

        var object = try indexObject(fixture)
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        var header = try XCTUnwrap(entries[0]["header"] as? [String: Any])
        header["schemaVersion"] = 1
        entries[0]["header"] = header
        object["entries"] = entries
        try replaceIndexObject(object, fixture: fixture)

        let indexURL = fixture.namespace.url.appendingPathComponent(
            "extraction-index.json"
        )
        let originalIndex = try Data(contentsOf: indexURL)
        let temporaryName = ".extraction-index.json.replacement.tmp"
        let temporaryData = Data("preserve old-header evidence".utf8)
        let temporary = try fixture.fileSystem.createRegularFileExclusive(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        try temporary.write(temporaryData)
        try temporary.fsync()
        temporary.close()
        let temporaryIdentity = try XCTUnwrap(
            fixture.fileSystem.statNoFollow(
                parent: fixture.indexDirectory,
                name: temporaryName
            )
        ).identity

        let rootURL = fixture.namespace.url.appendingPathComponent(
            owner.reservation.rootName,
            isDirectory: true
        )
        let root = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        let originalChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(root).map {
                ($0.name, $0.identity)
            }
        )
        root.close()

        let fresh = TransactionJournalStore(
            indexDirectory: fixture.indexDirectory,
            indexFileName: "extraction-index.json",
            policy: Task5TestSupport.policy(maximumJournalBytes: 1_048_576),
            fileSystem: fixture.fileSystem
        )
        do {
            _ = try await fresh.liveTransactions()
            XCTFail("Expected incompatible header schema")
        } catch {
            XCTAssertEqual(
                error as? TransactionJournalError,
                .incompatibleSchema(found: 1, expected: 2)
            )
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        let temporaryAfter = try fixture.fileSystem.statNoFollow(
            parent: fixture.indexDirectory,
            name: temporaryName
        )
        XCTAssertEqual(temporaryAfter?.identity, temporaryIdentity)
        if temporaryAfter != nil {
            let temporaryURL = fixture.namespace.url.appendingPathComponent(
                temporaryName
            )
            XCTAssertEqual(try Data(contentsOf: temporaryURL), temporaryData)
        }
        let unchangedRoot = try fixture.fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: rootURL,
            expected: owner.rootIdentity
        )
        defer { unchangedRoot.close() }
        let unchangedChildren = Dictionary(
            uniqueKeysWithValues: try fixture.fileSystem.listNoFollow(unchangedRoot).map {
                ($0.name, $0.identity)
            }
        )
        XCTAssertEqual(unchangedChildren, originalChildren)
    }

    func testOutcomeRejectsAbsoluteEscapeDuplicateUnsortedOverCapAndOverflowWhileActive() async throws {
        let manifest = StagingCleanupManifest(entries: [
            .init(relativePath: "a", kind: .regularFile),
            .init(relativePath: "b", kind: .regularFile),
        ])
        let fixture = try await Task5TestSupport.makeFixture(
            self,
            manifest: manifest,
            maximumJournalBytes: 32_768
        )
        let active = try await Task5TestSupport.activateOwner(
            fixture,
            store: fixture.store,
            fileSystem: fixture.fileSystem
        )
        active.activated.close()
        var queried = URLComponents(
            url: fixture.destinationURL.appendingPathComponent("a"),
            resolvingAgainstBaseURL: false
        )!
        queried.query = "unexpected=1"
        let nonNFC = "e\u{301}"
        let invalidResults = [
            ExtractionResult(
                transactionID: fixture.header.transactionID,
                publishedURLs: [URL(fileURLWithPath: "/tmp/outside")],
                skippedPaths: []
            ),
            Task5TestSupport.result(
                fixture,
                published: [("a", false), ("a", false)]
            ),
            Task5TestSupport.result(
                fixture,
                published: [("b", false), ("a", false)]
            ),
            ExtractionResult(
                transactionID: fixture.header.transactionID,
                publishedURLs: [try XCTUnwrap(queried.url)],
                skippedPaths: []
            ),
            Task5TestSupport.result(
                fixture,
                skippedPaths: ["../escape"]
            ),
            Task5TestSupport.result(
                fixture,
                skippedPaths: [nonNFC]
            ),
            Task5TestSupport.result(
                fixture,
                published: [("a", false), ("b", false), ("c", false)]
            ),
            Task5TestSupport.result(
                fixture,
                skippedPaths: [String(repeating: "x", count: 40_000)]
            ),
            ExtractionResult(
                transactionID: TransactionID(),
                publishedURLs: [],
                skippedPaths: []
            ),
        ]

        XCTAssertThrowsError(
            try TransactionJournalStore.checkedOutcomeByteCount(
                publishedPathByteCounts: [Int.max],
                skippedPathByteCounts: [],
                cap: 32_768
            )
        )

        for invalid in invalidResults {
            await XCTAssertThrowsErrorAsync {
                try await fixture.store.markCommitted(
                    transactionID: fixture.header.transactionID,
                    result: invalid
                )
            }
            let resolution = try await fixture.store.resolution(
                for: fixture.header.operationID
            )
            XCTAssertEqual(resolution, .unfinished)
            let live = try await fixture.store.liveTransactions()
            XCTAssertEqual(live.first?.phase, .active)
        }
        let object = try indexObject(fixture)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["phase"] as? String, "active")
        XCTAssertNil(entries.first?["committedOutcome"])
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
