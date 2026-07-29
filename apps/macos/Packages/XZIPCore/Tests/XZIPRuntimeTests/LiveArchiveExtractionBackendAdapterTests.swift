import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

/// Wave 9B-1: the live `ArchiveExtractionBackend` adapter bridges the
/// Runtime-tier backend seam (ArchiveLocator + StagingCleanupManifest) onto the
/// Core-tier `ArchiveStagingExtracting` (URL + StagingWriteAuthority). These
/// tests use a recording fake staging extractor to prove the parameter mapping
/// and the manifest→authority conversion, without needing a real 7zz.
final class LiveArchiveExtractionBackendAdapterTests: XCTestCase {

    /// Records everything the adapter forwards to the Core staging extractor.
    private final class RecordingStagingExtractor: ArchiveStagingExtracting, @unchecked Sendable {
        var inventoryToReturn: ExtractionInventory
        var progressToEmit: [ArchiveProgress]
        var stagingError: Error?

        private(set) var freshArchiveURL: URL?
        private(set) var freshSelected: [String]?
        private(set) var freshPassword: String?
        private(set) var extractArchiveURL: URL?
        private(set) var extractDestination: URL?
        private(set) var extractSelected: [String]?
        private(set) var extractAuthority: StagingWriteAuthority?
        private(set) var extractPreserveTimestamps: Bool?
        private(set) var extractPassword: String?
        private let policyObservationLock = NSLock()
        private var freshPolicies: [ArchiveResourcePolicy] = []
        private var extractPolicies: [ArchiveResourcePolicy] = []
        var hangUntilCancelled = false
        var onTerminationHandler: (@Sendable (AsyncThrowingStream<ArchiveProgress, Error>.Continuation.Termination) -> Void)?

        init(
            inventory: ExtractionInventory,
            progress: [ArchiveProgress] = [],
            stagingError: Error? = nil
        ) {
            self.inventoryToReturn = inventory
            self.progressToEmit = progress
            self.stagingError = stagingError
        }

        func policyObservations() -> (
            fresh: [ArchiveResourcePolicy],
            extract: [ArchiveResourcePolicy]
        ) {
            policyObservationLock.withLock {
                (freshPolicies, extractPolicies)
            }
        }

