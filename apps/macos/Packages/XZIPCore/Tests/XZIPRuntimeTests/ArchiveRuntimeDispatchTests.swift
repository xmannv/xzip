import Darwin
import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

private enum BackendProbeError: Error {
    case unexpectedCall
}

private final class BackendProbe: ArchiveBackend, @unchecked Sendable {
    typealias ListHandler = @Sendable (URL, String?) async throws -> [ArchiveEntry]
    typealias DeleteHandler = @Sendable (URL, [String], String?) async throws -> Void
    typealias CompressHandler = @Sendable (
        [URL], URL, CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error>
    typealias ExtractHandler = @Sendable (
        URL, URL, ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error>
    typealias DetectFormatHandler = @Sendable (URL) -> ArchiveFormat?

    private let listHandler: ListHandler
    private let deleteHandler: DeleteHandler
    private let compressHandler: CompressHandler
    private let extractHandler: ExtractHandler
    private let detectFormatHandler: DetectFormatHandler

    init(
        list: @escaping ListHandler = { _, _ in [] },
        delete: @escaping DeleteHandler = { _, _, _ in },
        compress: @escaping CompressHandler = { _, _, _ in
            AsyncThrowingStream { continuation in continuation.finish() }
        },
        extract: @escaping ExtractHandler = { _, _, _ in
            AsyncThrowingStream { continuation in continuation.finish() }
        },
        detectedFormat: @escaping DetectFormatHandler = { _ in nil }
    ) {
        self.listHandler = list
        self.deleteHandler = delete
        self.compressHandler = compress
        self.extractHandler = extract
        self.detectFormatHandler = detectedFormat
    }

    func readComment(for archive: URL) async throws -> String {
        throw BackendProbeError.unexpectedCall
    }

    func writeComment(_ comment: String, to archive: URL) async throws {
        throw BackendProbeError.unexpectedCall
    }

    func canEditComment(for archive: URL) -> Bool { false }

    func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult? {
        throw BackendProbeError.unexpectedCall
    }

    func joinSplit(
        parts: [URL],
        destination: URL
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: BackendProbeError.unexpectedCall)
        }
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        try compressHandler(sources, destination, options)
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        try extractHandler(archive, destination, options)
    }

    func detectedFormat(for archive: URL) -> ArchiveFormat? {
        detectFormatHandler(archive)
    }

    func list(archive: URL, password: String?) async throws -> [ArchiveEntry] {
        try await listHandler(archive, password)
    }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        let entries = try await listHandler(archive, password)
        return ArchiveListingResult(
            entries: Array(entries.prefix(limit)),
            truncated: entries.count > limit
        )
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        throw BackendProbeError.unexpectedCall
    }

    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {
        throw BackendProbeError.unexpectedCall
    }

    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        throw BackendProbeError.unexpectedCall
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {
        try await deleteHandler(archive, entries, password)
    }

    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        throw BackendProbeError.unexpectedCall
    }

    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {
        throw BackendProbeError.unexpectedCall
    }
}

