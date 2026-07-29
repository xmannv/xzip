import Foundation
import XCTest
@testable import XZIPRuntime

/// Unit tests for the journal's on-disk framing (C7).
///
/// The old format was an 8-byte length followed by the payload, written as two
/// separate `write` calls with no integrity field. Two consequences: a crash
/// between the writes left a length describing a payload that was never
/// submitted, and — the dangerous one — a torn payload was indistinguishable
/// from a short valid one, so a half-written record could decode as valid JSON
/// and be replayed as a real instruction by recovery.
final class JournalFrameTests: XCTestCase {

    private let cap = 1_048_576

    // MARK: - Round trip

    func testEncodedFrameRoundTrips() throws {
        let payload = Data(#"{"kind":"publish"}"#.utf8)
        let frame = JournalFrame.encode(payload: payload)

        XCTAssertEqual(frame.count, JournalFrame.headerSize + payload.count)
        let header = try XCTUnwrap(
            JournalFrame.decodeHeader(in: frame, at: 0, maximumPayloadLength: cap)
        )
        XCTAssertEqual(header.payloadLength, payload.count)
        let decoded = frame.subdata(
            in: JournalFrame.headerSize..<(JournalFrame.headerSize + header.payloadLength)
        )
        XCTAssertEqual(decoded, payload)
        XCTAssertTrue(JournalFrame.matches(checksum: header.checksum, payload: decoded))
    }

    func testEmptyPayloadRoundTrips() throws {
        // A zero-length payload is degenerate but must not be mistaken for a
        // truncated frame: the header is complete, so the frame is complete.
        let frame = JournalFrame.encode(payload: Data())
        let header = try XCTUnwrap(
            JournalFrame.decodeHeader(in: frame, at: 0, maximumPayloadLength: cap)
        )
        XCTAssertEqual(header.payloadLength, 0)
        XCTAssertTrue(JournalFrame.matches(checksum: header.checksum, payload: Data()))
    }

    func testFramesConcatenateWithoutAmbiguity() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var log = JournalFrame.encode(payload: first)
        log.append(JournalFrame.encode(payload: second))

        let firstHeader = try XCTUnwrap(
            JournalFrame.decodeHeader(in: log, at: 0, maximumPayloadLength: cap)
        )
        let secondOffset = JournalFrame.headerSize + firstHeader.payloadLength
        let secondHeader = try XCTUnwrap(
            JournalFrame.decodeHeader(in: log, at: secondOffset, maximumPayloadLength: cap)
        )
        XCTAssertEqual(secondHeader.payloadLength, second.count)
        let secondPayloadStart = secondOffset + JournalFrame.headerSize
        let secondPayloadEnd = secondPayloadStart + secondHeader.payloadLength
        XCTAssertEqual(
            log.subdata(in: secondPayloadStart..<secondPayloadEnd),
            second
        )
    }

    // MARK: - Detecting damage the old format could not

    func testChecksumRejectsAFlippedPayloadByte() throws {
        // The case that motivated the CRC: the length still matches, so the old
        // format saw a perfectly well-formed record.
        let payload = Data("the original record".utf8)
        var frame = JournalFrame.encode(payload: payload)
        frame[JournalFrame.headerSize] ^= 0x01

        let header = try XCTUnwrap(
            JournalFrame.decodeHeader(in: frame, at: 0, maximumPayloadLength: cap)
        )
        let corrupted = frame.subdata(
            in: JournalFrame.headerSize..<(JournalFrame.headerSize + header.payloadLength)
        )
        XCTAssertFalse(
            JournalFrame.matches(checksum: header.checksum, payload: corrupted),
            "a single flipped bit must invalidate the frame"
        )
    }

    func testBadMagicThrowsRatherThanGuessing() {
        var frame = JournalFrame.encode(payload: Data("record".utf8))
        frame[0] = 0x00

        XCTAssertThrowsError(
            try JournalFrame.decodeHeader(in: frame, at: 0, maximumPayloadLength: cap)
        ) { error in
            XCTAssertEqual(error as? JournalFrameError, .badMagic(offset: 0))
        }
    }

    func testTruncatedHeaderReportsIncompleteRatherThanCorrupt() throws {
        // Fewer bytes than a header is the ordinary crash-mid-append shape, and
        // must be reported as "nothing more to read" (nil) so the caller can
        // apply its truncated-tail policy, not as corruption.
        let frame = JournalFrame.encode(payload: Data("record".utf8))
        for count in 0..<JournalFrame.headerSize {
            XCTAssertNil(
                try JournalFrame.decodeHeader(
                    in: frame.prefix(count),
                    at: 0,
                    maximumPayloadLength: cap
                ),
                "a \(count)-byte fragment is incomplete, not corrupt"
            )
        }
    }

    func testDeclaredLengthBeyondCapIsRejected() {
        // Guards against a corrupt length driving a huge allocation.
        var frame = JournalFrame.encode(payload: Data("record".utf8))
        var huge = UInt64(cap + 1).littleEndian
        withUnsafeBytes(of: &huge) { bytes in
            frame.replaceSubrange(
                JournalFrame.magicSize..<(JournalFrame.magicSize + JournalFrame.lengthSize),
                with: bytes
            )
        }

        XCTAssertThrowsError(
            try JournalFrame.decodeHeader(in: frame, at: 0, maximumPayloadLength: cap)
        ) { error in
            XCTAssertEqual(
                error as? JournalFrameError,
                .payloadTooLarge(limit: cap, declared: UInt64(cap + 1))
            )
        }
    }

    // MARK: - CRC32 itself

    func testCRC32MatchesKnownVectors() {
        // Standard CRC-32/IEEE check values, so a refactor of the table cannot
        // quietly change the algorithm.
        XCTAssertEqual(CRC32.checksum(Data()), 0x0000_0000)
        XCTAssertEqual(CRC32.checksum(Data("a".utf8)), 0xE8B7_BE43)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }
}
