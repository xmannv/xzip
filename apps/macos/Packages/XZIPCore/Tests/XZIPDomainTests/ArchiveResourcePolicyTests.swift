import Foundation
import XCTest
@testable import XZIPDomain

final class ArchiveResourcePolicyTests: XCTestCase {
    func testProductionPolicyLocksExactBudgets() {
        let policy = ArchiveResourcePolicy.production

        XCTAssertEqual(policy.listing, .init(
            browserEntryCap: 100_000,
            listingHardCap: 1_000_000,
            totalPathByteCap: 64 * 1_024 * 1_024,
            maximumPathByteCount: 32 * 1_024,
            maximumPathDepth: 256
        ))
        let tebibyte: UInt64 = 1_024 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(policy.output, ArchiveResourcePolicy.Output(
            advertisedOutputByteCap: tebibyte,
            advertisedDictionaryByteCap: 4 * 1_024 * 1_024 * 1_024,
            stagingByteCap: tebibyte
        ))
        XCTAssertEqual(policy.process, .init(
            stdoutBufferByteCap: 4 * 1_024 * 1_024,
            stderrTailByteCap: 1 * 1_024 * 1_024,
            rawChunkByteCap: 256 * 1_024,
            progressEventBufferCount: 1,
            progressInterval: 0.1,
            terminationGracePeriod: 2
        ))
        XCTAssertEqual(policy.cache, .init(weightBudget: 128 * 1_024 * 1_024))
        XCTAssertEqual(policy.split, .init(
            maximumSuffixWidth: 6,
            maximumPartIndex: 999_999,
            maximumPartCount: 10_000
        ))
        XCTAssertEqual(policy.command, .init(
            maximumPathCount: 256,
            maximumRequestBytes: 1 * 1_024 * 1_024,
            maximumPendingRequestCount: 256,
            maximumPullCount: 32,
            replayWindow: 10 * 60,
            longPollTimeout: 20
        ))
        XCTAssertEqual(policy.journal, .init(
            maximumJournalBytes: 16 * 1_024 * 1_024,
            retention: 7 * 24 * 60 * 60,
            maximumRecoveryCountPerLaunch: 32,
            maximumPruneCountPerPass: 64
        ))
        XCTAssertEqual(policy.scheduling, .init(
            globalProcessLimit: 4,
            metadataProcessLimit: 2,
            heavyIOPerVolumeLimit: 1
        ))
    }

    func testTinyPolicyRoundTripsThroughCodable() throws {
        let tiny = ArchiveResourcePolicy.production.replacingForTests(
            browserEntryCap: 2,
            listingHardCap: 3,
            totalPathByteCap: 8,
            cacheWeightBudget: 16,
            splitMaximumSuffixWidth: 3,
            splitMaximumPartIndex: 999,
            splitMaximumPartCount: 2,
            commandMaximumPathCount: 2,
            commandMaximumRequestBytes: 512,
            commandMaximumPendingRequestCount: 2,
            commandMaximumPullCount: 1,
            commandReplayWindow: 5,
            commandLongPollTimeout: 0.1
        )

        let encoded = try JSONEncoder().encode(tiny)
        let decoded = try JSONDecoder().decode(ArchiveResourcePolicy.self, from: encoded)

        XCTAssertEqual(decoded, tiny)
        XCTAssertEqual(decoded.listing.browserEntryCap, 2)
        XCTAssertEqual(decoded.listing.listingHardCap, 3)
        XCTAssertEqual(decoded.listing.totalPathByteCap, 8)
        XCTAssertEqual(decoded.cache.weightBudget, 16)
        XCTAssertEqual(decoded.split.maximumPartCount, 2)
        XCTAssertEqual(decoded.command.maximumRequestBytes, 512)
        XCTAssertEqual(decoded.command.maximumPullCount, 1)
    }
}
