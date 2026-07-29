import Foundation

/// On-disk framing for the extraction journal's append-only record log.
///
/// ## Why this type exists
///
/// The journal previously framed each record as an 8-byte little-endian length
/// followed by the JSON payload, emitted as **two** separate `write` calls. That
/// has two failure modes, and the second is the dangerous one:
///
/// 1. A crash between the two writes leaves a length with no payload. The reader
///    saw a plausible length, ran off the end of the file, and (for an active
///    transaction) treated it as a truncated tail — recoverable, but only by
///    accident.
/// 2. A crash *during* the payload write leaves a length whose bytes are only
///    partly present, or present but torn. Nothing in the format could tell a
///    short-but-valid record from a torn one, so a half-written record could
///    decode as valid JSON and be replayed as a real instruction.
///
/// Recovery decides which files to move and delete based on these records, so a
/// silently mis-decoded record is a correctness problem, not just a parse bug.
///
/// ## The format
///
/// ```text
/// +--------+----------------+-----------+------------------+
/// | magic  | payloadLength  | payload   | payload          |
/// | 4 B    | 8 B LE UInt64  | CRC32 4 B | payloadLength B  |
/// +--------+----------------+-----------+------------------+
/// ```
///
/// `magic` catches misalignment: without it, any 8 bytes of garbage read as a
/// length, and the reader would either allocate wildly or silently skip real
/// records. `CRC32` covers only the payload, which is what must be trusted; a
/// corrupt header fails the magic or the bounds check instead.
///
/// ## What this does and does not guarantee
///
/// A frame is built in memory and handed to a single `write` call, so there is no
/// longer a window where a length exists on disk without its payload having been
/// submitted. That is *not* a claim of atomicity: `DurableFileHandle.write` loops
/// on partial writes, and a crash can still leave a frame half on disk. The
/// guarantee comes from the CRC — a torn frame is *detectable*, which is what the
/// two-write format lacked. Recovery policy then decides what to do about it (see
/// `JournalFrameReader`).
///
/// Pre-release, so no format migration is needed; there are no journals in the
/// wild to read.
enum JournalFrame {
    /// `XZJ` plus a format version. Bump the last byte if the layout changes.
    static let magic: [UInt8] = [0x58, 0x5A, 0x4A, 0x01]

    static let magicSize = 4
    static let lengthSize = MemoryLayout<UInt64>.size
    static let checksumSize = MemoryLayout<UInt32>.size

    /// Bytes preceding the payload.
    static let headerSize = magicSize + lengthSize + checksumSize

    /// Builds the complete on-disk frame for `payload`.
    static func encode(payload: Data) -> Data {
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(contentsOf: magic)
        var length = UInt64(payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        var checksum = CRC32.checksum(payload).littleEndian
        withUnsafeBytes(of: &checksum) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Header fields decoded from the start of a frame.
    struct Header {
        let payloadLength: Int
        let checksum: UInt32
    }

    /// Reads a header at `offset`, or nil when `data` is too short to hold one.
    ///
    /// Throws only when the magic is wrong, which cannot be explained by a
    /// truncated write: the magic is the first thing written and is smaller than
    /// any plausible torn prefix boundary. Wrong magic means the log is corrupt
    /// or not a journal at all.
    static func decodeHeader(
        in data: Data,
        at offset: Int,
        maximumPayloadLength: Int
    ) throws -> Header? {
        guard data.count - offset >= headerSize else { return nil }

        let magicRange = offset..<(offset + magicSize)
        guard Array(data[magicRange]) == magic else {
            throw JournalFrameError.badMagic(offset: offset)
        }

        var rawLength: UInt64 = 0
        let lengthStart = offset + magicSize
        _ = withUnsafeMutableBytes(of: &rawLength) { destination in
            data.copyBytes(to: destination, from: lengthStart..<(lengthStart + lengthSize))
        }
        let payloadLength = UInt64(littleEndian: rawLength)
        guard payloadLength <= UInt64(maximumPayloadLength) else {
            throw JournalFrameError.payloadTooLarge(
                limit: maximumPayloadLength,
                declared: payloadLength
            )
        }

        var rawChecksum: UInt32 = 0
        let checksumStart = lengthStart + lengthSize
        _ = withUnsafeMutableBytes(of: &rawChecksum) { destination in
            data.copyBytes(to: destination, from: checksumStart..<(checksumStart + checksumSize))
        }

        return Header(
            payloadLength: Int(payloadLength),
            checksum: UInt32(littleEndian: rawChecksum)
        )
    }

    static func matches(checksum: UInt32, payload: Data) -> Bool {
        CRC32.checksum(payload) == checksum
    }
}

enum JournalFrameError: Error, Equatable {
    case badMagic(offset: Int)
    case payloadTooLarge(limit: Int, declared: UInt64)
}

/// CRC-32 (IEEE 802.3, the reflected polynomial used by zip and gzip).
///
/// Hand-rolled because the platform offers no CRC-32 outside zlib's C API, and
/// pulling in a dependency for sixteen lines of table lookup is not worth it. The
/// choice of CRC-32 over a cryptographic hash is deliberate: this detects
/// accidental truncation and bit rot, not deliberate tampering. An attacker who
/// can write to the journal directory can already do worse.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                // 0xEDB88320 is the bit-reversed form of the standard polynomial.
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
