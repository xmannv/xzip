import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime
@testable import XZip

private enum RecordingBridgeError: Error, Sendable {
    case unsupportedPolicy(ExistingFilePolicy)
}

private final class RecordingExtractionBridge:
    ExtractionBridging,
    @unchecked Sendable
{
    struct PreflightCall: Sendable {
        let destination: URL
        let policy: ExistingFilePolicy
        let password: String?
    }

    struct Execution: Sendable {
        let preflight: ExtractionPreflight
        let password: String?
        let replacementApproval: DestructiveReplacementApproval?
    }

    private let lock = NSLock()
    private let replacePreflight: ExtractionPreflight
    private let skipPreflight: ExtractionPreflight
    private let preflightGate: DestinationGate?
    private let preflightErrorWhenPasswordMissing: ArchiveEngineError?
    private let requiresPasswordForExtraction: Bool
    private var preflightCallsStorage: [PreflightCall] = []
    private var executionsStorage: [Execution] = []

    init(
        replacePreflight: ExtractionPreflight,
        skipPreflight: ExtractionPreflight,
        preflightGate: DestinationGate? = nil,
        preflightErrorWhenPasswordMissing: ArchiveEngineError? = nil,
        requiresPasswordForExtraction: Bool = false
    ) {
        self.replacePreflight = replacePreflight
        self.skipPreflight = skipPreflight
        self.preflightGate = preflightGate
        self.preflightErrorWhenPasswordMissing =
            preflightErrorWhenPasswordMissing
        self.requiresPasswordForExtraction = requiresPasswordForExtraction
    }

    var preflightCalls: [PreflightCall] {
        lock.withLock { preflightCallsStorage }
    }

    var preflightPolicies: [ExistingFilePolicy] {
        preflightCalls.map(\.policy)
    }

    var executions: [Execution] {
        lock.withLock { executionsStorage }
    }

    func preflight(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> ExtractionPreflight {
        lock.withLock {
            preflightCallsStorage.append(PreflightCall(
                destination: destination,
                policy: options.existingFilePolicy,
                password: options.password
            ))
        }
        if let preflightGate {
            await preflightGate.wait(for: destination.path)
        }
        if options.password == nil,
           let preflightErrorWhenPasswordMissing {
            throw preflightErrorWhenPasswordMissing
        }
        switch options.existingFilePolicy {
        case .replace:
            return replacePreflight
        case .skip:
            return skipPreflight
        case .keepBoth, .fail:
            throw RecordingBridgeError.unsupportedPolicy(
                options.existingFilePolicy
            )
        }
    }

    func extract(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?
    ) -> AsyncThrowingStream<Double, Error> {
        lock.withLock {
            executionsStorage.append(Execution(
                preflight: preflight,
                password: password,
                replacementApproval: replacementApproval
            ))
        }
        return AsyncThrowingStream { continuation in
            if requiresPasswordForExtraction, password == nil {
                continuation.finish(throwing: ArchiveEngineError.passwordRequired)
            } else {
                continuation.yield(1.0)
                continuation.finish()
            }
        }
    }
}

private actor DestinationGate {
    private var released: Set<String> = []
    private var waiting: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivalWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for key: String) async {
        waiting.insert(key)
        let arrivals = arrivalWaiters.removeValue(forKey: key) ?? []
        for continuation in arrivals {
            continuation.resume()
        }
        guard !released.contains(key) else { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func waitUntilWaiting(for key: String) async {
        guard !waiting.contains(key) else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        released.insert(key)
        let pending = waiters.removeValue(forKey: key) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class RecordingConflictPasswordStore:
    PasswordStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var savesStorage: [(key: String, password: String)] = []

    func save(password: String, for key: String) throws {
        lock.withLock {
            values[key] = password
            savesStorage.append((key, password))
        }
    }

    func password(for key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    func delete(for key: String) throws {
        lock.withLock { values[key] = nil }
    }

    func allKeys() throws -> [String] {
        lock.withLock { Array(values.keys) }
    }

    func seed(_ password: String, for key: String) {
        lock.withLock { values[key] = password }
    }

    var saveCount: Int {
        lock.withLock { savesStorage.count }
    }
}

final class ConflictDialogCancellationTests: XCTestCase {

    @MainActor
    private struct Fixture {
        static let existingContents = Data("do not overwrite me".utf8)

        let root: URL
        let previousConflictPolicy: Any?
        let archive: URL
        let destination: URL
        let existingFile: URL
        let engine: ConflictEngineProbe
        let replacePreflight: ExtractionPreflight
        let skipPreflight: ExtractionPreflight
        let bridge: RecordingExtractionBridge
        let router: ExtractionRouter
        let passwordStore: RecordingConflictPasswordStore
        let preflightGate: DestinationGate?

        init(
            suspendPreflights: Bool = false,
            preflightErrorWhenPasswordMissing: ArchiveEngineError? = nil,
            requiresPasswordForExtraction: Bool = false
        ) throws {
            previousConflictPolicy = UserDefaults.standard.object(
                forKey: XZIPDefaults.conflictPolicy
            )
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "conflict-cancel-\(UUID().uuidString)",
                    isDirectory: true
                )
            archive = root.appendingPathComponent("sample.zip")
            destination = root.appendingPathComponent("out", isDirectory: true)
            existingFile = destination.appendingPathComponent("folder/old.txt")
            engine = ConflictEngineProbe(entryPath: "folder/new.txt")
            try FileManager.default.createDirectory(
                at: existingFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
            try Self.existingContents.write(to: existingFile)

            let locator = ArchiveLocator(
                archiveID: ArchiveID(identity: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 2,
                    generation: 1
                )),
                url: archive
            )
            replacePreflight = Self.makePreflight(
                locator: locator,
                destination: destination,
                policy: .replace,
                destructivePaths: ["folder"],
                digestByte: 0x01
            )
            skipPreflight = Self.makePreflight(
                locator: locator,
                destination: destination,
                policy: .skip,
                destructivePaths: [],
                digestByte: 0x02
            )
            let gate = suspendPreflights ? DestinationGate() : nil
            preflightGate = gate
            let recordingBridge = RecordingExtractionBridge(
                replacePreflight: replacePreflight,
                skipPreflight: skipPreflight,
                preflightGate: gate,
                preflightErrorWhenPasswordMissing:
                    preflightErrorWhenPasswordMissing,
                requiresPasswordForExtraction:
                    requiresPasswordForExtraction
            )
            bridge = recordingBridge
            passwordStore = RecordingConflictPasswordStore()
            let stagingVolume = ExtractionRouter.volumeIdentifier(of: destination)
            router = ExtractionRouter(
                makeBridge: { recordingBridge },
                resolveStagingVolume: { stagingVolume }
            )
        }

        private static func makePreflight(
            locator: ArchiveLocator,
            destination: URL,
            policy: OperationConflictPolicy,
            destructivePaths: [String],
            digestByte: UInt8
        ) -> ExtractionPreflight {
            ExtractionPreflight(
                archive: locator,
                archiveRevision: ArchiveRevision(
                    archiveID: locator.archiveID,
                    fileSize: 4,
                    contentModificationDate: Date(timeIntervalSince1970: 100),
                    boundedContentFingerprint: Data([0xAA])
                ),
                destination: destination,
                destinationIdentity: ExtractionDestinationIdentity(
                    parent: .stable(
                        volumeIdentifier: 1,
                        fileIdentifier: 10,
                        generation: 1
                    ),
                    root: .stable(
                        volumeIdentifier: 1,
                        fileIdentifier: 11,
                        generation: 1
                    )
                ),
                selectedEntries: [],
                conflictPolicy: policy,
                preserveTimestamps: true,
                resourcePolicy: .production,
                planDigest: ExtractionPlanDigest(bytes: Data([digestByte])),
                publicationBinding: [],
                conflicts: [ExtractionConflictSummary(
                    relativePath: "folder",
                    existingByteCount: nil,
                    existingModificationDate: nil,
                    replacesDirectorySubtree: policy == .replace
                )],
                destructiveReplacementPaths: destructivePaths
            )
        }

        func makeModel(
            conflictPolicy: ConflictPolicy = .ask,
            savedPassword: String? = nil
        ) -> AppModel {
            if let savedPassword {
                passwordStore.seed(
                    savedPassword,
                    for: archive.standardizedFileURL.path
                )
            }
            UserDefaults.standard.set(
                conflictPolicy.rawValue,
                forKey: XZIPDefaults.conflictPolicy
            )
            let service = ArchiveService(
                engineFactory: SingleEngineFactory(engine: engine),
                editor: InertEditor(),
                passwordStore: passwordStore,
                presetStore: PresetStore(
                    fileURL: root.appendingPathComponent("presets.json")
                ),
                commentService: ArchiveCommentService(),
                splitJoiner: SplitArchiveJoiner()
            )
            return AppModel(service: service, extractionRouter: router)
        }

        func remove() {
            if let previousConflictPolicy {
                UserDefaults.standard.set(
                    previousConflictPolicy,
                    forKey: XZIPDefaults.conflictPolicy
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: XZIPDefaults.conflictPolicy
                )
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testCancellingRuntimePreflightLeavesSubtreeUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()

        XCTAssertEqual(fixture.bridge.preflightPolicies, [.replace])
        let prompt = try XCTUnwrap(model.pendingConflict)
        prompt.cancel()
        try await Self.settle()

        XCTAssertNil(model.pendingConflict)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: fixture.existingFile),
            Fixture.existingContents
        )
        XCTAssertNotNil(model.infoMessage)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCancellingDestructivePromptDoesNotSpendOrSaveCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        var authenticationCalls = 0
        model.authenticator = { _ in
            authenticationCalls += 1
            return true
        }
        model.presentPasswordPrompt(
            for: fixture.archive,
            validationContext: .listing
        ) {
            model.startExtraction(
                archive: fixture.archive,
                destination: fixture.destination
            )
        }

        model.passwordPromptDidSubmit("pending-secret", saveToKeychain: true)
        try await Self.settle()

        let prompt = try XCTUnwrap(model.pendingConflict)
        XCTAssertEqual(fixture.bridge.preflightCalls.count, 1)
        XCTAssertNil(fixture.bridge.preflightCalls[0].password)
        XCTAssertEqual(authenticationCalls, 0)
        XCTAssertEqual(fixture.passwordStore.saveCount, 0)

        prompt.cancel()
        try await Self.settle()

        XCTAssertTrue(fixture.bridge.executions.isEmpty)
        XCTAssertEqual(authenticationCalls, 0)
        XCTAssertEqual(fixture.passwordStore.saveCount, 0)
    }

    @MainActor
    func testDestructivePreflightThatNeedsPasswordFailsClosed() async throws {
        let fixture = try Fixture(
            preflightErrorWhenPasswordMissing: .passwordRequired
        )
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.credentials.store("must-not-be-spent", for: fixture.archive)

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()

        XCTAssertNil(fixture.bridge.preflightCalls.first?.password)
        XCTAssertNil(model.pendingConflict)
        XCTAssertNil(model.passwordPromptTarget)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testReplaceApprovalAcquiresCredentialOnlyAfterConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel(savedPassword: "approved-secret")
        model.credentials.store("approved-secret", for: fixture.archive)
        var authenticationCalls = 0
        model.authenticator = { _ in
            authenticationCalls += 1
            return true
        }

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()

        let prompt = try XCTUnwrap(model.pendingConflict)
        XCTAssertNil(fixture.bridge.preflightCalls.first?.password)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)

        prompt.resolve(.replace)
        try await Self.settle()

        let execution = try XCTUnwrap(fixture.bridge.executions.last)
        XCTAssertEqual(authenticationCalls, 1)
        XCTAssertEqual(execution.password, "approved-secret")
    }

    @MainActor
    func testDeniedPresenceDoesNotSpendSavedCredentialAfterReplaceApproval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel(savedPassword: "saved-secret")
        model.credentials.store("saved-secret", for: fixture.archive)
        var authenticationCalls = 0
        model.authenticator = { _ in
            authenticationCalls += 1
            return false
        }

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let prompt = try XCTUnwrap(model.pendingConflict)

        prompt.resolve(.replace)
        try await Self.settle()

        XCTAssertNil(fixture.bridge.preflightCalls.first?.password)
        XCTAssertEqual(authenticationCalls, 1)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
    }

    @MainActor
    func testReplaceResolutionDoesNotUseCredentialCapturedBeforePrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.credentials.store("stale-secret", for: fixture.archive)

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let prompt = try XCTUnwrap(model.pendingConflict)

        model.credentials.discard(for: fixture.archive, ifMatching: "stale-secret")
        prompt.resolve(.replace)
        try await Self.settle()

        XCTAssertNil(fixture.bridge.preflightCalls.first?.password)
        XCTAssertNil(try XCTUnwrap(fixture.bridge.executions.last).password)
    }

    @MainActor
    func testChoosingReplaceExecutesWithExactApproval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()

        let prompt = try XCTUnwrap(model.pendingConflict)
        XCTAssertEqual(prompt.destructiveDirectoryCount, 1)
        prompt.resolve(.replace)
        try await Self.settle()

        let execution = try XCTUnwrap(fixture.bridge.executions.last)
        XCTAssertEqual(execution.preflight, fixture.replacePreflight)
        XCTAssertEqual(
            execution.replacementApproval,
            fixture.replacePreflight.makeDestructiveReplacementApproval()
        )
    }

    @MainActor
    func testPasswordRetryAfterApprovalReusesExactPreflightWithoutReprompt() async throws {
        let fixture = try Fixture(requiresPasswordForExtraction: true)
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let conflictPrompt = try XCTUnwrap(model.pendingConflict)
        conflictPrompt.resolve(.replace)
        try await Self.settle()

        XCTAssertEqual(model.passwordPromptTarget, fixture.archive)
        XCTAssertEqual(fixture.bridge.preflightCalls.count, 1)
        XCTAssertEqual(fixture.bridge.executions.count, 1)
        XCTAssertNil(fixture.bridge.executions[0].password)

        model.passwordPromptDidSubmit("execution-secret")
        try await Self.settle()

        XCTAssertNil(model.pendingConflict)
        XCTAssertEqual(fixture.bridge.preflightCalls.count, 1)
        XCTAssertEqual(fixture.bridge.executions.count, 2)
        let retry = try XCTUnwrap(fixture.bridge.executions.last)
        XCTAssertEqual(retry.preflight, fixture.replacePreflight)
        XCTAssertEqual(retry.password, "execution-secret")
        XCTAssertEqual(
            retry.replacementApproval,
            fixture.replacePreflight.makeDestructiveReplacementApproval()
        )
    }

    @MainActor
    func testStoredReplacePolicyStillRequiresConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel(conflictPolicy: .replace)

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()

        XCTAssertNotNil(model.pendingConflict)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
    }

    @MainActor
    func testRepeatedReplaceResolutionExecutesOnlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let prompt = try XCTUnwrap(model.pendingConflict)

        prompt.resolve(.replace)
        prompt.resolve(.replace)
        try await Self.waitUntil { fixture.bridge.executions.count == 1 }

        XCTAssertEqual(fixture.bridge.executions.count, 1)
    }

    @MainActor
    func testStaleResolveCannotConsumeOrExecuteCurrentPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let stalePrompt = try XCTUnwrap(model.pendingConflict)

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let currentPrompt = try XCTUnwrap(model.pendingConflict)
        XCTAssertNotEqual(stalePrompt.id, currentPrompt.id)

        stalePrompt.resolve(.replace)

        XCTAssertEqual(model.pendingConflict?.id, currentPrompt.id)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
    }

    @MainActor
    func testStaleCancelCannotConsumeCurrentPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let stalePrompt = try XCTUnwrap(model.pendingConflict)

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let currentPrompt = try XCTUnwrap(model.pendingConflict)
        XCTAssertNotEqual(stalePrompt.id, currentPrompt.id)

        stalePrompt.cancel()

        XCTAssertEqual(model.pendingConflict?.id, currentPrompt.id)
        XCTAssertNil(model.infoMessage)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
    }

    @MainActor
    func testReverseOrderPreflightCompletionKeepsLatestRequestPrompt() async throws {
        let fixture = try Fixture(suspendPreflights: true)
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let newerHandled = expectation(description: "newer preflight handled")
        let olderHandled = expectation(description: "older preflight rejected")
        model.conflictPreflightDidFinish = { generation in
            switch generation {
            case 1:
                olderHandled.fulfill()
            case 2:
                newerHandled.fulfill()
            default:
                break
            }
        }
        let firstDestination = fixture.destination
        let secondDestination = fixture.root.appendingPathComponent(
            "out-second",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: secondDestination,
            withIntermediateDirectories: true
        )

        model.startExtraction(
            archive: fixture.archive,
            destination: firstDestination
        )
        model.startExtraction(
            archive: fixture.archive,
            destination: secondDestination
        )
        let gate = try XCTUnwrap(fixture.preflightGate)
        await gate.waitUntilWaiting(for: firstDestination.path)
        await gate.waitUntilWaiting(for: secondDestination.path)
        XCTAssertEqual(fixture.bridge.preflightCalls.count, 2)

        await gate.release(secondDestination.path)
        await fulfillment(of: [newerHandled], timeout: 2)
        let latestPrompt = try XCTUnwrap(model.pendingConflict)

        await gate.release(firstDestination.path)
        await fulfillment(of: [olderHandled], timeout: 2)

        XCTAssertEqual(model.pendingConflict?.id, latestPrompt.id)
        XCTAssertTrue(fixture.bridge.executions.isEmpty)
    }

    @MainActor
    func testChoosingSkipRepreflightsAndExecutesWithoutApproval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.startExtraction(
            archive: fixture.archive,
            destination: fixture.destination
        )
        try await Self.settle()
        let prompt = try XCTUnwrap(model.pendingConflict)

        prompt.resolve(.skip)
        try await Self.settle()

        XCTAssertEqual(fixture.bridge.preflightPolicies, [.replace, .skip])
        let execution = try XCTUnwrap(fixture.bridge.executions.last)
        XCTAssertEqual(execution.preflight.conflictPolicy, .skip)
        XCTAssertNil(execution.replacementApproval)
    }

    @MainActor
    private static func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

private final class ConflictEngineProbe: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<XZIPCore.ArchiveFormat> = [.zip]

    private let entryPath: String

    init(entryPath: String) {
        self.entryPath = entryPath
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] {
        [
            XZIPCore.ArchiveEntry(
                path: entryPath,
                uncompressedSize: 1,
                compressedSize: 1,
                modificationDate: nil,
                isDirectory: false,
                isEncrypted: false
            )
        ]
    }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        let entries = try await list(archive: archive, password: password)
        return ArchiveListingResult(
            entries: Array(entries.prefix(limit)),
            truncated: entries.count > limit
        )
    }

    func test(archive: URL, password: String?) async throws -> Bool { true }
}

private struct SingleEngineFactory: ArchiveEngineProviding {
    let engine: ConflictEngineProbe

    func engine(for format: XZIPCore.ArchiveFormat) throws -> any ArchiveEngine { engine }
    func engine(forArchive url: URL) throws -> any ArchiveEngine { engine }
}

private final class InertEditor: ArchiveEditing, @unchecked Sendable {
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
    func delete(entries: [String], from archive: URL, password: String?) async throws {}
    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {}
    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {}
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}
}

private struct InertPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
