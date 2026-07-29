import Foundation
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

private func makeCacheKey(_ fileID: UInt64 = 1) -> CompatibilityArchiveCache.CacheKey {
    let archiveID = ArchiveID(identity: .stable(
        volumeIdentifier: 1,
        fileIdentifier: fileID,
        generation: 1
    ))
    return .init(
        archiveID: archiveID,
        revision: ArchiveRevision(
            archiveID: archiveID,
            fileSize: 4,
            contentModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            boundedContentFingerprint: Data("AAAA".utf8)
        )
    )
}

private func cacheEntry(_ path: String) -> ArchiveEntry {
    ArchiveEntry(
        path: path,
        uncompressedSize: 1,
        compressedSize: 1,
        modificationDate: nil,
        isDirectory: false,
        isEncrypted: false
    )
}

final class ArchiveRuntimeCacheTests: XCTestCase {
    func testMutationInvalidatesListingAndFormatWithUnchangedRevision() async {
        let cache = CompatibilityArchiveCache()
        let key = makeCacheKey()
        let token = await cache.beginLoad(for: key)
        await cache.storeListing([cacheEntry("before")], token: token)
        await cache.storeFormat(.zip, token: token)

        await cache.invalidate(archiveID: key.archiveID)

        let listing = await cache.cachedListing(for: key)
        let format = await cache.cachedFormat(for: key)
        XCTAssertNil(listing)
        XCTAssertNil(format)
    }

    func testMutationRejectsListingThatStartedBeforeInvalidation() async {
        let cache = CompatibilityArchiveCache()
        let key = makeCacheKey()
        let staleToken = await cache.beginLoad(for: key)

        await cache.invalidate(archiveID: key.archiveID)
        await cache.storeListing([cacheEntry("stale")], token: staleToken)

        let listing = await cache.cachedListing(for: key)
        XCTAssertNil(listing)
    }

    func testOlderRefreshCannotOverwriteNewerListing() async {
        let cache = CompatibilityArchiveCache()
        let key = makeCacheKey()
        let older = await cache.beginLoad(for: key)
        let newer = await cache.beginLoad(for: key)

        await cache.storeListing([cacheEntry("new")], token: newer)
        await cache.storeListing([cacheEntry("old")], token: older)

        let listing = await cache.cachedListing(for: key)
        XCTAssertEqual(listing, [cacheEntry("new")])
    }

    func testOlderFormatDetectionCannotOverwriteNewerResult() async {
        let cache = CompatibilityArchiveCache()
        let key = makeCacheKey()
        let older = await cache.beginLoad(for: key)
        let newer = await cache.beginLoad(for: key)

        await cache.storeFormat(.sevenZip, token: newer)
        await cache.storeFormat(.zip, token: older)

        let format = await cache.cachedFormat(for: key)
        XCTAssertEqual(format, .sevenZip)
    }


    func testTerminalLoadPurgesMetadataWithoutEvictingCachedValues() async {
        let cache = CompatibilityArchiveCache()
        let key = makeCacheKey()
        let token = await cache.beginLoad(for: key)
        await cache.storeListing([cacheEntry("cached")], token: token)
        await cache.storeFormat(.zip, token: token)

        await cache.finishLoad(token)

        let activeLoads = await cache.activeLoadCountForTesting()
        let latestLoads = await cache.latestLoadCountForTesting()
        let generations = await cache.mutationGenerationCountForTesting()
        let listing = await cache.cachedListing(for: key)
        let format = await cache.cachedFormat(for: key)
        XCTAssertEqual(activeLoads, 0)
        XCTAssertEqual(latestLoads, 0)
        XCTAssertEqual(generations, 0)
        XCTAssertEqual(listing, [cacheEntry("cached")])
        XCTAssertEqual(format, .zip)
    }

    func testActiveLoadMetadataIsBoundedAndRetiredTokensStayRejected() async {
        let cache = CompatibilityArchiveCache(metadataCapacity: 2)
        let firstKey = makeCacheKey(10)
        let secondKey = makeCacheKey(11)
        let thirdKey = makeCacheKey(12)
        let first = await cache.beginLoad(for: firstKey)
        _ = await cache.beginLoad(for: secondKey)
        let third = await cache.beginLoad(for: thirdKey)

        let activeLoads = await cache.activeLoadCountForTesting()
        let latestLoads = await cache.latestLoadCountForTesting()
        XCTAssertEqual(activeLoads, 2)
        XCTAssertEqual(latestLoads, 2)

        await cache.storeListing([cacheEntry("retired")], token: first)
        await cache.storeListing([cacheEntry("current")], token: third)
        await cache.finishLoad(third)
        let retiredListing = await cache.cachedListing(for: firstKey)
        let currentListing = await cache.cachedListing(for: thirdKey)
        XCTAssertNil(retiredListing)
        XCTAssertEqual(currentListing, [cacheEntry("current")])
    }

    func testLoadSequenceOverflowRetiresInflightTokensBeforeReset() async {
        let cache = CompatibilityArchiveCache(
            metadataCapacity: 4,
            initialLoadSequence: UInt64.max - 1
        )
        let key = makeCacheKey()
        let stale = await cache.beginLoad(for: key)
        let current = await cache.beginLoad(for: key)

        await cache.storeListing([cacheEntry("stale")], token: stale)
        await cache.storeListing([cacheEntry("current")], token: current)
        await cache.finishLoad(current)

        let listing = await cache.cachedListing(for: key)
        let activeLoads = await cache.activeLoadCountForTesting()
        let latestLoads = await cache.latestLoadCountForTesting()
        XCTAssertEqual(listing, [cacheEntry("current")])
        XCTAssertEqual(activeLoads, 0)
        XCTAssertEqual(latestLoads, 0)
    }


