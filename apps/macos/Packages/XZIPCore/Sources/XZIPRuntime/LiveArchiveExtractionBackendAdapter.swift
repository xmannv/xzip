import Foundation
import XZIPCore
import XZIPDomain

/// Live `ArchiveExtractionBackend` that bridges the Runtime-tier backend seam
/// onto the Core-tier `ArchiveStagingExtracting` (Wave 9A).
///
/// The two contracts differ deliberately: the backend receives an
/// `ArchiveLocator` and the durable `StagingCleanupManifest`, whereas the Core
/// staging extractor receives a plain `URL` and a `StagingWriteAuthority`. This
/// adapter performs exactly that translation — mapping `ArchiveLocator.url` and
/// converting the manifest into the equivalent authority via
/// `StagingWriteAuthority.fromAuthorizedEntries` — then delegates to the
/// authority-enforcing Core extractor. It never reuses the plain,
/// non-authority `ArchiveEngine.extract`: the transaction's write authority is
/// carried through end to end.
///
/// The manifest is the transaction's own `makeManifest` output (built from the
/// same inventory this adapter returns from `freshExtractionInventory`), so the
/// converted authority matches what the transaction validates against.
public struct LiveArchiveExtractionBackendAdapter: ArchiveExtractionBackend {
    private let stagingExtractor: any ArchiveStagingExtracting

    public init(stagingExtractor: any ArchiveStagingExtracting) {
        self.stagingExtractor = stagingExtractor
    }

    public func freshExtractionInventory(
        archive: ArchiveLocator,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        try await stagingExtractor.freshExtractionInventory(
            archive: archive.url,
            selectedEntries: selectedEntries,
            password: password,
            policy: policy
        )
    }

    public func extractToEmptyStagingDirectory(
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        cleanupManifest: StagingCleanupManifest,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        // Convert the durable cleanup manifest into the Core write authority.
        // A malformed manifest (absolute/traversal/empty component) must fail
        // the stream rather than trap, and must not begin any staging write.
        let authority: StagingWriteAuthority
        do {
            authority = try StagingWriteAuthority.fromAuthorizedEntries(
                cleanupManifest.entries.map {
                    StagingWriteAuthority.Entry(relativePath: $0.relativePath, kind: $0.kind)
                }
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return stagingExtractor.extractToEmptyStagingDirectory(
            archive: archive.url,
            destination: destination,
            selectedEntries: selectedEntries,
            authority: authority,
            preserveTimestamps: preserveTimestamps,
            policy: policy,
            password: password
        )
    }
}

public struct FormatRoutingArchiveStagingExtractor: ArchiveStagingExtracting {
    private let fallback: any ArchiveStagingExtracting
    private let overrides: [ArchiveFormat: any ArchiveStagingExtracting]

    public init(
        fallback: any ArchiveStagingExtracting,
        overrides: [ArchiveFormat: any ArchiveStagingExtracting]
    ) {
        self.fallback = fallback
        self.overrides = overrides
    }

    private func extractor(for archive: URL) -> any ArchiveStagingExtracting {
        guard let format = ArchiveFormat.infer(
            fromFilename: archive.lastPathComponent
        ) else {
            return fallback
        }
        return overrides[format] ?? fallback
    }

    public func freshExtractionInventory(
        archive: URL,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        try await extractor(for: archive).freshExtractionInventory(
            archive: archive,
            selectedEntries: selectedEntries,
            password: password,
            policy: policy
        )
    }

    public func extractToEmptyStagingDirectory(
        archive: URL,
        destination: URL,
        selectedEntries: [String],
        authority: StagingWriteAuthority,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        extractor(for: archive).extractToEmptyStagingDirectory(
            archive: archive,
            destination: destination,
            selectedEntries: selectedEntries,
            authority: authority,
            preserveTimestamps: preserveTimestamps,
            policy: policy,
            password: password
        )
    }
}
