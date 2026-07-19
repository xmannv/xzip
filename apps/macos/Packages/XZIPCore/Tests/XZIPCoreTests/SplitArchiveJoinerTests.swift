import XCTest
@testable import XZIPCore

/// Tests for `SplitArchiveJoiner` part detection + join (mockup 4b logic).
final class SplitArchiveJoinerTests: XCTestCase {

    // MARK: - splitComponents parsing

    func testSplitComponentsParsesNumericSuffix() {
        let url = URL(fileURLWithPath: "/tmp/backup.7z.002")
        let parsed = SplitArchiveJoiner.splitComponents(of: url)
        XCTAssertEqual(parsed?.base, "backup.7z")
        XCTAssertEqual(parsed?.index, 2)
    }

    func testSplitComponentsParsesBareNumericParts() {
        let url = URL(fileURLWithPath: "/tmp/movie.001")
        let parsed = SplitArchiveJoiner.splitComponents(of: url)
        XCTAssertEqual(parsed?.base, "movie")
        XCTAssertEqual(parsed?.index, 1)
    }

    func testSplitComponentsRejectsNonNumericSuffix() {
        XCTAssertNil(SplitArchiveJoiner.splitComponents(of: URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertNil(SplitArchiveJoiner.splitComponents(of: URL(fileURLWithPath: "/tmp/file.7z")))
    }

    // MARK: - detect (filesystem)

    func testDetectFindsCompleteSet() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...3 {
            let name = String(format: "data.bin.%03d", i)
            try Data("part\(i)".utf8).write(to: dir.appendingPathComponent(name))
        }

        let joiner = SplitArchiveJoiner()
        let result = joiner.detect(part: dir.appendingPathComponent("data.bin.001"))
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isComplete ?? false)
        XCTAssertEqual(result?.foundParts.count, 3)
        XCTAssertEqual(result?.missingParts ?? [], [])
        XCTAssertEqual(result?.baseName, "data.bin")
    }

    func testDetectReportsMissingParts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Parts 1 and 3 present, 2 missing.
        for i in [1, 3] {
            let name = String(format: "clip.mov.%03d", i)
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let joiner = SplitArchiveJoiner()
        let result = joiner.detect(part: dir.appendingPathComponent("clip.mov.001"))
        XCTAssertEqual(result?.isComplete, false)
        XCTAssertEqual(result?.missingParts ?? [], [2])
    }

    func testDetectReportsMissingFirstPart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Parts 2 and 3 present, the first part (.001) missing. This must be
        // reported incomplete: expecting the range from 1 (not the lowest index
        // found) is what surfaces the missing first part — previously it was
        // treated as complete and produced a corrupt join.
        for i in [2, 3] {
            let name = String(format: "backup.7z.%03d", i)
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let joiner = SplitArchiveJoiner()
        let result = joiner.detect(part: dir.appendingPathComponent("backup.7z.002"))
        XCTAssertEqual(result?.isComplete, false)
        XCTAssertEqual(result?.missingParts ?? [], [1])
    }

    func testDetectSingleZeroIndexedPartDoesNotTrap() throws {
        // A lone `.00` part must not crash (`Array(1...0)` range trap) and is a
        // complete single-part set.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("blob.00"))

        let joiner = SplitArchiveJoiner()
        let result = joiner.detect(part: dir.appendingPathComponent("blob.00"))
        XCTAssertEqual(result?.isComplete, true)
        XCTAssertEqual(result?.foundParts.count, 1)
        XCTAssertEqual(result?.missingParts ?? [nil].compactMap { $0 }, [])
    }

    func testDetectZeroBasedSetIncludesFirstPart() throws {
        // A `.000`/`.001` set is 0-based; the `.000` part must be included, not
        // silently dropped (which would join a corrupt file yet report complete).
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in [0, 1] {
            try Data("p\(i)".utf8).write(
                to: dir.appendingPathComponent(String(format: "vol.%03d", i)))
        }

        let joiner = SplitArchiveJoiner()
        let result = joiner.detect(part: dir.appendingPathComponent("vol.000"))
        XCTAssertEqual(result?.isComplete, true)
        XCTAssertEqual(result?.foundParts.count, 2)
    }

    func testDetectIgnoresLoneHighNumberedFile() throws {
        // A single file that merely ends in digits (e.g. `movie.2024`) is not a
        // split set and must not trigger a spurious "missing parts" prompt.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("movie.2024"))

        let joiner = SplitArchiveJoiner()
        XCTAssertNil(joiner.detect(part: dir.appendingPathComponent("movie.2024")))
    }

    // MARK: - join

    func testJoinConcatenatesPartsInOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parts = try (1...3).map { i -> URL in
            let url = dir.appendingPathComponent(String(format: "blob.%03d", i))
            try Data("[\(i)]".utf8).write(to: url)
            return url
        }
        let destination = dir.appendingPathComponent("joined.bin")

        let joiner = SplitArchiveJoiner()
        for try await _ in joiner.join(parts: parts, destination: destination) {}

        let joined = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(joined, "[1][2][3]")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
