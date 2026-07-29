import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

/// Regression tests for C1: a crafted `-slt` record could hide a `..` component
/// from the path-traversal guard.
///
/// The attack does not need a malicious 7zz. `-slt` values may contain newlines
/// (filenames legally can), so the *archive author* controls lines that appear in
/// the middle of a record. The old parser decided "new field vs continuation" by
/// testing for `" = "` first, so a filename whose second line contained an equals
/// sign was split: the dangerous part became a bogus field and `Path` kept only
/// the harmless first line. The guard inspected the harmless value while 7zz
/// extracted to the real, escaping name.
final class SevenZipRecordAccumulatorTests: XCTestCase {

    // MARK: - The C1 payload

    /// A forged `Key = value` line must not terminate the `Path` value.
    func testForgedFieldLineIsTreatedAsPathContinuation() {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Folder = -

        """
        let entries = SevenZipListingParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        // The crafted line belongs to the name, so the reconstructed path still
        // carries the `..` the guard needs to see.
        XCTAssertEqual(entries.first?.path, "safe.txt\n../../evil = x")
        XCTAssertFalse(
            entries.contains { $0.path == "safe.txt" },
            "Path must not be truncated to the harmless first line"
        )
    }

    /// The whole point of reconstructing the name: the guard rejects it.
    func testForgedFieldLineIsRejectedByTraversalGuard() throws {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Folder = -

        """
        let entries = SevenZipListingParser.parse(listing)
        let destination = URL(fileURLWithPath: "/tmp/dest")

        XCTAssertThrowsError(
            try SevenZipEngine.validateNoPathTraversal(
                entries: entries,
                destination: destination
            )
        ) { error in
            guard case ArchiveEngineError.pathTraversalDetected = error else {
                return XCTFail("Expected pathTraversalDetected, got \(error)")
            }
        }
    }

    /// Same payload through the parser that authorises staging writes. This is
    /// the more dangerous of the two: its output becomes the
    /// `StagingWriteAuthority`.
    func testInventoryParserDoesNotTruncatePathOnForgedField() {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Attributes = _ -rw-r--r--

        """
        let entries = SevenZipInventoryParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "safe.txt\n../../evil = x")
    }

    /// The staging path has a second, independent guard: `ExtractionInventory`
    /// validates every component via `ArchiveComponentValidator`, which rejects
    /// both `..` and embedded line breaks. Asserting it here pins that layering
    /// so a future change to the parser cannot quietly become the only defence.
    func testInventoryValidationRejectsReconstructedTraversalPath() {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Attributes = _ -rw-r--r--

        """
        let parsed = SevenZipInventoryParser.parse(listing)

        XCTAssertThrowsError(
            try ExtractionInventory.validated(
                entries: parsed,
                advertisedDictionaryByteCount: 0,
                policy: .production
            )
        ) { error in
            guard case ExtractionInventoryError.invalidPath = error else {
                return XCTFail("Expected invalidPath, got \(error)")
            }
        }
    }

    /// The incremental parser feeds the same accumulator, so it must agree
    /// byte-for-byte with the batch parser on the payload.
    func testIncrementalParserAgreesWithBatchParserOnForgedField() throws {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Folder = -

        """
        var parser = SevenZipIncrementalListingParser()
        try parser.feed(Data(listing.utf8))
        try parser.finish()

        XCTAssertEqual(parser.entries, SevenZipListingParser.parse(listing))
        XCTAssertEqual(parser.entries.first?.path, "safe.txt\n../../evil = x")
    }

    /// A `..` reached via a deeper forged field is still caught. Uses a key that
    /// looks plausible (`Evil`) rather than an obvious path, to show the check is
    /// "is this key one 7zz emits?" and not "does this look like a path?".
    func testUnrecognizedPlausibleKeyIsAlsoContinuation() {
        let listing = """
        ----------
        Path = docs/readme.txt
        Evil = ../../../../etc/cron.d/pwn
        Size = 10
        Folder = -

        """
        let entries = SevenZipListingParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            entries.first?.path,
            "docs/readme.txt\nEvil = ../../../../etc/cron.d/pwn"
        )
        XCTAssertThrowsError(
            try SevenZipEngine.validateNoPathTraversal(
                entries: entries,
                destination: URL(fileURLWithPath: "/tmp/dest")
            )
        ) { error in
            guard case ArchiveEngineError.pathTraversalDetected = error else {
                return XCTFail("Expected pathTraversalDetected, got \(error)")
            }
        }
    }

    // MARK: - Not breaking legitimate output

    /// Every key 7zz actually emits must still parse as a field.
    func testRecognizedKeysStillParseAsFields() {
        let listing = """
        ----------
        Path = folder/hello.txt
        Size = 12
        Packed Size = 20
        Modified = 2026-07-16 08:52:31
        Attributes = _ -rw-r--r--
        Encrypted = -
        Folder = -
        CRC = ABCDEF01

        """
        let entries = SevenZipListingParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        let entry = entries.first
        XCTAssertEqual(entry?.path, "folder/hello.txt")
        XCTAssertEqual(entry?.uncompressedSize, 12)
        XCTAssertEqual(entry?.compressedSize, 20)
        XCTAssertEqual(entry?.isDirectory, false)
        XCTAssertNotNil(entry?.modificationDate)
    }

    /// A genuine embedded newline (no equals sign) was already handled; keep it
    /// working.
    func testPlainMultiLineFilenameIsStillReassembled() {
        let listing = """
        ----------
        Path = weird
        name.txt
        Size = 5
        Folder = -

        """
        let entries = SevenZipListingParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "weird\nname.txt")
    }

    /// CRLF output must not merge adjacent records. The incremental parser used
    /// to test raw-byte emptiness for the record boundary, so a separator line
    /// holding a lone CR read as content and glued two entries together.
    func testCRLFSeparatorStillEndsRecord() throws {
        let listing = "----------\r\nPath = a.txt\r\nSize = 1\r\nFolder = -\r\n\r\nPath = b.txt\r\nSize = 2\r\nFolder = -\r\n"

        var parser = SevenZipIncrementalListingParser()
        try parser.feed(Data(listing.utf8))
        try parser.finish()

        XCTAssertEqual(parser.entries.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(parser.entries.count, 2)
    }

    /// Chunk boundaries must not change the result: the accumulator sees logical
    /// lines, not network-sized pieces.
    func testResultIsIndependentOfChunkBoundaries() throws {
        let listing = """
        ----------
        Path = safe.txt
        ../../evil = x
        Size = 10
        Folder = -

        """
        let bytes = Array(Data(listing.utf8))

        for chunkSize in [1, 3, 7, 64] {
            var parser = SevenZipIncrementalListingParser()
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                let end = min(start + chunkSize, bytes.count)
                try parser.feed(Data(bytes[start..<end]))
            }
            try parser.finish()

            XCTAssertEqual(
                parser.entries.first?.path,
                "safe.txt\n../../evil = x",
                "chunk size \(chunkSize) changed the parse"
            )
        }
    }
}
