import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

/// Wave 9C: the seams that let the app call the transactional extraction stack.
///
/// The bridge's ordering contract (subscribe to progress before starting the
/// operation) is the invariant most likely to regress silently, so it is
/// asserted directly rather than inferred from observed progress.
final class TransactionalExtractionBridgeTests: XCTestCase {

    // MARK: - Fixtures

    private static func locator(_ url: URL) -> ArchiveLocator {
        ArchiveLocator(
            archiveID: ArchiveID(
                identity: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 2,
                    generation: nil
                )
            ),
            url: url
        )
    }

    private actor Recorder {
        private(set) var events: [String] = []
        private(set) var fractions: [Double] = []

        func record(_ event: String) { events.append(event) }
        func append(_ fraction: Double) { fractions.append(fraction) }
        func hasSeen(_ fraction: Double) -> Bool { fractions.contains(fraction) }
    }

    /// Somewhere for a `@Sendable` callback to leave an observation, since a
    /// captured `var` cannot be mutated from concurrent code.
    private actor Box<Value: Sendable> {
        private(set) var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ newValue: Value) { value = newValue }
    }

    /// Minimal runtime double. `onExecute` runs inside `executeOperation`, which
    /// lets a test drive progress while the operation is still in flight.
    private final class FakeRuntime: ArchiveRuntimeClient, ArchiveRuntimeObserving, ArchiveExtractionPreflighting, @unchecked Sendable {
        let recorder: Recorder
        let archiveURL: URL
        var executeError: Error?
        var capturedDescriptor: OperationDescriptor?
        var onExecute: (@Sendable (AsyncStream<OperationProgressEvent>.Continuation?) async throws -> Void)?
        var preflightResult: ExtractionPreflight?
        var preflightError: Error?
        var onPreflight: (@Sendable () async throws -> Void)?
        var preflightRequests: [ExtractionPreflightRequest] = []

        private var continuation: AsyncStream<OperationProgressEvent>.Continuation?

        init(recorder: Recorder, archiveURL: URL) {
            self.recorder = recorder
            self.archiveURL = archiveURL
        }

        func openArchive(at url: URL) async throws -> ArchiveLocator {
            await recorder.record("open")
            return TransactionalExtractionBridgeTests.locator(url)
        }

        func progress(
            for operationID: OperationID
        ) async -> AsyncStream<OperationProgressEvent> {
            await recorder.record("progress")
            let pair = AsyncStream<OperationProgressEvent>.makeStream()
            continuation = pair.continuation
            return pair.stream
        }

        func preflightExtraction(
            _ request: ExtractionPreflightRequest
        ) async throws -> ExtractionPreflight {
            await recorder.record("preflight")
            preflightRequests.append(request)
            try await onPreflight?()
            if let preflightError { throw preflightError }
            return try XCTUnwrap(preflightResult)
        }

        func executeOperation(_ descriptor: OperationDescriptor) async throws {
            await recorder.record("execute")
            capturedDescriptor = descriptor
            try await onExecute?(continuation)
            if let executeError { throw executeError }
        }

        var lastExtractionPayload: ExtractionOperationPayload? {
            guard case let .extract(payload)? = capturedDescriptor?.payload else {
                return nil
            }
            return payload
        }

        func result(for operationID: OperationID) async -> OperationResult? { nil }
        func state(for operationID: OperationID) async -> OperationState? { nil }
        func cancelOperation(_ operationID: OperationID) async {
            await recorder.record("cancel")
        }
    }

    private func makeBridge(
        _ runtime: FakeRuntime,
        credentials: EphemeralCredentialRegistry? = nil
    ) -> TransactionalExtractionBridge<FakeRuntime> {
        TransactionalExtractionBridge(runtime: runtime, credentials: credentials)
    }

    /// A destination that does not exist yet and is unique per call, so an
    /// assertion about creating it cannot pass by reusing a shared directory.
    ///
    /// Removal is registered here rather than left to each caller: this returns a
    /// path the *bridge* then creates, which is the behaviour under test, so there
    /// is nothing at this point for a `defer` to delete and it is easy to assume
    /// none is needed. Every caller used to leak a directory per run.
    private func freshDestination() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-bridge-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makePreflight(
        archive: URL,
        destination: URL,
        policy: OperationConflictPolicy = .replace,
        destructivePaths: [String] = ["folder"],
        selectedEntries: [String] = ["folder/file.txt"]
    ) -> ExtractionPreflight {
        let locator = Self.locator(archive)
        return ExtractionPreflight(
            archive: locator,
            archiveRevision: ArchiveRevision(
                archiveID: locator.archiveID,
                fileSize: 7,
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
            selectedEntries: selectedEntries,
            conflictPolicy: policy,
            preserveTimestamps: true,
            resourcePolicy: .production,
            planDigest: ExtractionPlanDigest(bytes: Data([0x01])),
            publicationBinding: [
                ExtractionPublicationBindingEntry(
                    originalPath: "folder/file.txt",
                    expectedIdentity: nil,
                    decision: .keepBoth(finalPath: "folder/file 2.txt")
                )
            ],
            conflicts: destructivePaths.map {
                ExtractionConflictSummary(
                    relativePath: $0,
                    existingByteCount: nil,
                    existingModificationDate: nil,
                    replacesDirectorySubtree: true
                )
            },
            destructiveReplacementPaths: destructivePaths
        )
    }

    private func drain(
        _ stream: AsyncThrowingStream<Double, Error>,
        into recorder: Recorder
    ) async throws {
        for try await fraction in stream {
            await recorder.append(fraction)
        }
    }

    private func approvedStream(
        runtime: FakeRuntime,
        bridge: TransactionalExtractionBridge<FakeRuntime>,
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> AsyncThrowingStream<Double, Error> {
        runtime.preflightResult = makePreflight(
            archive: archive,
            destination: destination,
            policy: TransactionalExtractionBridge<FakeRuntime>.conflictPolicy(
                for: options.existingFilePolicy
            ),
            destructivePaths: [],
            selectedEntries: options.selectedEntries
        )
        let preflight = try await bridge.preflight(
            archive: archive,
            destination: destination,
            options: options
        )
        return bridge.extract(
            preflight: preflight,
            password: options.password,
            replacementApproval: nil
        )
    }

    // MARK: - Policy mapping

    func testConflictPolicyMappingIsExhaustiveAndOrderPreserving() {
        typealias Bridge = TransactionalExtractionBridge<FakeRuntime>
        XCTAssertEqual(Bridge.conflictPolicy(for: .replace), .replace)
        XCTAssertEqual(Bridge.conflictPolicy(for: .keepBoth), .keepBoth)
        XCTAssertEqual(Bridge.conflictPolicy(for: .skip), .skip)
        XCTAssertEqual(Bridge.conflictPolicy(for: .fail), .fail)
    }

    // MARK: - Two-phase extraction

    func testPreflightForwardsConcretePolicyAndReturnsNoPassword() async throws {
        let recorder = Recorder()
        let archive = URL(fileURLWithPath: "/tmp/a.7z")
        let destination = freshDestination()
        let runtime = FakeRuntime(recorder: recorder, archiveURL: archive)
        runtime.preflightResult = makePreflight(
            archive: archive,
            destination: destination
        )
        let credentials = EphemeralCredentialRegistry()
        let bridge = makeBridge(runtime, credentials: credentials)
        var options = ExtractionOptions()
        options.password = "secret"
        options.selectedEntries = ["folder/file.txt"]
        options.existingFilePolicy = .replace

        let preflight = try await bridge.preflight(
            archive: archive,
            destination: destination,
            options: options
        )

        let request = try XCTUnwrap(runtime.preflightRequests.last)
        XCTAssertEqual(request.selectedEntries, ["folder/file.txt"])
        XCTAssertEqual(request.conflictPolicy, .replace)
        XCTAssertFalse(String(describing: preflight).contains("secret"))
        let remainingCredentials = await credentials.count
        XCTAssertEqual(remainingCredentials, 0)
    }

    func testApprovedExecutionCarriesExactPreflightBindingAndNewOperationID() async throws {
        let recorder = Recorder()
        let archive = URL(fileURLWithPath: "/tmp/a.7z")
        let destination = freshDestination()
        let runtime = FakeRuntime(recorder: recorder, archiveURL: archive)
        runtime.preflightResult = makePreflight(
            archive: archive,
            destination: destination
        )
        let bridge = makeBridge(runtime)
        var options = ExtractionOptions()
        options.existingFilePolicy = .replace
        let preflight = try await bridge.preflight(
            archive: archive,
            destination: destination,
            options: options
        )
        let preflightOperationID = try XCTUnwrap(
            runtime.preflightRequests.last?.operationID
        )
        let approval = preflight.makeDestructiveReplacementApproval()

        for try await _ in bridge.extract(
            preflight: preflight,
            password: nil,
            replacementApproval: approval
        ) {}

        let payload = try XCTUnwrap(runtime.lastExtractionPayload)
        let executionOperationID = try XCTUnwrap(
            runtime.capturedDescriptor?.operationID
        )
        XCTAssertNotEqual(executionOperationID, preflightOperationID)
        XCTAssertEqual(payload.expectedArchiveRevision, preflight.archiveRevision)
        XCTAssertEqual(payload.expectedDestinationIdentity, preflight.destinationIdentity)
        XCTAssertEqual(payload.planDigest, preflight.planDigest)
        XCTAssertEqual(payload.publicationBinding, preflight.publicationBinding)
        XCTAssertEqual(payload.replacementApproval, approval)
    }

    func testApprovedExecutionRequiresReplacementApproval() async throws {
        let recorder = Recorder()
        let archive = URL(fileURLWithPath: "/tmp/a.7z")
        let destination = freshDestination()
        let runtime = FakeRuntime(recorder: recorder, archiveURL: archive)
        let preflight = makePreflight(
            archive: archive,
            destination: destination
        )

        do {
            for try await _ in makeBridge(runtime).extract(
                preflight: preflight,
                password: nil,
                replacementApproval: nil
            ) {}
            XCTFail("expected destructive replacement approval to be required")
        } catch ArchiveFailure.destructiveReplacementApprovalRequired {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertNil(runtime.capturedDescriptor)
    }

    // MARK: - Ordering

    func testProgressIsRegisteredBeforeOperationStarts() async throws {
        // The observation store buffers only the newest event and finishes a
        // late subscriber immediately, so subscribing after the operation began
        // could yield a stream that never reports anything.
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let destination = URL(fileURLWithPath: "/tmp/dest")
        let bridge = makeBridge(runtime)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: ExtractionOptions()
            ),
            into: recorder
        )

        let events = await recorder.events
        XCTAssertEqual(events, ["open", "preflight", "progress", "execute"])
    }

    // MARK: - Destination creation

    func testExtractCreatesAMissingDestinationDirectory() async throws {
        // The app's default destination is a subfolder named after the archive,
        // which does not exist yet. The legacy engine path gets this for free
        // from `7zz -o`, but ExtractionTransaction opens the destination without
        // O_CREAT and has no directory-creation authority — so the bridge has to
        // make up the difference or the common "Extract" flow fails outright.
        //
        // Uses a unique path rather than the shared `/tmp/dest` the other tests
        // pass, because a pre-existing directory would make this pass for free.
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-bridge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        let bridge = makeBridge(runtime)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: ExtractionOptions()
            ),
            into: recorder
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            ),
            "the bridge must create the destination before extracting"
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPreflightRejectsSymlinkParentWithoutCreatingThroughIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        let destination = link
            .appendingPathComponent("created", isDirectory: true)
            .appendingPathComponent("destination", isDirectory: true)
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: root.appendingPathComponent("archive.7z")
        )
        let bridge = makeBridge(runtime)

        await XCTAssertThrowsErrorAsync {
            _ = try await bridge.preflight(
                archive: runtime.archiveURL,
                destination: destination,
                options: ExtractionOptions()
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("created").path
            )
        )
        XCTAssertTrue(runtime.preflightRequests.isEmpty)
    }

    // MARK: - Progress translation

    func testInFlightProgressEventsReachTheStream() async throws {
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        // Yield a fraction while the operation is still running and do not
        // return until the consumer observed it, so the assertion cannot race.
        runtime.onExecute = { continuation in
            continuation?.yield(.archive(ArchiveProgress(fraction: 0.5)))
            for _ in 0..<1_000 {
                if await recorder.hasSeen(0.5) { return }
                await Task.yield()
            }
        }

        let destination = URL(fileURLWithPath: "/tmp/dest")
        let bridge = makeBridge(runtime)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: ExtractionOptions()
            ),
            into: recorder
        )

        let fractions = await recorder.fractions
        XCTAssertTrue(fractions.contains(0.5), "in-flight progress must be forwarded")
        XCTAssertEqual(fractions.last, 1.0, "a completed extraction must end at 1.0")
    }

    func testIndeterminateProgressIsNotForwardedAsAFraction() async throws {
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        runtime.onExecute = { continuation in
            continuation?.yield(.archive(.indeterminate))
            await Task.yield()
        }

        let destination = URL(fileURLWithPath: "/tmp/dest")
        let bridge = makeBridge(runtime)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: ExtractionOptions()
            ),
            into: recorder
        )

        // Only the terminal 1.0 — an indeterminate event carries no fraction.
        let fractions = await recorder.fractions
        XCTAssertEqual(fractions, [1.0])
    }

    // MARK: - Request translation

    func testRequestCarriesDestinationSelectionAndPolicy() async throws {
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let destination = URL(fileURLWithPath: "/tmp/dest")

        let options = ExtractionOptions(
            selectedEntries: ["only/this.txt"],
            existingFilePolicy: .skip
        )
        let bridge = makeBridge(runtime)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: options
            ),
            into: recorder
        )

        guard case let .extract(payload)? = runtime.capturedDescriptor?.payload else {
            return XCTFail("expected an extract payload")
        }
        XCTAssertEqual(payload.destination.url, destination)
        XCTAssertEqual(payload.selectedEntryPaths, ["only/this.txt"])
        XCTAssertEqual(payload.conflictPolicy, .skip)
    }

    // MARK: - Failure semantics

    func testPasswordWithoutACredentialSeamIsRefusedWithoutStartingTheOperation() async {
        // A bridge built without a registry has nowhere to put the password, and
        // extracting anyway would drop it and fail confusingly partway through.
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )

        do {
            _ = try await makeBridge(runtime).preflight(
                archive: runtime.archiveURL,
                destination: freshDestination(),
                options: ExtractionOptions(password: "secret")
            )
            XCTFail("expected a credentials-unavailable refusal")
        } catch TransactionalExtractionUnsupported.credentialsUnavailable {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let events = await recorder.events
        XCTAssertFalse(events.contains("execute"), "the operation must not start")
        XCTAssertNil(runtime.capturedDescriptor)
    }

    // MARK: - Credential handoff

    func testPasswordIsDepositedForTheOperationBeingExtracted() async throws {
        // The credential cannot ride along inside the request, so the bridge
        // deposits it against the operation's ID for the runtime's resolver to
        // withdraw. This fake runtime has no handler, so nothing withdraws it and
        // the deposit itself is observable mid-flight.
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let credentials = EphemeralCredentialRegistry()
        let observed = Box<String?>(nil)
        runtime.onExecute = { _ in
            // Read it from inside the operation: afterwards the bridge clears it.
            guard let descriptor = runtime.capturedDescriptor,
                  let sessionID = descriptor.sessionID,
                  let archiveID = descriptor.archiveID
            else { return }
            let value = try? await credentials.resolveExtractionCredential(
                sessionID: sessionID,
                operationID: descriptor.operationID,
                archiveID: archiveID
            )
            await observed.set(value)
        }

        let destination = freshDestination()
        let options = ExtractionOptions(password: "secret")
        let bridge = makeBridge(runtime, credentials: credentials)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: options
            ),
            into: recorder
        )

        let resolved = await observed.value
        XCTAssertEqual(
            resolved, "secret",
            "the resolver must find the password under the operation's own ID"
        )
        // Withdrawal removes, so "at most once" holds without the caller policing it.
        let remaining = await credentials.count
        XCTAssertEqual(remaining, 0)
    }

    func testAFailedOperationLeavesNoCredentialBehind() async {
        // The resolver only withdraws once the operation reaches the handler, so
        // anything that fails earlier would otherwise park the secret in the
        // registry for the rest of the process.
        struct Boom: Error {}
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        runtime.executeError = Boom()
        let credentials = EphemeralCredentialRegistry()

        let destination = freshDestination()
        let options = ExtractionOptions(password: "secret")
        let bridge = makeBridge(runtime, credentials: credentials)
        do {
            try await drain(
                try await approvedStream(
                    runtime: runtime,
                    bridge: bridge,
                    archive: runtime.archiveURL,
                    destination: destination,
                    options: options
                ),
                into: recorder
            )
            XCTFail("expected the operation to fail")
        } catch {
            // expected
        }

        let remaining = await credentials.count
        XCTAssertEqual(
            remaining, 0,
            "a failed operation must not leave its credential in the registry"
        )
    }

    func testASuccessfulOperationLeavesNoCredentialBehind() async throws {
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let credentials = EphemeralCredentialRegistry()

        let destination = freshDestination()
        let options = ExtractionOptions(password: "secret")
        let bridge = makeBridge(runtime, credentials: credentials)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: options
            ),
            into: recorder
        )

        let remaining = await credentials.count
        XCTAssertEqual(remaining, 0)
    }

    func testNoCredentialIsStoredWhenTheArchiveNeedsNoPassword() async throws {
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        let credentials = EphemeralCredentialRegistry()
        let observedDuringOperation = Box(-1)
        runtime.onExecute = { _ in
            await observedDuringOperation.set(await credentials.count)
        }

        let destination = freshDestination()
        let options = ExtractionOptions()
        let bridge = makeBridge(runtime, credentials: credentials)
        try await drain(
            try await approvedStream(
                runtime: runtime,
                bridge: bridge,
                archive: runtime.archiveURL,
                destination: destination,
                options: options
            ),
            into: recorder
        )

        let held = await observedDuringOperation.value
        XCTAssertEqual(
            held, 0,
            "a passwordless extraction must not deposit anything"
        )
    }

    func testOperationFailurePropagatesToTheStream() async {
        struct Boom: Error, Equatable {}
        let recorder = Recorder()
        let runtime = FakeRuntime(
            recorder: recorder,
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z")
        )
        runtime.executeError = Boom()

        let destination = URL(fileURLWithPath: "/tmp/dest")
        let options = ExtractionOptions()
        let bridge = makeBridge(runtime)
        do {
            try await drain(
                try await approvedStream(
                    runtime: runtime,
                    bridge: bridge,
                    archive: runtime.archiveURL,
                    destination: destination,
                    options: options
                ),
                into: recorder
            )
            XCTFail("expected the operation failure to surface")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let fractions = await recorder.fractions
        XCTAssertFalse(fractions.contains(1.0), "a failed extraction must not report completion")
    }

    private enum CredentialPhase: CaseIterable, Equatable {
        case preflight
        case execution
    }

    private enum CredentialOutcome: CaseIterable, Equatable {
        case success
        case failure
        case cancellation
    }

    private struct BridgeFailure: Error, Sendable {}

    private struct StartSignal: Sendable {
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation

        init() {
            let pair = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            stream = pair.stream
            continuation = pair.continuation
        }

        func markStarted() {
            continuation.yield(())
        }

        func waitUntilStarted() async {
            for await _ in stream { return }
        }
    }

    private actor ManualGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    func testExecutionControllerCancellationWaitsForOperationUnwind() async {
        let recorder = Recorder()
        let started = StartSignal()
        let cancellationCallerReady = StartSignal()
        let cancellationObserved = StartSignal()
        let invokeCancellation = ManualGate()
        let releaseUnwind = ManualGate()
        let controller = ExtractionExecutionController {
            await recorder.record("operation-started")
            started.markStarted()
            await withTaskCancellationHandler {
                await releaseUnwind.wait()
            } onCancel: {
                cancellationObserved.markStarted()
            }
            await recorder.record("cancellation-observed")
            await recorder.record("operation-unwound")
        }

        await controller.start()
        await started.waitUntilStarted()
        let cancellation = Task {
            cancellationCallerReady.markStarted()
            await invokeCancellation.wait()
            await controller.cancelAndWait()
            await recorder.record("cancel-returned")
        }
        await cancellationCallerReady.waitUntilStarted()
        cancellation.cancel()
        await invokeCancellation.open()
        await cancellationObserved.waitUntilStarted()
        await releaseUnwind.open()
        await cancellation.value

        let events = await recorder.events
        XCTAssertEqual(
            events,
            [
                "operation-started",
                "cancellation-observed",
                "operation-unwound",
                "cancel-returned",
            ]
        )
    }

    func testCredentialRegistryIsEmptyAcrossEveryTerminalPath() async throws {
        for phase in CredentialPhase.allCases {
            for outcome in CredentialOutcome.allCases {
                try await assertCredentialCleanup(phase: phase, outcome: outcome)
            }
        }
    }

    func testExecutionCancellationBeforeDepositCannotLeaveCredentialBehind() async throws {
        let recorder = Recorder()
        let archive = URL(fileURLWithPath: "/tmp/a.7z")
        let destination = freshDestination()
        let runtime = FakeRuntime(recorder: recorder, archiveURL: archive)
        let credentials = EphemeralCredentialRegistry()
        let bridge = makeBridge(runtime, credentials: credentials)
        let preflight = makePreflight(
            archive: archive,
            destination: destination,
            policy: .skip,
            destructivePaths: []
        )

        for _ in 0..<100 {
            let task = Task {
                for try await _ in bridge.extract(
                    preflight: preflight,
                    password: "secret",
                    replacementApproval: nil
                ) {}
                try Task.checkCancellation()
            }
            task.cancel()
            _ = await task.result
        }

        let remainingCredentials = await credentials.count
        XCTAssertEqual(remainingCredentials, 0)
    }

    private func assertCredentialCleanup(
        phase: CredentialPhase,
        outcome: CredentialOutcome
    ) async throws {
        let recorder = Recorder()
        let archive = URL(fileURLWithPath: "/tmp/a.7z")
        let destination = freshDestination()
        let runtime = FakeRuntime(recorder: recorder, archiveURL: archive)
        runtime.preflightResult = makePreflight(
            archive: archive,
            destination: destination,
            destructivePaths: []
        )
        let credentials = EphemeralCredentialRegistry()
        let bridge = makeBridge(runtime, credentials: credentials)
        let started = StartSignal()

        switch phase {
        case .preflight:
            if outcome == .failure {
                runtime.preflightError = BridgeFailure()
            } else if outcome == .cancellation {
                runtime.onPreflight = {
                    started.markStarted()
                    try await Task.sleep(for: .seconds(60))
                }
            }
            var options = ExtractionOptions(password: "secret")
            options.existingFilePolicy = .skip
            let task = Task {
                try await bridge.preflight(
                    archive: archive,
                    destination: destination,
                    options: options
                )
            }
            if outcome == .cancellation {
                await started.waitUntilStarted()
                task.cancel()
            }
            do {
                _ = try await task.value
                XCTAssertEqual(outcome, .success)
            } catch {
                XCTAssertNotEqual(outcome, .success)
            }

        case .execution:
            var options = ExtractionOptions()
            options.existingFilePolicy = .skip
            let preflight = try await bridge.preflight(
                archive: archive,
                destination: destination,
                options: options
            )
            if outcome == .failure {
                runtime.executeError = BridgeFailure()
            } else if outcome == .cancellation {
                runtime.onExecute = { _ in
                    started.markStarted()
                    try await Task.sleep(for: .seconds(60))
                }
            }
            let task = Task {
                for try await _ in bridge.extract(
                    preflight: preflight,
                    password: "secret",
                    replacementApproval: nil
                ) {}
                try Task.checkCancellation()
            }
            if outcome == .cancellation {
                await started.waitUntilStarted()
                task.cancel()
            }
            do {
                try await task.value
                XCTAssertEqual(outcome, .success)
            } catch {
                XCTAssertNotEqual(outcome, .success)
            }
        }

        let remainingCredentials = await credentials.count
        XCTAssertEqual(
            remainingCredentials,
            0,
            "credential leak in \(phase)/\(outcome)"
        )
    }
}

