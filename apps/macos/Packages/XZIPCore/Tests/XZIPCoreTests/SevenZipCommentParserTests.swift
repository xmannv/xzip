import Foundation
import XCTest
@testable import XZIPCore

final class SevenZipCommentParserTests: XCTestCase {
    func testCommentParserStopsAfterArchiveHeader() throws {
        var parser = IncrementalSevenZipCommentParser()
        XCTAssertNil(try parser.consume(Data("Comment = hello\n".utf8)))
        XCTAssertEqual(
            try parser.consume(Data("----------\nPath = huge\n".utf8)),
            "hello"
        )
        XCTAssertTrue(parser.isComplete)
    }

    func testCommentParserHandlesCommentAndUTF8ScalarSplitAcrossChunks() throws {
        let bytes = Array("Comment = café\n----------\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)!
        var parser = IncrementalSevenZipCommentParser()

        XCTAssertNil(try parser.consume(Data(bytes[..<split])))
        XCTAssertNil(try parser.consume(Data(bytes[split...split])))
        XCTAssertEqual(try parser.consume(Data(bytes[(split + 1)...])), "café")
    }

    func testCommentParserHandlesCRLFHeaderBoundary() throws {
        var parser = IncrementalSevenZipCommentParser()

        XCTAssertNil(try parser.consume(Data("Comment = hello\r\n-----".utf8)))
        XCTAssertEqual(try parser.consume(Data("-----\r\nPath = ignored\r\n".utf8)), "hello")
    }

    func testCommentParserReturnsEmptyComment() throws {
        var parser = IncrementalSevenZipCommentParser()

        XCTAssertEqual(
            try parser.consume(Data("Comment =\n----------\n".utf8)),
            ""
        )
    }

    func testCommentParserReturnsEmptyWhenCommentIsAbsent() throws {
        var parser = IncrementalSevenZipCommentParser()

        XCTAssertEqual(
            try parser.consume(Data("Path = archive.zip\n----------\n".utf8)),
            ""
        )
    }

    func testCommentParserIgnoresDataAfterCompletion() throws {
        var parser = IncrementalSevenZipCommentParser()

        XCTAssertEqual(
            try parser.consume(Data("Comment = hello\n----------\nPath = ignored\n".utf8)),
            "hello"
        )
        XCTAssertNil(try parser.consume(Data(repeating: 0x41, count: 1_024)))
        XCTAssertTrue(parser.isComplete)
    }

    func testCommentParserRejectsOversizedHeader() throws {
        var parser = IncrementalSevenZipCommentParser(maximumHeaderByteCount: 8)

        XCTAssertThrowsError(try parser.consume(Data("123456789".utf8))) { error in
            XCTAssertEqual(
                error as? SevenZipCommentParserError,
                .headerTooLarge(limit: 8)
            )
        }
    }

    func testCommentParserRejectsMalformedUTF8BeforeHeaderBoundary() throws {
        var parser = IncrementalSevenZipCommentParser()
        let malformed = Data([0x43, 0x6F, 0x6D, 0x6D, 0x65, 0x6E, 0x74, 0x20,
                              0x3D, 0x20, 0xFF, 0x0A])

        XCTAssertNil(try parser.consume(malformed))
        XCTAssertThrowsError(try parser.consume(Data("----------\n".utf8))) { error in
            XCTAssertEqual(error as? SevenZipCommentParserError, .malformedUTF8)
        }
    }


    func testCommentParserRejectsMissingHeaderBoundaryAtEndOfStream() throws {
        var parser = IncrementalSevenZipCommentParser()
        XCTAssertNil(try parser.consume(Data("Comment = hello\n".utf8)))

        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(
                error as? SevenZipCommentParserError,
                .missingArchiveHeaderDelimiter
            )
        }
    }
}
