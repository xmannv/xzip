import Foundation
import XCTest
import XZIPCore
import XZIPDomain
import XZIPRuntime
@testable import XZip

/// Wave 9C/9D: extraction routing through transactional destination authority.
///
/// Every detected format uses a staging extractor that enforces write
/// authority. Undetected formats remain unavailable. Password-protected
/// archives carry their credential through the transaction.
@MainActor
final class ExtractionRouterTests: XCTestCase {

    /// A destination for tests whose expected answer does not depend on which
    /// volume it is on.
    private let anyDestination = URL(fileURLWithPath: NSTemporaryDirectory())

    /// Pins the router's staging volume to `url`'s own volume, so a test that
    /// expects the transactional path does not depend on the temporary directory
    /// and Application Support happening to share a volume on the test machine.
    private func stagingVolume(matching url: URL) -> () -> (any NSObjectProtocol)? {
        { ExtractionRouter.volumeIdentifier(of: url) }
    }

    @MainActor
    private func preparedRouter() async throws -> ExtractionRouter {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: work,
            withIntermediateDirectories: true
        )
        let router = ExtractionRouter(
            makeBridge: {
                try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: stagingVolume(matching: work)
        )
        await router.prepare()
        try? FileManager.default.removeItem(at: work)
        return router
    }

    // MARK: - Routing predicate

    func testDMGUsesTransactionalPathWhenStackIsReady() async throws {
        let router = try await preparedRouter()
        XCTAssertNotNil(router.transactionalBridge(
            format: .dmg,
            hasPassword: false,
            destination: anyDestination
        ))
    }

    func testPasswordProtectedArchivesUseTheTransactionalPath() {
        // Wave 9D wires credential resolution: the bridge deposits the password
        // for the operation and the runtime's resolver withdraws it, so an
        // encrypted archive can remain on the transactional path.
        XCTAssertTrue(
            ExtractionRouter.canUseTransaction(format: .zip, hasPassword: true)
        )
        XCTAssertTrue(
            ExtractionRouter.canUseTransaction(format: .sevenZip, hasPassword: true)
        )
    }

    func testEncryptedDMGUsesTransactionalPath() {
        XCTAssertTrue(
            ExtractionRouter.canUseTransaction(format: .dmg, hasPassword: true)
        )
    }

    func testUndetectedFormatIsUnavailable() {
        // An archive whose format could not be content-detected must not bypass
        // transactional destination authority.
        XCTAssertFalse(
            ExtractionRouter.canUseTransaction(format: nil, hasPassword: false)
        )
    }

    func testEveryFormatIsEligibleWhenNoPasswordIsNeeded() {
        // Exhaustive over ArchiveFormat rather than a hand-picked list, so a
        // newly added format has to be considered here deliberately.
        for format in ArchiveFormat.allCases {
            XCTAssertTrue(
                ExtractionRouter.canUseTransaction(format: format, hasPassword: false),
                "\(format) should extract through the transactional path"
            )
            XCTAssertTrue(
                ExtractionRouter.canUseTransaction(format: format, hasPassword: true),
                "\(format) should extract through the transactional path with a password"
            )
        }
    }

    // MARK: - Startup gate