    func testLoadEpochOverflowDisablesNewCacheStoresFailClosed() async {
        let cache = CompatibilityArchiveCache(
            initialLoadSequence: UInt64.max,
            initialLoadEpoch: UInt64.max
        )
        let key = makeCacheKey()
        let token = await cache.beginLoad(for: key)

        await cache.storeListing([cacheEntry("rejected")], token: token)
        await cache.finishLoad(token)

        let listing = await cache.cachedListing(for: key)
        let activeLoads = await cache.activeLoadCountForTesting()
        let latestLoads = await cache.latestLoadCountForTesting()
        XCTAssertNil(listing)
        XCTAssertEqual(activeLoads, 0)
        XCTAssertEqual(latestLoads, 0)
    }

    func testMutationGenerationOverflowRejectsInflightToken() async {
        let cache = CompatibilityArchiveCache(
            initialMutationGeneration: UInt64.max
        )
        let key = makeCacheKey()
        let stale = await cache.beginLoad(for: key)

        await cache.invalidate(archiveID: key.archiveID)
        await cache.storeListing([cacheEntry("stale")], token: stale)

        let listing = await cache.cachedListing(for: key)
        let activeLoads = await cache.activeLoadCountForTesting()
        let latestLoads = await cache.latestLoadCountForTesting()
        let generations = await cache.mutationGenerationCountForTesting()
        XCTAssertNil(listing)
        XCTAssertEqual(activeLoads, 0)
        XCTAssertEqual(latestLoads, 0)
        XCTAssertEqual(generations, 0)
    }

    func testAccessSequenceOverflowPreservesDeterministicCachedValue() async {
        let cache = CompatibilityArchiveCache(initialAccessSequence: UInt64.max)
        let key = makeCacheKey()
        let token = await cache.beginLoad(for: key)

        await cache.storeListing([cacheEntry("cached")], token: token)
        await cache.finishLoad(token)

        let listing = await cache.cachedListing(for: key)
        XCTAssertEqual(listing, [cacheEntry("cached")])
    }


    func testListingCapacityEvictsDeterministicOldestEntry() async {
        let cache = CompatibilityArchiveCache(
            listingCapacity: 2,
            listingWeightBudget: 10_000
        )
        let first = makeCacheKey(1)
        let second = makeCacheKey(2)
        let third = makeCacheKey(3)

        let firstToken = await cache.beginLoad(for: first)
        await cache.storeListing([cacheEntry("first")], token: firstToken)
        await cache.finishLoad(firstToken)
        let secondToken = await cache.beginLoad(for: second)
        await cache.storeListing([cacheEntry("second")], token: secondToken)
        await cache.finishLoad(secondToken)
        _ = await cache.cachedListing(for: first)
        let thirdToken = await cache.beginLoad(for: third)
        await cache.storeListing([cacheEntry("third")], token: thirdToken)
        await cache.finishLoad(thirdToken)

        let retainedFirst = await cache.cachedListing(for: first)
        let evictedSecond = await cache.cachedListing(for: second)
        let retainedThird = await cache.cachedListing(for: third)
        XCTAssertEqual(retainedFirst, [cacheEntry("first")])
        XCTAssertNil(evictedSecond)
        XCTAssertEqual(retainedThird, [cacheEntry("third")])
    }

    func testFormatCapacityEvictsDeterministicOldestEntry() async {
        let cache = CompatibilityArchiveCache(formatCapacity: 2)
        let first = makeCacheKey(1)
        let second = makeCacheKey(2)
        let third = makeCacheKey(3)

        let firstToken = await cache.beginLoad(for: first)
        await cache.storeFormat(.zip, token: firstToken)
        await cache.finishLoad(firstToken)
        let secondToken = await cache.beginLoad(for: second)
        await cache.storeFormat(.sevenZip, token: secondToken)
        await cache.finishLoad(secondToken)
        _ = await cache.cachedFormat(for: first)
        let thirdToken = await cache.beginLoad(for: third)
        await cache.storeFormat(.tar, token: thirdToken)
        await cache.finishLoad(thirdToken)

        let retainedFirst = await cache.cachedFormat(for: first)
        let evictedSecond = await cache.cachedFormat(for: second)
        let retainedThird = await cache.cachedFormat(for: third)
        XCTAssertEqual(retainedFirst, .zip)
        XCTAssertNil(evictedSecond)
        XCTAssertEqual(retainedThird, .tar)
    }

    func testListingWeightBudgetEvictsDeterministicOldestEntry() async {
        let entryWeight = "aa".utf8.count + 64
        let cache = CompatibilityArchiveCache(
            listingCapacity: 3,
            listingWeightBudget: entryWeight * 2
        )
        let first = makeCacheKey(1)
        let second = makeCacheKey(2)
        let third = makeCacheKey(3)

        let firstToken = await cache.beginLoad(for: first)
        await cache.storeListing([cacheEntry("aa")], token: firstToken)
        await cache.finishLoad(firstToken)
        let secondToken = await cache.beginLoad(for: second)
        await cache.storeListing([cacheEntry("aa")], token: secondToken)
        await cache.finishLoad(secondToken)
        let thirdToken = await cache.beginLoad(for: third)
        await cache.storeListing([cacheEntry("aa")], token: thirdToken)
        await cache.finishLoad(thirdToken)

        let evictedFirst = await cache.cachedListing(for: first)
        let retainedSecond = await cache.cachedListing(for: second)
        let retainedThird = await cache.cachedListing(for: third)
        XCTAssertNil(evictedFirst)
        XCTAssertEqual(retainedSecond, [cacheEntry("aa")])
        XCTAssertEqual(retainedThird, [cacheEntry("aa")])
    }
}
