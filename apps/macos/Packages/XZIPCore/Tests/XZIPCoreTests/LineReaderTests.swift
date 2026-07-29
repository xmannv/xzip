import XCTest
@testable import XZIPCore

/// Regression tests for the piped-7zz progress format: 7zz redraws its
/// progress line with backspaces (0x08), not carriage returns, so LineReader
/// must treat a backspace as a segment boundary — otherwise the whole
/// progress sequence arrives as one line only when the process exits.
final class LineReaderTests: XCTestCase {

    private func segments(from chunks: [String]) -> [String] {
        var out: [String] = []
        let reader = LineReader { out.append($0) }
        for chunk in chunks { reader.feed(Data(chunk.utf8)) }
        reader.flush()
        return out
    }

    func testSplitsOnBackspaceRuns() {
        // Shape captured from the bundled 7zz 26.02 writing to a pipe.
        let feed = "  0%\u{08}\u{08}\u{08}\u{08}    \u{08}\u{08}\u{08}\u{08}  6% 1 + big.bin\u{08}\u{08} 13% 1 + big.bin\n"
        let lines = segments(from: [feed])
        XCTAssertTrue(lines.contains("  0%"))
        XCTAssertTrue(lines.contains("  6% 1 + big.bin"))
        XCTAssertTrue(lines.contains(" 13% 1 + big.bin"))
    }

    func testBackspaceProgressParsesToIncreasingFractions() {
        let feed = "  0%\u{08}\u{08}  6% 1 + big.bin\u{08}\u{08} 13% 1 + big.bin\u{08}\u{08}100% 1 + big.bin\n"
        let fractions = segments(from: [feed])
            .compactMap { SevenZipProgressParser.parse($0)?.fraction }
        XCTAssertEqual(fractions, [0.0, 0.06, 0.13, 1.0])
    }

    func testStillSplitsOnNewlineAndCarriageReturn() {
        XCTAssertEqual(segments(from: ["a\nb\rc\n"]), ["a", "b", "c"])
    }

    func testChunkBoundaryInsideBackspaceRun() {
        // A pipe read can split anywhere, including mid-run.
        let lines = segments(from: ["  6%\u{08}", "\u{08} 13%\n"])
        XCTAssertTrue(lines.contains("  6%"))
        XCTAssertTrue(lines.contains(" 13%"))
    }
}
