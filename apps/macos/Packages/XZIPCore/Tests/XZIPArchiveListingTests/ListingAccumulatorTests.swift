import Archive
import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPArchiveListing

final class ListingAccumulatorTests: XCTestCase {
    func testMapsMetadataWithoutReadingEntryData() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var accumulator = try ListingAccumulator(limit: 10, policy: policy())

        try accumulator.append(.init(
            pathname: "資料/readme.txt",
            size: 42,
            fileType: .regular,
            modificationDate: date
        ))
        try accumulator.append(.init(
            pathname: "empty/",
            fileType: .directory,
            modificationDate: date
        ))

        XCTAssertEqual(accumulator.result, ArchiveListingResult(
            entries: [
                ArchiveEntry(
                    path: "資料/readme.txt",
                    uncompressedSize: 42,
                    compressedSize: 0,
                    modificationDate: date,
                    isDirectory: false,
                    isEncrypted: false
                ),
                ArchiveEntry(
                    path: "empty/",
                    uncompressedSize: 0,
                    compressedSize: 0,
                    modificationDate: date,
                    isDirectory: true,
                    isEncrypted: false
                )
            ],
            truncated: false
        ))
    }

    func testStopsAfterLookaheadEntry() throws {
        var accumulator = try ListingAccumulator(limit: 2, policy: policy())
        try accumulator.append(.init(pathname: "one", size: 1))
        try accumulator.append(.init(pathname: "two", size: 2))
        try accumulator.append(.init(pathname: "three", size: 3))

        XCTAssertTrue(accumulator.shouldStop)
        XCTAssertEqual(accumulator.result.entries.map(\.path), ["one", "two"])
        XCTAssertTrue(accumulator.result.truncated)
    }

    func testRejectsNegativeLimit() {
        XCTAssertThrowsError(try ListingAccumulator(limit: -1, policy: policy())) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, .resourceLimitExceeded)
        }
    }

    func testListingHardCapOverridesCallerLimit() throws {
        var accumulator = try ListingAccumulator(limit: 99, policy: policy(hardCap: 1))
        try accumulator.append(.init(pathname: "one"))
        try accumulator.append(.init(pathname: "two"))
        XCTAssertEqual(accumulator.result.entries.map(\.path), ["one"])
        XCTAssertTrue(accumulator.result.truncated)
    }

    func testRejectsAbsolutePath() throws {
        try assertEntry("/private/payload", failsWith: .invalidEntryPath)
    }

    func testRejectsParentTraversalComponent() throws {
        try assertEntry("safe/../payload", failsWith: .invalidEntryPath)
    }

    func testRejectsPathOverByteCap() throws {
        var accumulator = try ListingAccumulator(limit: 1, policy: policy(pathBytes: 3))
        XCTAssertThrowsError(try accumulator.append(.init(pathname: "four"))) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, .invalidEntryPath)
        }
    }

    func testRejectsPathOverDepthCap() throws {
        var accumulator = try ListingAccumulator(limit: 1, policy: policy(depth: 2))
        XCTAssertThrowsError(try accumulator.append(.init(pathname: "a/b/c"))) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, .resourceLimitExceeded)
        }
    }

    func testRejectsTotalPathBytesOverCap() throws {
        var accumulator = try ListingAccumulator(limit: 2, policy: policy(totalBytes: 5))
        try accumulator.append(.init(pathname: "abc"))
        XCTAssertThrowsError(try accumulator.append(.init(pathname: "def"))) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, .resourceLimitExceeded)
        }
    }

    func testRejectsNegativeSize() throws {
        var accumulator = try ListingAccumulator(limit: 1, policy: policy())
        XCTAssertThrowsError(try accumulator.append(.init(pathname: "bad", size: -1))) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, .resourceLimitExceeded)
        }
    }

    private func assertEntry(
        _ path: String,
        failsWith expected: QuickLookArchiveListingError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var accumulator = try ListingAccumulator(limit: 1, policy: policy())
        XCTAssertThrowsError(
            try accumulator.append(.init(pathname: path)),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? QuickLookArchiveListingError, expected, file: file, line: line)
        }
    }

    private func policy(
        hardCap: Int = 10,
        totalBytes: Int = 1_024,
        pathBytes: Int = 256,
        depth: Int = 10
    ) -> ArchiveResourcePolicy.Listing {
        .init(
            browserEntryCap: 10,
            listingHardCap: hardCap,
            totalPathByteCap: totalBytes,
            maximumPathByteCount: pathBytes,
            maximumPathDepth: depth
        )
    }
}
