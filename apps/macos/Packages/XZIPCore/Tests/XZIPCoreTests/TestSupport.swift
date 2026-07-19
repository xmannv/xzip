import Foundation
import XCTest
@testable import XZIPCore

/// Shared helpers for locating the repo's bundled `7zz` during tests.
enum TestSupport {
    /// Repo root resolved from this source file's location:
    /// Packages/XZIPCore/Tests/XZIPCoreTests/<file> -> repo root is 4 up.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // XZIPCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // XZIPCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    static var binDirectory: URL {
        repoRoot.appendingPathComponent("Resources/bin")
    }

    static var locator: BinaryLocator {
        BinaryLocator(searchDirectories: [binDirectory])
    }

    static var hasSevenZip: Bool {
        locator.path(for: .sevenZip) != nil
    }

    /// Creates a unique temporary directory, returning its URL.
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drains a progress stream to completion, returning all values.
    static func drain(
        _ stream: AsyncThrowingStream<ArchiveProgress, Error>
    ) async throws -> [ArchiveProgress] {
        var values: [ArchiveProgress] = []
        for try await p in stream { values.append(p) }
        return values
    }

    /// Creates a file via the raw open(2) syscall so the name's exact UTF-8
    /// bytes land on disk. Foundation's file APIs pass names through
    /// fileSystemRepresentation, which NFD-decomposes Unicode — they cannot
    /// produce an NFC-named file (as created by git, curl, terminal tools).
    static func createFileRawName(_ name: String, in dir: URL, content: String) throws -> URL {
        let path = dir.path + "/" + name
        // withCString passes plain UTF-8 bytes, not fileSystemRepresentation.
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        let bytes = Array(content.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return URL(fileURLWithPath: path)
    }

    /// Minimal store-only zip with a single UTF-8-flagged entry, written byte by
    /// byte so the entry name keeps its exact normalization (compressing real
    /// files can't do that reliably: Foundation-created names are NFD on disk).
    static func writeStoredZip(entryName: String, content: String, to url: URL) throws {
        let name = Array(entryName.utf8)
        let body = Array(content.utf8)
        let crc = crc32(body)

        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }

        var local: [UInt8] = []
        local += le32(0x0403_4B50)                 // local file header signature
        local += le16(20)                          // version needed
        local += le16(0x0800)                      // flags: UTF-8 names
        local += le16(0)                           // method: store
        local += le16(0) + le16(0x21)              // mod time/date
        local += le32(crc)
        local += le32(UInt32(body.count))          // compressed size
        local += le32(UInt32(body.count))          // uncompressed size
        local += le16(UInt16(name.count))
        local += le16(0)                           // extra length
        local += name + body

        var central: [UInt8] = []
        central += le32(0x0201_4B50)               // central directory signature
        central += le16(20) + le16(20)             // version made by / needed
        central += le16(0x0800)                    // flags: UTF-8 names
        central += le16(0)                         // method: store
        central += le16(0) + le16(0x21)            // mod time/date
        central += le32(crc)
        central += le32(UInt32(body.count))
        central += le32(UInt32(body.count))
        central += le16(UInt16(name.count))
        central += le16(0) + le16(0)               // extra / comment length
        central += le16(0) + le16(0)               // disk / internal attrs
        central += le32(0)                         // external attrs
        central += le32(0)                         // local header offset
        central += name

        var eocd: [UInt8] = []
        eocd += le32(0x0605_4B50)                  // end of central directory
        eocd += le16(0) + le16(0)                  // disk numbers
        eocd += le16(1) + le16(1)                  // entry counts
        eocd += le32(UInt32(central.count))
        eocd += le32(UInt32(local.count))          // central directory offset
        eocd += le16(0)                            // comment length

        try Data(local + central + eocd).write(to: url)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
