import XCTest
import XZIPCore

/// Detection rules feeding the add-files repack pipeline: which filenames are
/// compressed tarballs (repackable) vs plain single-stream files (blocked).
final class TarWrapperTests: XCTestCase {
    func testCompoundTarExtensionsDetected() {
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tgz"), .gzip)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.bz2"), .bzip2)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "b.tbz"), .bzip2)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "b.tbz2"), .bzip2)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.xz"), .xz)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.txz"), .xz)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.zst"), .zstd)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tzst"), .zstd)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "A.TAR.GZ"), .gzip)
        // Long-form codec extensions.
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.gzip"), .gzip)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.bzip2"), .bzip2)
        XCTAssertEqual(ArchiveFormat.tarWrapper(fromFilename: "a.tar.zstd"), .zstd)
    }

    func testGzippedNonTarPayloadsAreNotTarWrapper() {
        // A gzip OF a .tgz is not itself a tarball wrapper.
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.tgz.gz"))
        // Split-archive parts infer no format at all.
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "x.7z.001"))
    }

    func testPlainSingleStreamIsNotTarWrapper() {
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "notes.txt.gz"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.gz"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.xz"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.zst"))
    }

    func testOtherFormatsAreNotTarWrapper() {
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.zip"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.7z"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.tar"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "a.rar"))
        XCTAssertNil(ArchiveFormat.tarWrapper(fromFilename: "plain.txt"))
    }

    func testSevenZipTypeFlags() {
        XCTAssertEqual(ArchiveFormat.gzip.sevenZipTypeFlag, "-tgzip")
        XCTAssertEqual(ArchiveFormat.bzip2.sevenZipTypeFlag, "-tbzip2")
        XCTAssertEqual(ArchiveFormat.xz.sevenZipTypeFlag, "-txz")
        XCTAssertEqual(ArchiveFormat.zstd.sevenZipTypeFlag, "-tzstd")
        XCTAssertNil(ArchiveFormat.rar.sevenZipTypeFlag)
        XCTAssertNil(ArchiveFormat.dmg.sevenZipTypeFlag)
    }
}