private actor AsyncTestSignal {
    private var signalCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        signalCount += 1
        let ready = waiters.filter { $0.0 <= signalCount }
        waiters.removeAll { $0.0 <= signalCount }
        ready.forEach { $0.1.resume() }
    }

    func wait(until target: Int) async {
        if signalCount >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func currentCount() -> Int { signalCount }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ControlledDoubleStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Double, Error>.Continuation?

    func makeStream() -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func yield(_ value: Double) {
        lock.withLock { continuation }?.yield(value)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func increment() -> Int {
        let (result, ready) = lock.withLock {
            storage += 1
            let ready = waiters.filter { $0.0 <= storage }.map(\.1)
            waiters.removeAll { $0.0 <= storage }
            return (storage, ready)
        }
        ready.forEach { $0.resume() }
        return result
    }

    func wait(until target: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard storage < target else { return true }
                waiters.append((target, continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    var value: Int { lock.withLock { storage } }
}


private final class LockedExistingFilePolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ExistingFilePolicy?

    var value: ExistingFilePolicy? {
        lock.withLock { storage }
    }

    func set(_ value: ExistingFilePolicy) {
        lock.withLock { storage = value }
    }
}


private final class LockedFileSystemIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FileSystemIdentity?

    var value: FileSystemIdentity? {
        lock.withLock { storage }
    }

    func set(_ value: FileSystemIdentity?) {
        lock.withLock { storage = value }
    }
}

private func stableIdentity(for url: URL) throws -> FileSystemIdentity {
    var info = stat()
    let result = url.path.withCString { Darwin.lstat($0, &info) }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return .stable(
        volumeIdentifier: UInt64(UInt32(bitPattern: info.st_dev)),
        fileIdentifier: UInt64(info.st_ino),
        generation: info.st_gen == 0 ? nil : UInt64(info.st_gen)
    )
}

private func destinationKey(for url: URL) throws -> DestinationLeaseKey {
    DestinationLeaseKey(
        parentIdentity: try stableIdentity(for: url.deletingLastPathComponent()),
        // Shares the production canonicalizer on purpose. This helper used to
        // re-implement it, which meant the tests would keep agreeing with
        // themselves after production drifted away from them.
        normalizedName: FileSystemNameCanonicalization.key(
            component: url.lastPathComponent
        )
    )
}

private func waitUntilQueued(
    _ expected: Int,
    archiveID: ArchiveID,
    registry: ArchiveLeaseRegistry
) async {
    for _ in 0..<10_000 {
        if await registry.queuedWaiterCountForTesting(archiveID: archiveID) == expected {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(expected) queued archive waiters")
}

private func waitUntilQueued(
    _ expected: Int,
    destination: DestinationLeaseKey,
    registry: ArchiveLeaseRegistry
) async {
    for _ in 0..<10_000 {
        if await registry.queuedWaiterCountForTesting(destination: destination) == expected {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(expected) queued destination waiters")
}

private func archiveEntry(_ path: String) -> ArchiveEntry {
    ArchiveEntry(
        path: path,
        uncompressedSize: 1,
        compressedSize: 1,
        modificationDate: nil,
        isDirectory: false,
        isEncrypted: false
    )
}

final class ArchiveRuntimeDispatchTests: XCTestCase {
    func testExtractionApprovalRoundTripsWithoutCredentialMaterial() throws {
        let destinationIdentity = ExtractionDestinationIdentity(
            parent: .stable(
                volumeIdentifier: 1,
                fileIdentifier: 2,
                generation: 3
            ),
            root: .stable(
                volumeIdentifier: 1,
                fileIdentifier: 4,
                generation: 5
            )
        )
        let revision = ArchiveRevision(
            archiveID: ArchiveID(identity: .stable(
                volumeIdentifier: 1,
                fileIdentifier: 6,
                generation: 7
            )),
            fileSize: 99,
            contentModificationDate: Date(timeIntervalSince1970: 123),
            boundedContentFingerprint: Data([0xAA, 0xBB])
        )
        let publicationBinding = [ExtractionPublicationBindingEntry(
            originalPath: "folder/file.txt",
            expectedIdentity: ExtractionPublicationNodeIdentity(
                device: 1,
                inode: 8,
                generation: 9,
                kindRawValue: "regularFile"
            ),
            decision: .replace
        )]
        let approval = DestructiveReplacementApproval(
            archiveRevision: revision,
            destinationIdentity: destinationIdentity,
            conflictPolicy: .replace,
            planDigest: ExtractionPlanDigest(bytes: Data([0x01, 0x02])),
            publicationBinding: publicationBinding
        )
        let payload = ExtractionOperationPayload(
            archive: .init(
                identity: revision.archiveID.identity,
                url: URL(fileURLWithPath: "/tmp/a.zip")
            ),
            destination: .init(
                identity: destinationIdentity.root,
                url: URL(fileURLWithPath: "/tmp/out")
            ),
            selectedEntryPaths: ["folder/file.txt"],
            conflictPolicy: .replace,
            preserveTimestamps: true,
            expectedArchiveRevision: revision,
            expectedDestinationIdentity: destinationIdentity,
            planDigest: approval.planDigest,
            publicationBinding: publicationBinding,
            replacementApproval: approval
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            ExtractionOperationPayload.self,
            from: encoded
        )

        XCTAssertEqual(decoded, payload)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
    }

    private func makeArchiveURL(named name: String = "archive.zip") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRuntimeDispatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data("archive".utf8).write(to: url)
        return url
    }

    private func makeRuntime(
        backend: any ArchiveBackend,
        leases: ArchiveLeaseRegistry = ArchiveLeaseRegistry()
    ) -> ArchiveRuntime {
        let production = ArchiveResourcePolicy.production
        let leaseFocusedPolicy = ArchiveResourcePolicy(
            listing: production.listing,
            output: production.output,
            process: production.process,
            cache: production.cache,
            split: production.split,
            command: production.command,
            journal: production.journal,
            scheduling: .init(
                globalProcessLimit: production.scheduling.globalProcessLimit,
                metadataProcessLimit: production.scheduling.metadataProcessLimit,
                heavyIOPerVolumeLimit: 2
            )
        )
        return ArchiveRuntime(
            backend: backend,
            identityResolver: ArchiveIdentityResolver(),
            policy: leaseFocusedPolicy,
            leases: leases
        )
    }

    private func operationDescriptor(
        archiveID: ArchiveID? = nil,
        payload: OperationPayload,
        title: String
    ) -> OperationDescriptor {
        OperationDescriptor(
            archiveID: archiveID,
            payload: payload,
            resourcePolicy: .production,
            ui: .init(title: title)
        )
    }

    func testExecuteOperationAllowsReadersAndQueuesWriterUntilBothFinish() async throws {
        let archive = try makeArchiveURL()
        let readersEntered = AsyncTestSignal()
        let releaseReaders = AsyncTestGate()
        let writerEntered = AsyncTestSignal()
        let backend = BackendProbe(
            list: { _, _ in
                await readersEntered.signal()
                await releaseReaders.wait()
                return []
            },
            delete: { _, _, _ in await writerEntered.signal() }
        )
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let locator = try await runtime.openArchive(at: archive)
        let reference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: archive
        )
        let firstDescriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .list(.init(archive: reference)),
            title: "List first"
        )
        let secondDescriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .list(.init(archive: reference)),
            title: "List second"
        )
        let writerDescriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .delete(.init(archive: reference, entryPaths: ["old.txt"])),
            title: "Delete"
        )

        let first = Task { try await runtime.executeOperation(firstDescriptor) }
        let second = Task { try await runtime.executeOperation(secondDescriptor) }
        await readersEntered.wait(until: 2)
        let writer = Task { try await runtime.executeOperation(writerDescriptor) }
        await waitUntilQueued(1, archiveID: locator.archiveID, registry: leases)
        let beforeRelease = await writerEntered.currentCount()
        XCTAssertEqual(beforeRelease, 0)

        await releaseReaders.open()
        try await first.value
        try await second.value
        try await writer.value
        let afterRelease = await writerEntered.currentCount()
        XCTAssertEqual(afterRelease, 1)
    }

    func testExecuteOperationLeaseLivesUntilBackendStreamFinishes() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let destination = source.deletingLastPathComponent().appendingPathComponent("output.zip")
        let firstStream = ControlledDoubleStream()
        let calls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            if calls.increment() == 1 { return firstStream.makeStream() }
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let key = try destinationKey(for: destination)
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )
        let firstDescriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress first"
        )
        let secondDescriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress second"
        )

        let first = Task { try await runtime.executeOperation(firstDescriptor) }
        await calls.wait(until: 1)
        let competing = Task { try await runtime.executeOperation(secondDescriptor) }
        await waitUntilQueued(1, destination: key, registry: leases)
        XCTAssertEqual(calls.value, 1)

        firstStream.finish()
        try await first.value
        try await competing.value
        XCTAssertEqual(calls.value, 2)
    }

    /// R2: two destination names that the filesystem treats as one file must take
    /// the same lease, so the second operation waits instead of writing
    /// concurrently.
    ///
    /// Verified on APFS: `straße.zip` and `strasse.zip` resolve to a single
    /// inode, because the volume applies full Unicode case folding rather than
    /// plain lowercasing. The lease key used to be built with `lowercased()`,
    /// which leaves those two names distinct, so the registry handed out two
    /// concurrent leases for one file and both operations wrote it at once.
    func testDestinationsFoldedTogetherByTheFilesystemShareOneLease() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let directory = source.deletingLastPathComponent()
        let first = directory.appendingPathComponent("straße.zip")
        // Same file as `first` as far as the filesystem is concerned.
        let second = directory.appendingPathComponent("strasse.zip")

        let firstStream = ControlledDoubleStream()
        let calls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            if calls.increment() == 1 { return firstStream.makeStream() }
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)

        // Descriptors are built up front, outside the tasks: capturing a local
        // helper that produces them would make the closures non-sending.
        let firstPayload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: first),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )
        let secondPayload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: second),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )
        let firstDescriptor = operationDescriptor(
            payload: .compress(firstPayload),
            title: "Compress first"
        )
        let secondDescriptor = operationDescriptor(
            payload: .compress(secondPayload),
            title: "Compress second"
        )

        let firstTask = Task { try await runtime.executeOperation(firstDescriptor) }
        await calls.wait(until: 1)
        let competing = Task { try await runtime.executeOperation(secondDescriptor) }

        // Both spellings must map to one key, so the second operation queues.
        let key = try destinationKey(for: first)
        XCTAssertEqual(key, try destinationKey(for: second))
        await waitUntilQueued(1, destination: key, registry: leases)
        XCTAssertEqual(
            calls.value, 1,
            "second write to the same underlying file must not start while the first holds the lease"
        )

        firstStream.finish()
        try await firstTask.value
        try await competing.value
        XCTAssertEqual(calls.value, 2)
    }

    func testExecuteOperationCancellationReleasesLease() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let destination = source.deletingLastPathComponent().appendingPathComponent("output.zip")
        let firstStream = ControlledDoubleStream()
        let calls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            if calls.increment() == 1 { return firstStream.makeStream() }
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let key = try destinationKey(for: destination)
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )
        let firstDescriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress first"
        )
        let secondDescriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress second"
        )

        let first = Task { try await runtime.executeOperation(firstDescriptor) }
        await calls.wait(until: 1)
        let competing = Task { try await runtime.executeOperation(secondDescriptor) }
        await waitUntilQueued(1, destination: key, registry: leases)
        XCTAssertEqual(calls.value, 1)

        first.cancel()
        do {
            try await first.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        try await competing.value
        XCTAssertEqual(calls.value, 2)
    }


    func testDestinationArchiveAliasQueuesBehindArchiveReaderAndInvalidatesCache() async throws {
        let archive = try makeArchiveURL()
        let source = try makeArchiveURL(named: "source.txt")
        let listCalls = LockedInt()
        let compressCalls = LockedInt()
        let backend = BackendProbe(
            list: { _, _ in
                _ = listCalls.increment()
                return [archiveEntry("cached.txt")]
            },
            compress: { _, _, _ in
                _ = compressCalls.increment()
                return AsyncThrowingStream { $0.finish() }
            }
        )
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let locator = try await runtime.openArchive(at: archive)
        let archiveReference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: archive
        )
        let listDescriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .list(.init(archive: archiveReference)),
            title: "List"
        )
        try await runtime.executeOperation(listDescriptor)
        XCTAssertEqual(listCalls.value, 1)

        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await leases.withLeases(archive: (locator.archiveID, .read), destination: nil) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: archiveReference,
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .replace
        )
        let descriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Replace archive"
        )
        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await waitUntilQueued(1, archiveID: locator.archiveID, registry: leases)
        XCTAssertEqual(compressCalls.value, 0)

        await releaseBlocker.open()
        try await blocker.value
        try await operation.value
        XCTAssertEqual(compressCalls.value, 1)

        let refreshedListDescriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .list(.init(archive: archiveReference)),
            title: "Refreshed list"
        )
        try await runtime.executeOperation(refreshedListDescriptor)
        XCTAssertEqual(listCalls.value, 2)
    }

    func testDestinationParentReplacementWhileQueuedFailsBeforeBackendCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRuntimeParentReplacement-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let destination = parent.appendingPathComponent("output.zip")
        let key = try destinationKey(for: destination)
        let compressCalls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            _ = compressCalls.increment()
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await leases.withLeases(archive: nil, destination: key) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .replace
        )
        let descriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress"
        )
        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await waitUntilQueued(1, destination: key, registry: leases)

        try FileManager.default.moveItem(
            at: parent,
            to: root.appendingPathComponent("old-parent", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await releaseBlocker.open()
        try await blocker.value

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(compressCalls.value, 0)
    }


    func testExistingDestinationReplacementWhileQueuedFailsBeforeBackendCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRuntimeDestinationReplacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("output.zip")
        let replacement = root.appendingPathComponent("replacement.zip")
        try Data("source".utf8).write(to: source)
        try Data("destination-a".utf8).write(to: destination)
        try Data("destination-b".utf8).write(to: replacement)
        let originalIdentity = try stableIdentity(for: destination)
        let key = try destinationKey(for: destination)

        let compressCalls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            _ = compressCalls.increment()
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await leases.withLeases(archive: nil, destination: key) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .replace
        )
        let descriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress"
        )
        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await waitUntilQueued(1, destination: key, registry: leases)

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        XCTAssertNotEqual(try stableIdentity(for: destination), originalIdentity)
        await releaseBlocker.open()
        try await blocker.value

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(compressCalls.value, 0)
    }

    func testSourceIdentityReplacementWhileQueuedFailsBeforeBackendCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRuntimeSourceReplacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("old".utf8).write(to: source)
        let sourceIdentity = try stableIdentity(for: source)
        let destination = root.appendingPathComponent("output.zip")
        let key = try destinationKey(for: destination)
        let compressCalls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            _ = compressCalls.increment()
            return AsyncThrowingStream { $0.finish() }
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await leases.withLeases(archive: nil, destination: key) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let payload = CompressionOperationPayload(
            sources: [.init(identity: sourceIdentity, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .replace
        )
        let descriptor = operationDescriptor(
            payload: .compress(payload),
            title: "Compress"
        )
        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await waitUntilQueued(1, destination: key, registry: leases)

        try FileManager.default.moveItem(
            at: source,
            to: root.appendingPathComponent("old-source.txt")
        )
        try Data("new".utf8).write(to: source)
        await releaseBlocker.open()
        try await blocker.value

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(compressCalls.value, 0)
    }

    func testAskConflictPolicyIsRejectedBeforeBackendCall() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let destination = source.deletingLastPathComponent().appendingPathComponent("output.zip")
        let compressCalls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            _ = compressCalls.increment()
            return AsyncThrowingStream { $0.finish() }
        })
        let runtime = makeRuntime(backend: backend)
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .ask
        )

        do {
            try await runtime.executeOperation(operationDescriptor(
                payload: .compress(payload),
                title: "Ask"
            ))
            XCTFail("Expected unresolved conflict policy")
        } catch ArchiveFailure.unresolvedConflictPolicy {}
        XCTAssertEqual(compressCalls.value, 0)
    }

    func testFailCompressionRejectsExistingDestinationBeforeBackendCall() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let destination = source.deletingLastPathComponent().appendingPathComponent("output.zip")
        try Data("existing".utf8).write(to: destination)
        let compressCalls = LockedInt()
        let backend = BackendProbe(compress: { _, _, _ in
            _ = compressCalls.increment()
            return AsyncThrowingStream { $0.finish() }
        })
        let runtime = makeRuntime(backend: backend)
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: try stableIdentity(for: destination), url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )

        do {
            try await runtime.executeOperation(operationDescriptor(
                payload: .compress(payload),
                title: "Fail"
            ))
            XCTFail("Expected destination conflict")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: destination.path))
        }
        XCTAssertEqual(compressCalls.value, 0)
    }


    func testFailCompressionPassesPolicyToBackendWhenDestinationIsAbsent() async throws {
        let source = try makeArchiveURL(named: "source.txt")
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent("new-output.zip")
        let expectedParentIdentity = try destinationKey(for: destination).parentIdentity
        let receivedPolicy = LockedExistingFilePolicy()
        let receivedParentIdentity = LockedFileSystemIdentity()
        let backend = BackendProbe(compress: { _, _, options in
            receivedPolicy.set(options.existingFilePolicy)
            receivedParentIdentity.set(options.destinationParentIdentity)
            return AsyncThrowingStream { $0.finish() }
        })
        let runtime = makeRuntime(backend: backend)
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: source)],
            destination: .init(identity: nil, url: destination),
            formatIdentifier: ArchiveFormat.zip.rawValue,
            compressionLevel: CompressionLevel.normal.rawValue,
            encryptFileNames: false,
            volumeSizeBytes: nil,
            exclusionPatterns: [],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )

        try await runtime.executeOperation(operationDescriptor(
            payload: .compress(payload),
            title: "Fail"
        ))

        XCTAssertEqual(receivedPolicy.value, .fail)
        XCTAssertEqual(receivedParentIdentity.value, expectedParentIdentity)
    }


    func testOpenOperationHoldsArchiveReadLeaseAgainstWriter() async throws {
        let archive = try makeArchiveURL()
        let detectCalls = LockedInt()
        let backend = BackendProbe(detectedFormat: { _ in
            _ = detectCalls.increment()
            return .zip
        })
        let leases = ArchiveLeaseRegistry()
        let runtime = makeRuntime(backend: backend, leases: leases)
        let locator = try await runtime.openArchive(at: archive)
        let reference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: archive
        )
        let blockerEntered = AsyncTestSignal()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await leases.withLeases(archive: (locator.archiveID, .write), destination: nil) {
                await blockerEntered.signal()
                await releaseBlocker.wait()
            }
        }
        await blockerEntered.wait(until: 1)

        let descriptor = operationDescriptor(
            archiveID: locator.archiveID,
            payload: .open(.init(archive: reference)),
            title: "Open"
        )
        let operation = Task {
            try await runtime.executeOperation(descriptor)
        }
        await waitUntilQueued(1, archiveID: locator.archiveID, registry: leases)
        XCTAssertEqual(detectCalls.value, 0)

        await releaseBlocker.open()
        try await blocker.value
        try await operation.value
        XCTAssertEqual(detectCalls.value, 1)
    }


    func testCreateParentPathIsValidatedBeforeWorkspaceAllocation() async throws {
        let archive = try makeArchiveURL()
        let workspaceCalls = LockedInt()
        let backend = BackendProbe()
        let runtime = ArchiveRuntime(
            backend: backend,
            identityResolver: ArchiveIdentityResolver(),
            replacementWorkspaceProvider: { _ in
                _ = workspaceCalls.increment()
                return FileManager.default.temporaryDirectory
            }
        )
        let locator = try await runtime.openArchive(at: archive)
        let reference = OperationResourceReference(
            identity: locator.archiveID.identity,
            url: archive
        )
        let payload = CreateEntryOperationPayload(
            archive: reference,
            parentPath: "../escape",
            name: "new.txt",
            kind: .file
        )

        do {
            try await runtime.executeOperation(operationDescriptor(
                archiveID: locator.archiveID,
                payload: .create(payload),
                title: "Create"
            ))
            XCTFail("Expected invalid parent path")
        } catch is ArchiveNameValidationError {}
        XCTAssertEqual(workspaceCalls.value, 0)
    }
}