        func freshExtractionInventory(
            archive: URL,
            selectedEntries: [String],
            password: String?,
            policy: ArchiveResourcePolicy
        ) async throws -> ExtractionInventory {
            freshArchiveURL = archive
            freshSelected = selectedEntries
            freshPassword = password
            policyObservationLock.withLock { freshPolicies.append(policy) }
            return inventoryToReturn
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
            extractArchiveURL = archive
            extractDestination = destination
            extractSelected = selectedEntries
            extractAuthority = authority
            extractPreserveTimestamps = preserveTimestamps
            extractPassword = password
            policyObservationLock.withLock { extractPolicies.append(policy) }
            let progress = progressToEmit
            let error = stagingError
            let hang = hangUntilCancelled
            let onTermination = onTerminationHandler
            return AsyncThrowingStream { continuation in
                continuation.onTermination = onTermination
                for value in progress { continuation.yield(value) }
                if hang {
                    // Leave the stream open so the consumer can cancel it; the
                    // continuation's onTermination fires on cancellation.
                    return
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func locator(_ path: String) -> ArchiveLocator {
        let identity = FileSystemIdentity.stable(
            volumeIdentifier: 1, fileIdentifier: 42, generation: nil)
        return ArchiveLocator(archiveID: ArchiveID(identity: identity),
                              url: URL(fileURLWithPath: path))
    }

    private func sampleInventory() -> ExtractionInventory {
        ExtractionInventory(
            entries: [
                ExtractionInventoryEntry(
                    path: "a/b.txt", kind: .regularFile, size: 3,
                    linkTarget: nil, isExplicitDirectory: false)
            ],
            implicitDirectories: ["a"],
            advertisedOutputByteCount: 0,
            advertisedDictionaryByteCount: 0
        )
    }

    func testFormatRouterUsesDMGOverrideAndSevenZipFallback() async throws {
        let inventory = sampleInventory()
        let fallback = RecordingStagingExtractor(inventory: inventory)
        let dmg = RecordingStagingExtractor(inventory: inventory)
        let router = FormatRoutingArchiveStagingExtractor(
            fallback: fallback,
            overrides: [.dmg: dmg]
        )
        let inventoryPolicy = ArchiveResourcePolicy.production
            .replacingForTests(stagingByteCap: 111)
        let materializationPolicy = ArchiveResourcePolicy.production
            .replacingForTests(stagingByteCap: 222)
        let dmgArchive = URL(fileURLWithPath: "/tmp/archive.dmg")
        let zipArchive = URL(fileURLWithPath: "/tmp/archive.zip")
        let authority = try StagingWriteAuthority.fromInventory(inventory)

        _ = try await router.freshExtractionInventory(
            archive: dmgArchive,
            selectedEntries: [],
            password: nil,
            policy: inventoryPolicy
        )
        _ = try await router.freshExtractionInventory(
            archive: zipArchive,
            selectedEntries: [],
            password: nil,
            policy: inventoryPolicy
        )

        try await TestSupport.drain(
            router.extractToEmptyStagingDirectory(
                archive: dmgArchive,
                destination: URL(fileURLWithPath: "/tmp/dmg-staging"),
                selectedEntries: [],
                authority: authority,
                preserveTimestamps: true,
                policy: materializationPolicy,
                password: nil
            )
        )
        try await TestSupport.drain(
            router.extractToEmptyStagingDirectory(
                archive: zipArchive,
                destination: URL(fileURLWithPath: "/tmp/zip-staging"),
                selectedEntries: [],
                authority: authority,
                preserveTimestamps: true,
                policy: materializationPolicy,
                password: nil
            )
        )

        XCTAssertEqual(dmg.freshArchiveURL, dmgArchive)
        XCTAssertEqual(fallback.freshArchiveURL, zipArchive)
        XCTAssertEqual(dmg.extractArchiveURL, dmgArchive)
        XCTAssertEqual(fallback.extractArchiveURL, zipArchive)
        XCTAssertEqual(
            dmg.policyObservations().fresh,
            [inventoryPolicy]
        )
        XCTAssertEqual(
            fallback.policyObservations().fresh,
            [inventoryPolicy]
        )
        XCTAssertEqual(
            dmg.policyObservations().extract,
            [materializationPolicy]
        )
        XCTAssertEqual(
            fallback.policyObservations().extract,
            [materializationPolicy]
        )
    }

    func testFreshExtractionInventoryForwardsArchiveURLAndArgs() async throws {
        let fake = RecordingStagingExtractor(inventory: sampleInventory())
        let adapter = LiveArchiveExtractionBackendAdapter(stagingExtractor: fake)
        let inv = try await adapter.freshExtractionInventory(
            archive: locator("/tmp/x.7z"),
            selectedEntries: ["a/b.txt"],
            password: "secret",
            policy: .production
        )
        XCTAssertEqual(fake.freshArchiveURL, URL(fileURLWithPath: "/tmp/x.7z"))
        XCTAssertEqual(fake.freshSelected, ["a/b.txt"])
        XCTAssertEqual(fake.freshPassword, "secret")
        XCTAssertEqual(inv.entries.map(\.path), ["a/b.txt"])
    }

    func testExtractConvertsCleanupManifestToAuthorityAndForwards() async throws {
        let fake = RecordingStagingExtractor(
            inventory: sampleInventory(),
            progress: [ArchiveProgress(fraction: 0.5), ArchiveProgress(fraction: 1.0)]
        )
        let adapter = LiveArchiveExtractionBackendAdapter(stagingExtractor: fake)
        let manifest = StagingCleanupManifest(entries: [
            StagingCleanupManifestEntry(relativePath: "a", kind: .directory),
            StagingCleanupManifestEntry(relativePath: "a/b.txt", kind: .regularFile),
        ])
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            stagingByteCap: 123
        )

        let stream = adapter.extractToEmptyStagingDirectory(
            archive: locator("/tmp/x.7z"),
            destination: URL(fileURLWithPath: "/tmp/staging"),
            selectedEntries: ["a/b.txt"],
            cleanupManifest: manifest,
            preserveTimestamps: true,
            policy: policy,
            password: "pw"
        )
        var fractions: [Double] = []
        for try await p in stream { if let f = p.fraction { fractions.append(f) } }

        XCTAssertEqual(fractions, [0.5, 1.0])
        XCTAssertEqual(fake.extractArchiveURL, URL(fileURLWithPath: "/tmp/x.7z"))
        XCTAssertEqual(fake.extractDestination, URL(fileURLWithPath: "/tmp/staging"))
        XCTAssertEqual(fake.extractSelected, ["a/b.txt"])
        XCTAssertEqual(fake.extractPreserveTimestamps, true)
        XCTAssertEqual(fake.extractPassword, "pw")
        XCTAssertEqual(fake.policyObservations().extract, [policy])
        // The manifest must have been converted to the equivalent authority.
        let authority = try XCTUnwrap(fake.extractAuthority)
        XCTAssertEqual(authority.authorizedPaths, ["a", "a/b.txt"])
        XCTAssertTrue(authority.isAuthorized(relativePath: "a", kind: .directory))
        XCTAssertTrue(authority.isAuthorized(relativePath: "a/b.txt", kind: .regularFile))
    }

    func testExtractPropagatesStagingError() async throws {
        struct Boom: Error {}
        let fake = RecordingStagingExtractor(
            inventory: sampleInventory(), stagingError: Boom())
        let adapter = LiveArchiveExtractionBackendAdapter(stagingExtractor: fake)
        let manifest = StagingCleanupManifest(entries: [
            StagingCleanupManifestEntry(relativePath: "a/b.txt", kind: .regularFile),
        ])
        let stream = adapter.extractToEmptyStagingDirectory(
            archive: locator("/tmp/x.7z"),
            destination: URL(fileURLWithPath: "/tmp/staging"),
            selectedEntries: [],
            cleanupManifest: manifest,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        do {
            for try await _ in stream {}
            XCTFail("Expected staging error to propagate")
        } catch is Boom {
            // expected
        }
    }

    func testExtractPreservesCancellationOfDelegatedStream() async throws {
        // The adapter returns the inner extractor's stream directly, so
        // cancelling the consumer must propagate to the inner stream's
        // onTermination (guards against a future refactor that wraps + drops it).
        let fake = RecordingStagingExtractor(inventory: sampleInventory())
        fake.hangUntilCancelled = true
        let terminated = expectation(description: "inner onTermination fires on cancel")
        fake.onTerminationHandler = { _ in terminated.fulfill() }
        let adapter = LiveArchiveExtractionBackendAdapter(stagingExtractor: fake)
        let manifest = StagingCleanupManifest(entries: [
            StagingCleanupManifestEntry(relativePath: "a/b.txt", kind: .regularFile),
        ])
        let stream = adapter.extractToEmptyStagingDirectory(
            archive: locator("/tmp/x.7z"),
            destination: URL(fileURLWithPath: "/tmp/staging"),
            selectedEntries: [],
            cleanupManifest: manifest,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        let task = Task { for try await _ in stream {} }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await fulfillment(of: [terminated], timeout: 2.0)
    }

    func testExtractSurfacesInvalidManifestAsStreamError() async throws {
        let fake = RecordingStagingExtractor(inventory: sampleInventory())
        let adapter = LiveArchiveExtractionBackendAdapter(stagingExtractor: fake)
        // An absolute path in the manifest is invalid authority input; the
        // adapter must fail the stream rather than trap.
        let manifest = StagingCleanupManifest(entries: [
            StagingCleanupManifestEntry(relativePath: "/etc/passwd", kind: .regularFile),
        ])
        let stream = adapter.extractToEmptyStagingDirectory(
            archive: locator("/tmp/x.7z"),
            destination: URL(fileURLWithPath: "/tmp/staging"),
            selectedEntries: [],
            cleanupManifest: manifest,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        do {
            for try await _ in stream {}
            XCTFail("Expected invalid manifest to fail the stream")
        } catch {
            XCTAssertNil(fake.extractAuthority,
                         "staging must not start with an invalid authority")
        }
    }
}

private enum TestSupport {
    static func drain<Element>(
        _ stream: AsyncThrowingStream<Element, Error>
    ) async throws {
        for try await _ in stream {}
    }
}
