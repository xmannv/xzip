import XCTest
@testable import XZIPCore

/// Pure tests for ArchiveTreeBuilder and ArchiveFormatDetector.
final class TreeAndDetectorTests: XCTestCase {

    // MARK: - ArchiveTreeBuilder

    private func file(_ path: String, size: UInt64 = 10, dir: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, uncompressedSize: size, compressedSize: size,
                     modificationDate: nil, isDirectory: dir, isEncrypted: false)
    }

    func testBuildsHierarchyWithSynthesizedFolders() {
        let entries = [
            file("docs/readme.txt", size: 100),
            file("docs/img/logo.png", size: 500),
            file("root.txt", size: 20)
        ]
        let tree = ArchiveTreeBuilder.build(from: entries)

        // Directories first, so "docs" precedes "root.txt".
        XCTAssertEqual(tree.map(\.name), ["docs", "root.txt"])

        let docs = tree.first { $0.name == "docs" }
        XCTAssertEqual(docs?.isDirectory, true)
        // "img" folder was synthesized even though never listed explicitly.
        let img = docs?.children.first { $0.name == "img" }
        XCTAssertEqual(img?.isDirectory, true)
        XCTAssertEqual(img?.children.first?.name, "logo.png")
    }

    func testTotalSizeAggregates() {
        let entries = [
            file("a/b.txt", size: 100),
            file("a/c.txt", size: 50)
        ]
        let tree = ArchiveTreeBuilder.build(from: entries)
        let a = tree.first { $0.name == "a" }
        XCTAssertEqual(a?.totalSize, 150)
    }

    // MARK: - ArchiveFormatDetector

    func testDetectByMagicBytes() {
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),
            .sevenZip)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x50, 0x4B, 0x03, 0x04, 0x00]),
            .zip)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x1F, 0x8B, 0x08]),
            .gzip)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x28, 0xB5, 0x2F, 0xFD]),
            .zstd)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: Array("Rar!\u{1A}\u{07}\u{01}\u{00}".utf8)),
            .rar)
    }

    func testDetectExtractOnlyMagicBytes() {
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x4D, 0x53, 0x43, 0x46, 0x00, 0x00, 0x00, 0x00]),
            .cab)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0xED, 0xAB, 0xEE, 0xDB]),
            .rpm)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: Array("xar!".utf8)),
            .xip)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: Array("070701".utf8)),
            .cpio)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x68, 0x73, 0x71, 0x73]),
            .squashfs)
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x1F, 0x9D, 0x90]),
            .unixCompress)
        // LZH: "-lh" at offset 2.
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: [0x24, 0x00, 0x2D, 0x6C, 0x68, 0x35, 0x2D]),
            .lzh)
    }

    func testDetectIsoAtOffset32769() {
        var bytes = [UInt8](repeating: 0, count: 32774)
        for (i, b) in Array("CD001".utf8).enumerated() { bytes[32769 + i] = b }
        XCTAssertEqual(ArchiveFormatDetector.detect(headerBytes: bytes), .iso)
    }

    func testDetectChecksumValidLegacyTarWithoutUstar() {
        XCTAssertEqual(
            ArchiveFormatDetector.detect(headerBytes: makeTarHeader(name: "legacy.txt")),
            .tar
        )
    }

    func testDetectChecksumValidUstarTar() {
        var bytes = makeTarHeader(name: "modern.txt")
        bytes.replaceSubrange(257..<262, with: "ustar".utf8)
        writeTarChecksum(into: &bytes)
        XCTAssertEqual(ArchiveFormatDetector.detect(headerBytes: bytes), .tar)
    }

    func testRejectsTarMagicWithMalformedChecksum() {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes.replaceSubrange(257..<262, with: "ustar".utf8)
        bytes.replaceSubrange(148..<156, with: "000000\0 ".utf8)
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: bytes))
    }

    func testRejectsChecksumValidLzipHeaderWithUstarCollision() {
        var bytes = makeTarHeader(name: "placeholder")
        bytes.replaceSubrange(0..<6, with: [0x4C, 0x5A, 0x49, 0x50, 0x01, 0x0C])
        bytes.replaceSubrange(257..<262, with: "ustar".utf8)
        writeTarChecksum(into: &bytes)
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: bytes))
    }

    func testRejectsMalformedTarTypeflagWithValidChecksum() {
        var bytes = makeTarHeader(name: "bad-type")
        bytes[156] = 0xFF
        writeTarChecksum(into: &bytes)
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: bytes))
    }

    func testRejectsMalformedTarNumericFieldWithValidChecksum() {
        var bytes = makeTarHeader(name: "bad-size")
        bytes.replaceSubrange(124..<136, with: "99999999999\0".utf8)
        writeTarChecksum(into: &bytes)
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: bytes))
    }

    func testRejectsChecksumShapedEmptyBlock() {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes.replaceSubrange(148..<156, with: "000400\0 ".utf8)
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: bytes))
    }

    func testDetectUnknownReturnsNil() {
        XCTAssertNil(ArchiveFormatDetector.detect(headerBytes: [0x00, 0x01, 0x02, 0x03]))
    }

    func testDetectFileFallsBackToExtension() throws {
        // A file whose content is unknown but extension says .zip.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mystery-\(UUID().uuidString).zip")
        try Data([0xAA, 0xBB, 0xCC]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(ArchiveFormatDetector.detect(fileAt: tmp), .zip)
    }

    func testDetectFilePrefersMagicOverExtension() throws {
        // Content is real 7z but the extension lies (.txt).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("real7z-\(UUID().uuidString).txt")
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(ArchiveFormatDetector.detect(fileAt: tmp), .sevenZip)
    }

    private func makeTarHeader(name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes.replaceSubrange(0..<name.utf8.count, with: name.utf8)
        bytes.replaceSubrange(100..<108, with: "0000644\0".utf8)
        bytes.replaceSubrange(108..<116, with: "0000000\0".utf8)
        bytes.replaceSubrange(116..<124, with: "0000000\0".utf8)
        bytes.replaceSubrange(124..<136, with: "00000000000\0".utf8)
        bytes.replaceSubrange(136..<148, with: "00000000000\0".utf8)
        bytes[156] = 0x30
        writeTarChecksum(into: &bytes)
        return bytes
    }

    private func writeTarChecksum(into bytes: inout [UInt8]) {
        bytes.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
        let checksum = bytes.reduce(0) { $0 + Int($1) }
        bytes.replaceSubrange(148..<156, with: String(format: "%06o\0 ", checksum).utf8)
    }
}