    @MainActor
    func testBridgeIsUnavailableBeforeThePrepareGateRuns() {
        // Extraction must work from launch, before the transactional stack has
        // finished assembling.
        let router = ExtractionRouter(makeBridge: { throw CancellationError() })
        XCTAssertNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: anyDestination
            )
        )
    }

    @MainActor
    func testRecoveryFailureBlocksExtractionAndRecordsTheReason() async {
        // LiveExtractionAssembly refuses to produce a runtime when durable state
        // cannot be reconciled. The router records that failure without granting
        // a backend direct final-destination authority.
        struct RecoveryFailure: Error {}
        let router = ExtractionRouter(makeBridge: { throw RecoveryFailure() })

        await router.prepare()

        XCTAssertNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: anyDestination
            ),
            "a failed gate must leave safe extraction unavailable"
        )
        XCTAssertNotNil(
            router.unavailableReason,
            "the failure reason must be recorded for diagnostics"
        )
    }

    // MARK: - Surfacing unavailable state

    /// A failed gate must reach the UI, not just the router.
    ///
    /// `unavailableReason` is published so the app explains why extraction is
    /// blocked and offers a retry.
    @MainActor
    func testFailedAssemblyPublishesAnUnavailableReasonOnTheModel() async {
        struct RecoveryFailure: Error {}
        let model = AppModel(
            extractionRouter: ExtractionRouter(makeBridge: { throw RecoveryFailure() })
        )

        await model.prepareExtraction()

        XCTAssertNotNil(
            model.extractionFallbackReason,
            "blocked extraction must be visible to the UI"
        )
    }

    @MainActor
    func testStartingExtractionRefreshesUnavailableReasonAfterSuccessfulRetry() async throws {
        struct RecoveryFailure: Error {}
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("sample.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        let attempts = Counter()
        let router = ExtractionRouter(
            makeBridge: {
                if await attempts.incrementAndGet() == 1 {
                    throw RecoveryFailure()
                }
                return try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: stagingVolume(matching: work)
        )
        let model = AppModel(extractionRouter: router)

        await model.prepareExtraction()
        XCTAssertNotNil(model.extractionFallbackReason)

        model.startExtraction(
            archive: archive,
            destination: work.appendingPathComponent("destination")
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(model.extractionFallbackReason)
    }

    /// A successful gate must leave no warning behind.
    ///
    /// The bridge is assembled against a temporary Application Support
    /// directory, like the other assembly tests here: a default `AppModel()`
    /// would build the real stack over the user's own durable state, making the
    /// result depend on whatever that state happens to be.
    @MainActor
    func testSuccessfulAssemblyPublishesNoUnavailableReason() async {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let model = AppModel(
            extractionRouter: ExtractionRouter(makeBridge: {
                try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            })
        )

        await model.prepareExtraction()

        XCTAssertNil(model.extractionFallbackReason)
    }

    /// Dismissing hides the notice without changing routing, and a later failure
    /// raises it again rather than staying silent for the rest of the session.
    @MainActor
    func testDismissingTheUnavailableNoticeDoesNotSuppressALaterFailure() async {
        struct RecoveryFailure: Error {}
        let router = ExtractionRouter(makeBridge: { throw RecoveryFailure() })
        let model = AppModel(extractionRouter: router)

        await model.prepareExtraction()
        XCTAssertNotNil(model.extractionFallbackReason)

        model.dismissExtractionFallbackNotice()
        XCTAssertNil(model.extractionFallbackReason)
        XCTAssertNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: anyDestination
            ),
            "dismissing the notice must not change how extraction is routed"
        )

        await model.prepareExtraction()
        XCTAssertNotNil(
            model.extractionFallbackReason,
            "a still-failing gate must raise the notice again"
        )
    }

    @MainActor
    func testConcurrentPrepareCallsAssembleTheStackOnlyOnce() async {
        // Assembly runs crash recovery over a shared durable namespace, so it
        // must never run twice concurrently. @MainActor alone does NOT provide
        // that: `prepare()` awaits, and two callers can both pass the
        // "already prepared?" check before either has stored a result.
        // Sequential calls cannot detect this — the calls must overlap.
        let gate = Gate()
        let counter = Counter()
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let router = ExtractionRouter(
            makeBridge: {
                await counter.increment()
                // Suspend inside assembly so a second caller can interleave.
                await gate.wait()
                return try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: stagingVolume(matching: work)
        )

        async let first: Void = router.prepare()
        async let second: Void = router.prepare()
        // Let both callers reach the suspension before releasing either.
        await Task.yield()
        await gate.open()
        _ = await (first, second)

        let assemblies = await counter.value
        XCTAssertEqual(
            assemblies, 1,
            "concurrent prepare() must not run crash recovery twice"
        )
        XCTAssertNotNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: work
            )
        )
    }

    @MainActor
    func testPrepareAssemblesTheStackOnceAndExposesTheBridge() async {
        // The gate is idempotent: reopening a window must not rebuild the stack
        // or re-run recovery.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let counter = Counter()
        let router = ExtractionRouter(
            makeBridge: {
                await counter.increment()
                return try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: stagingVolume(matching: work)
        )

        await router.prepare()
        await router.prepare()

        let assemblies = await counter.value
        XCTAssertEqual(assemblies, 1, "the gate must assemble at most once")
        XCTAssertNil(router.unavailableReason)
        XCTAssertNotNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: work
            )
        )
        XCTAssertNotNil(
            router.transactionalBridge(
                format: .dmg,
                hasPassword: false,
                destination: work
            )
        )
        XCTAssertNotNil(
            router.transactionalBridge(
                format: .dmg,
                hasPassword: true,
                destination: work
            )
        )
        // The live bridge carries credentials, so an encrypted archive is served
        // rather than becoming unavailable.
        XCTAssertNotNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: true,
                destination: work
            )
        )
    }

    // MARK: - Cross-volume routing (C8)

    /// The reason this gate exists. The journal refuses to register a transaction
    /// whose destination is on another volume. The router must reject that route
    /// before extraction starts rather than grant direct destination authority.
    ///
    /// The staging volume is injected as a value the destination cannot match, so
    /// this covers the cross-volume decision without a second volume attached.
    @MainActor
    func testDestinationOnAnotherVolumeIsUnavailable() async {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let router = ExtractionRouter(
            makeBridge: {
                try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: { NSNumber(value: Int.max) }
        )

        await router.prepare()

        XCTAssertNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: work
            ),
            "a destination on another volume must remain unavailable"
        )
        XCTAssertNil(
            router.unavailableReason,
            """
            the transactional stack is healthy; only this destination is \
            ineligible, so the startup warning must stay clear
            """
        )
    }

    /// An unresolvable staging volume must not hand out the bridge: publishing
    /// relies on staging and the destination sharing a filesystem, and that
    /// authority cannot be granted when the volume is unknown.
    @MainActor
    func testUnknownStagingVolumeIsUnavailable() async {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-router-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let router = ExtractionRouter(
            makeBridge: {
                try await LiveExtractionAssembly.liveBridge(
                    backend: ExtractionOnlyArchiveBackend(),
                    stagingExtractor: StubStagingExtractor(),
                    identityResolver: ArchiveIdentityResolver(),
                    applicationSupportDirectory: work
                )
            },
            resolveStagingVolume: { nil }
        )

        await router.prepare()

        XCTAssertNil(
            router.transactionalBridge(
                format: .zip,
                hasPassword: false,
                destination: work
            )
        )
    }

    /// Extracting into a folder that does not exist yet is the common case (the
    /// destination subfolder is created by the extraction), so the volume has to
    /// be read from the nearest existing ancestor rather than the leaf.
    func testVolumeIsResolvedFromTheNearestExistingAncestor() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xzip-absent-\(UUID().uuidString)")
            .appendingPathComponent("deeper")
            .appendingPathComponent("deeper-still")

        let resolved = ExtractionRouter.volumeIdentifier(of: missing)
        let temporary = ExtractionRouter.volumeIdentifier(
            of: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        XCTAssertNotNil(
            resolved,
            "a destination that does not exist yet must still resolve a volume"
        )
        XCTAssertEqual(
            resolved?.isEqual(temporary as Any),
            true,
            "it must resolve to the volume the path would be created on"
        )
    }

    /// A destination on the staging volume keeps the transactional path: the
    /// cross-volume gate must not have disabled the case that covers nearly every
    /// extraction.
    func testDestinationOnTheStagingVolumeIsEligible() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertTrue(
            ExtractionRouter.destinationSharesVolume(
                destination: temporary,
                stagingVolume: ExtractionRouter.volumeIdentifier(of: temporary)
            )
        )
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func incrementAndGet() -> Int {
        value += 1
        return value
    }
}

/// Lets a test hold callers at a suspension point until it chooses to release
/// them, so concurrent entry into `prepare()` is deterministic rather than
/// dependent on scheduling luck.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Staging extractor that is never invoked: these tests exercise assembly and
/// routing, not extraction itself.
private struct StubStagingExtractor: ArchiveStagingExtracting {
    struct NotUsed: Error {}

    func freshExtractionInventory(
        archive: URL,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        throw NotUsed()
    }

    func extractToEmptyStagingDirectory(
        archive: URL,
        destination: URL,
        selectedEntries: [String],
        authority: StagingWriteAuthority,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: NotUsed()) }
    }
}