/// Wave 9C: the extraction-only backend exists solely to satisfy
/// `ArchiveRuntime`'s requirement. Every member is unreachable in production, so
/// the contract under test is that misuse is reported rather than crashing or
/// silently succeeding.
final class ExtractionOnlyArchiveBackendTests: XCTestCase {

    private let backend = ExtractionOnlyArchiveBackend()
    private let archive = URL(fileURLWithPath: "/tmp/a.7z")

    private func assertMisuse(
        _ expression: () async throws -> Void,
        _ operation: String
    ) async {
        do {
            try await expression()
            XCTFail("\(operation) must not silently succeed")
        } catch let error as ExtractionOnlyBackendMisuse {
            XCTAssertEqual(error.operation, operation)
            XCTAssertTrue(
                error.description.contains(operation),
                "the diagnostic must name the offending operation"
            )
        } catch {
            XCTFail("\(operation): unexpected error \(error)")
        }
    }

    func testExtractionIsRefusedBecauseTheRuntimeDispatchesItToTheHandler() async {
        await assertMisuse({
            _ = try self.backend.extract(
                archive: self.archive,
                destination: URL(fileURLWithPath: "/tmp/dest"),
                options: ExtractionOptions()
            )
        }, "extract")
    }

    func testNonExtractionOperationsReportMisuse() async {
        await assertMisuse({ _ = try await self.backend.readComment(for: self.archive) },
                          "readComment")
        await assertMisuse({ try await self.backend.writeComment("x", to: self.archive) },
                          "writeComment")
        await assertMisuse({ _ = try self.backend.detectSplit(part: self.archive) },
                          "detectSplit")
        await assertMisuse({
            _ = try self.backend.compress(
                sources: [], destination: self.archive,
                options: CompressionOptions(format: .sevenZip, level: .fast)
            )
        }, "compress")
        await assertMisuse({ _ = try await self.backend.list(archive: self.archive, password: nil) },
                          "list")
        await assertMisuse({ _ = try await self.backend.test(archive: self.archive, password: nil) },
                          "test")
        await assertMisuse({
            try await self.backend.delete(entries: ["a"], from: self.archive, password: nil)
        }, "delete")
    }

    func testJoinSplitFailsThroughItsStreamRatherThanCrashing() async {
        // joinSplit cannot throw synchronously, so the misuse has to arrive
        // through the stream.
        do {
            for try await _ in backend.joinSplit(parts: [archive], destination: archive) {}
            XCTFail("joinSplit must not silently succeed")
        } catch let error as ExtractionOnlyBackendMisuse {
            XCTAssertEqual(error.operation, "joinSplit")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonThrowingCapabilityChecksFailClosed() {
        // These cannot report misuse, so they answer conservatively instead of
        // claiming a capability the backend does not have.
        XCTAssertFalse(backend.canEditComment(for: archive))
        XCTAssertNil(backend.detectedFormat(for: archive))
    }
}
