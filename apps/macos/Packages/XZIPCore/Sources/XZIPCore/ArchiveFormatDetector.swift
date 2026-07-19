import Foundation

/// Detects archive formats by inspecting file header "magic" bytes.
///
/// Design: complements `ArchiveFormat.infer(fromFilename:)` (extension-based).
/// Content sniffing is more reliable for files with wrong/missing extensions,
/// which matters when users drop arbitrary files. Kept as a pure enum namespace
/// so it is trivially unit-testable against byte fixtures.
public enum ArchiveFormatDetector {

    /// Magic-byte signatures, longest/most-specific checked first.
    private struct Signature {
        let format: ArchiveFormat
        let offset: Int
        let bytes: [UInt8]
    }

    private static let signatures: [Signature] = [
        // 7z: 37 7A BC AF 27 1C
        Signature(format: .sevenZip, offset: 0, bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),
        // xz: FD 37 7A 58 5A 00
        Signature(format: .xz, offset: 0, bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
        // RAR5: 52 61 72 21 1A 07 01 00
        Signature(format: .rar, offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]),
        // RAR4: 52 61 72 21 1A 07 00
        Signature(format: .rar, offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]),
        // WIM: "MSWIM\0\0\0"
        Signature(format: .wim, offset: 0, bytes: [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]),
        // CAB: "MSCF" + reserved1 (always zero)
        Signature(format: .cab, offset: 0, bytes: [0x4D, 0x53, 0x43, 0x46, 0x00, 0x00, 0x00, 0x00]),
        // CHM: "ITSF" + version 3
        Signature(format: .chm, offset: 0, bytes: [0x49, 0x54, 0x53, 0x46, 0x03, 0x00, 0x00, 0x00]),
        // cpio (ASCII variants): "070701" / "070702" / "070707"
        Signature(format: .cpio, offset: 0, bytes: Array("070701".utf8)),
        Signature(format: .cpio, offset: 0, bytes: Array("070702".utf8)),
        Signature(format: .cpio, offset: 0, bytes: Array("070707".utf8)),
        // ISO 9660: "CD001" in the primary volume descriptor
        Signature(format: .iso, offset: 32769, bytes: Array("CD001".utf8)),
        // RPM: ED AB EE DB
        Signature(format: .rpm, offset: 0, bytes: [0xED, 0xAB, 0xEE, 0xDB]),
        // xar (XIP wrapper): "xar!"
        Signature(format: .xip, offset: 0, bytes: [0x78, 0x61, 0x72, 0x21]),
        // SquashFS: "hsqs" (LE) / "sqsh" (BE)
        Signature(format: .squashfs, offset: 0, bytes: [0x68, 0x73, 0x71, 0x73]),
        Signature(format: .squashfs, offset: 0, bytes: [0x73, 0x71, 0x73, 0x68]),
        // zstd: 28 B5 2F FD
        Signature(format: .zstd, offset: 0, bytes: [0x28, 0xB5, 0x2F, 0xFD]),
        // ZIP: 50 4B 03 04 (also empty/spanned variants)
        Signature(format: .zip, offset: 0, bytes: [0x50, 0x4B, 0x03, 0x04]),
        Signature(format: .zip, offset: 0, bytes: [0x50, 0x4B, 0x05, 0x06]),
        Signature(format: .zip, offset: 0, bytes: [0x50, 0x4B, 0x07, 0x08]),
        // LZH: "-lh" at offset 2
        Signature(format: .lzh, offset: 2, bytes: [0x2D, 0x6C, 0x68]),
        // bzip2: 42 5A 68 ("BZh")
        Signature(format: .bzip2, offset: 0, bytes: [0x42, 0x5A, 0x68]),
        // ARJ: 60 EA
        Signature(format: .arj, offset: 0, bytes: [0x60, 0xEA]),
        // Unix compress: 1F 9D
        Signature(format: .unixCompress, offset: 0, bytes: [0x1F, 0x9D]),
        // gzip: 1F 8B
        Signature(format: .gzip, offset: 0, bytes: [0x1F, 0x8B]),
        // tar: "ustar" at offset 257
        Signature(format: .tar, offset: 257, bytes: Array("ustar".utf8)),
    ]

    /// The number of header bytes needed to cover all signatures.
    /// The ISO 9660 magic sits at offset 32769, so the header spans 32 KB;
    /// smaller files simply skip the signatures they can't contain.
    static let headerLength = 32774

    /// Detects a format from a header byte buffer, or nil if unrecognized.
    public static func detect(headerBytes bytes: [UInt8]) -> ArchiveFormat? {
        for sig in signatures {
            let end = sig.offset + sig.bytes.count
            guard bytes.count >= end else { continue }
            if Array(bytes[sig.offset..<end]) == sig.bytes {
                return sig.format
            }
        }
        return nil
    }

    /// Detects a format by reading the header of the file at `url`.
    /// Falls back to extension-based inference when the header is unknown.
    public static func detect(fileAt url: URL) -> ArchiveFormat? {
        if let bytes = readHeader(of: url, length: headerLength),
           let format = detect(headerBytes: bytes) {
            return format
        }
        return ArchiveFormat.infer(fromFilename: url.lastPathComponent)
    }

    private static func readHeader(of url: URL, length: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: length)) ?? Data()
        return data.isEmpty ? nil : [UInt8](data)
    }
}
