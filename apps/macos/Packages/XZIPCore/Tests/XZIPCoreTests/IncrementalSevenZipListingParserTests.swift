import Foundation
import XCTest
@testable import XZIPCore

final class IncrementalSevenZipListingParserTests: XCTestCase {
    private let listing = """
    ----------
    Path = café.txt
    Size = 1
    Packed Size = 1
    Attributes = A

    Path = folder/left\rright.txt
    Size = 2
    Packed Size = 2
    Attributes = A

    """

    func testArbitraryOneByteChunksMatchLegacyParser() throws {
        var parser = SevenZipIncrementalListingParser()

        for byte in listing.utf8 {
            try parser.feed(Data([byte]))
        }
        try parser.finish()

        XCTAssertEqual(parser.entries, SevenZipListingParser.parse(listing))
    }

    func testUTF8ScalarSplitAcrossChunks() throws {
        var parser = SevenZipIncrementalListingParser()
        let bytes = Array(listing.utf8)
        let splitIndex = try XCTUnwrap(bytes.firstIndex(of: 0xC3))

        try parser.feed(Data(bytes[...splitIndex]))
        try parser.feed(Data(bytes[(splitIndex + 1)...]))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["café.txt", "folder/left\rright.txt"])
    }

    func testStandaloneCarriageReturnIsPreserved() throws {
        var parser = SevenZipIncrementalListingParser()
        let bytes = Array(listing.utf8)
        let carriageReturnIndex = try XCTUnwrap(bytes.firstIndex(of: 0x0D))

        try parser.feed(Data(bytes[...carriageReturnIndex]))
        try parser.feed(Data(bytes[(carriageReturnIndex + 1)...]))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["café.txt", "folder/left\rright.txt"])
    }

    func testEmbeddedLFContinuationIsReconstructed() throws {
        let output = """
        ----------
        Path = safe
        ../../evil
        Size = 3
        Attributes = A
        """
        var parser = SevenZipIncrementalListingParser()

        try parser.feed(Data(output.utf8))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["safe\n../../evil"])
    }

    func testEmptyPhysicalLineFlushesRecord() throws {
        let firstChunk = "----------\nPath = first.txt\nSize = 1\n\n"
        let secondChunk = "Path = second.txt\nSize = 2\n"
        var parser = SevenZipIncrementalListingParser()

        try parser.feed(Data(firstChunk.utf8))
        try parser.feed(Data(secondChunk.utf8))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["first.txt", "second.txt"])
    }

    func testEOFFlushesRecordWithoutTrailingNewline() throws {
        let output = "----------\nPath = final.txt\nSize = 7"
        var parser = SevenZipIncrementalListingParser()

        try parser.feed(Data(output.utf8))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["final.txt"])
        XCTAssertEqual(parser.entries.first?.uncompressedSize, 7)
    }

    func testOversizedPhysicalLineThrows() throws {
        var parser = SevenZipIncrementalListingParser(maxPhysicalLineBytes: 12)

        XCTAssertThrowsError(try parser.feed(Data("----------\nPath = too-long.txt".utf8))) { error in
            XCTAssertEqual(error as? SevenZipListingParserError, .physicalLineTooLong(limit: 12))
        }
    }

    func testOversizedRecordThrows() throws {
        var parser = SevenZipIncrementalListingParser(
            maxPhysicalLineBytes: 64,
            maxRecordBytes: 16
        )

        XCTAssertThrowsError(
            try parser.feed(Data("----------\nPath = file.txt\nSize = 1\n".utf8))
        ) { error in
            XCTAssertEqual(error as? SevenZipListingParserError, .recordTooLarge(limit: 16))
        }
    }
}
