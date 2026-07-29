import Foundation
import XZIPDomain

/// Accumulates one `-slt` record's `Key = value` fields.
///
/// This exists because deciding "is this line a new field or the continuation of
/// the previous one?" is the security-critical step of `-slt` parsing, and it was
/// previously implemented three times (listing, incremental listing, inventory)
/// by copy-paste.
///
/// The rule, and why it matters: a `-slt` value may legally contain newlines
/// because filenames may, and 7zz prints them raw. So a record for a file named
///
///     safe
///     ../../evil
///
/// arrives as `Path = safe` followed by a bare `../../evil` line. Re-attaching
/// that line is what lets the traversal guard see the `..`.
///
/// The subtle failure: the old code decided by testing for `" = "` *first*, so an
/// attacker only had to embed an equals sign in the crafted portion of the name:
///
///     Path = safe
///     ../../evil = x
///
/// The second line matched `" = "`, was filed as a field named `../../evil`, and
/// `Path` was left as the harmless `safe`. The guard inspected `safe` and passed
/// the entry, while 7zz extracted to the real multi-line name and escaped the
/// destination.
///
/// The fix is to treat a line as a new field only when its key is one 7zz
/// actually emits. Anything else is continuation text, however much it resembles
/// a field.
struct SevenZipRecordAccumulator {
    /// Keys 7zz emits inside a per-entry `-slt` record.
    ///
    /// Deliberately broad: a key that is missing from this set gets absorbed into
    /// the preceding value, which corrupts that value. Over-inclusion is the safe
    /// direction because an unexpected-but-real key merely gets stored and
    /// ignored, whereas a missing one silently mangles data.
    static let recognizedKeys: Set<String> = [
        "Path", "Size", "Packed Size", "Modified", "Created", "Accessed",
        "Attributes", "Encrypted", "Folder", "CRC", "Method", "Block",
        "Comment", "Host OS", "Version", "Characteristics", "Mode",
        "User", "Group", "Symbolic Link", "Hard Link", "iNode", "Stream ID",
        "Alternate Stream", "Volume Index", "Offset", "Link", "Error",
        "Warning", "Type", "Solid", "Sparse", "Delta", "Codec", "Provider",
        "Num Blocks", "Total Size", "Free Space", "Cluster Size", "Label",
        "Short Name", "Creator Application", "Sector Size", "Read-only",
        "Streams", "Anti", "Padding", "Copy Link", "Name", "Extension",
        "SubType", "Physical Size", "Headers Size", "ANSI"
    ]

    private(set) var fields: [String: String] = [:]
    private var lastKey: String?

    /// Feeds one logical line of a record.
    ///
    /// `line` must already have its trailing CR removed; normalising here rather
    /// than at each of the three call sites is what stopped the copies from
    /// drifting (one of them had grown CR-stripping the others lacked).
    mutating func consume(_ line: String) {
        if let separator = line.range(of: " = ") {
            let key = String(line[line.startIndex..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if Self.recognizedKeys.contains(key) {
                fields[key] = String(line[separator.upperBound...])
                lastKey = key
                return
            }
        }
        // Either no separator at all, or a separator whose key 7zz never emits:
        // both are continuation text belonging to the previous value.
        if let lastKey {
            fields[lastKey, default: ""] += "\n" + line
        }
    }

    mutating func reset() {
        fields.removeAll()
        lastKey = nil
    }

    /// Drops the trailing carriage return of a CRLF-terminated line.
    static func stripCarriageReturn(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}

/// Parses `7zz l -slt` (technical listing) output into `ArchiveEntry` values.
///
/// Design: a stateless pure function wrapped in an enum namespace. Pure parsing
/// keeps it trivially unit-testable against captured fixtures, decoupled from
/// process execution.
public enum SevenZipListingParser {
    /// `-slt` prints one blank-line-separated block per entry with `Key = Value`
    /// lines, following a `----------` separator that ends the header section.
    public static func parse(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var reachedEntries = false

        // Field accumulation (including the security-critical continuation rule)
        // lives in SevenZipRecordAccumulator so this parser, the incremental
        // parser and the inventory parser cannot drift apart.
        var record = SevenZipRecordAccumulator()
        func flush() {
            if let entry = Self.entry(from: record.fields) {
                entries.append(entry)
            }
            record.reset()
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = SevenZipRecordAccumulator.stripCarriageReturn(String(rawLine))

            if !reachedEntries {
                // The header block ends at a line of dashes.
                if line.hasPrefix("----------") { reachedEntries = true }
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }

            record.consume(line)
        }
        flush() // Final block without a trailing blank line.
        return entries
    }

    static func entry(from fields: [String: String]) -> ArchiveEntry? {
        guard let path = fields["Path"], !path.isEmpty else { return nil }
        let attributes = fields["Attributes"] ?? ""
        let folderFlag = fields["Folder"] ?? ""
        return ArchiveEntry(
            path: path,
            uncompressedSize: UInt64(fields["Size"] ?? "") ?? 0,
            compressedSize: UInt64(fields["Packed Size"] ?? "") ?? 0,
            modificationDate: parseDate(fields["Modified"]),
            isDirectory: folderFlag == "+" || attributes.hasPrefix("D"),
            isEncrypted: (fields["Encrypted"] ?? "").hasPrefix("+")
        )
    }

    /// Extracts the archive-level comment from `7zz l -slt` output, or "" when
    /// none. The comment lives in the archive-properties block (before the first
    /// `----------` separator) as a `Comment = …` property whose value may span
    /// several lines; those continuation lines run until the next `Key = value`
    /// property. Works for any format 7zz reads comments from (ZIP, RAR).
    /// Archive-level property keys 7zz emits in the header block. A `Comment`
    /// value spans lines until the next of these; a free-text comment line such
    /// as "Author = John" is NOT one of them, so it stays part of the comment.
    private static let archiveHeaderKeys: Set<String> = [
        "Path", "Type", "Physical Size", "Headers Size", "Method", "Solid",
        "Blocks", "Multivolume", "Volume Index", "Volumes", "Offset", "Tail Size",
        "Embedded Stub Size", "Characteristics", "Cluster Size", "Code Page",
        "Comment", "Warning", "Warnings", "Errors", "Open Errors",
        "Total Physical Size", "ANSI", "Created", "Modified", "Encrypted",
        "Name", "SubType", "Streams", "Alternate Streams", "Read-only"
    ]

    public static func parseArchiveComment(_ output: String) -> String {
        // Only look at the archive-properties block, before the entry listing.
        // Take the prefix up to the first separator without splitting the whole
        // (possibly huge) listing into pieces.
        let header: Substring
        if let separator = output.range(of: "----------") {
            header = output[output.startIndex..<separator.lowerBound]
        } else {
            header = output[...]
        }
        let lines = header.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0 == "Comment =" || $0.hasPrefix("Comment = ")
        }) else { return "" }

        var parts: [String] = []
        if let range = lines[start].range(of: "Comment = ") {
            let inline = String(lines[start][range.upperBound...])
            if !inline.isEmpty { parts.append(inline) }
        }
        // Gather continuation lines until the next KNOWN archive-level property.
        // The old code stopped at any "Word = " line, which truncated multi-line
        // user comments whose lines happened to look like "Author = John".
        var i = start + 1
        while i < lines.count {
            if let eq = lines[i].range(of: " = ") {
                let key = String(lines[i][lines[i].startIndex..<eq.lowerBound])
                if archiveHeaderKeys.contains(key) { break }
            }
            parts.append(lines[i])
            i += 1
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // 7-Zip prints the "Modified" timestamp in the machine's local time, so
        // it must be parsed in the local zone. Parsing as UTC shifted every
        // entry's mtime by the local UTC offset.
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // 7-Zip prints e.g. "2026-07-16 08:52:31".
        let normalized = value.replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return dateFormatter.date(from: String(normalized.prefix(19)))
    }
}


enum SevenZipListingParserError: Error, Equatable {
    case physicalLineTooLong(limit: Int)
    case recordTooLarge(limit: Int)
}


enum SevenZipCommentParserError: Error, Equatable {
    case headerTooLarge(limit: Int)
    case malformedUTF8
    case missingArchiveHeaderDelimiter
}

public struct IncrementalSevenZipCommentParser: Sendable {
    public private(set) var isComplete = false

    private static let archiveHeaderDelimiter = Data("----------".utf8)

    private let maximumHeaderByteCount: Int
    private var header = Data()
    private var currentLine = Data()

    public init(
        maximumHeaderByteCount: Int = ArchiveResourcePolicy.production.process.stdoutBufferByteCap
    ) {
        precondition(maximumHeaderByteCount >= 0)
        self.maximumHeaderByteCount = maximumHeaderByteCount
    }

    public mutating func consume(_ data: Data) throws -> String? {
        guard !isComplete else { return nil }

        for byte in data {
            if byte != 0x0A {
                guard header.count + currentLine.count < maximumHeaderByteCount else {
                    throw SevenZipCommentParserError.headerTooLarge(
                        limit: maximumHeaderByteCount
                    )
                }
                currentLine.append(byte)
                continue
            }

            var normalizedLine = currentLine
            if normalizedLine.last == 0x0D {
                normalizedLine.removeLast()
            }
            currentLine.removeAll(keepingCapacity: true)

            if normalizedLine == Self.archiveHeaderDelimiter {
                guard let output = String(data: header, encoding: .utf8) else {
                    throw SevenZipCommentParserError.malformedUTF8
                }
                header.removeAll(keepingCapacity: false)
                isComplete = true
                return SevenZipListingParser.parseArchiveComment(output)
            }

            guard header.count + normalizedLine.count + 1 <= maximumHeaderByteCount else {
                throw SevenZipCommentParserError.headerTooLarge(
                    limit: maximumHeaderByteCount
                )
            }
            header.append(normalizedLine)
            header.append(0x0A)
        }

        return nil
    }


    public mutating func finish() throws -> String {
        guard !isComplete else { return "" }
        throw SevenZipCommentParserError.missingArchiveHeaderDelimiter
    }
}

/// Parses `7zz l -slt` output into `ExtractionInventoryEntry` values, deriving
/// an exact `ExtractionNodeKind` (regular file / directory / symbolic link)
/// from the `Folder` flag and the Unix-mode `Attributes` field.
///
/// Unlike `SevenZipListingParser` (which yields browsing `ArchiveEntry` values
/// that only distinguish directories), this retains the node kind the
/// transactional staging path needs to build a `StagingWriteAuthority`.
/// `linkTarget` is not present in `-slt` output, so it is always nil: the
/// transaction enforces link kind via no-follow filesystem identity, never via
/// an advertised target.
enum SevenZipInventoryParser {
    static func parse(_ output: String) -> [ExtractionInventoryEntry] {
        var entries: [ExtractionInventoryEntry] = []
        var reachedEntries = false
        // Shares SevenZipRecordAccumulator with the two listing parsers. This one
        // matters most: its output becomes the StagingWriteAuthority, so a `Path`
        // truncated by a forged `Key = value` line would authorise a write under
        // a name the guard never inspected.
        var record = SevenZipRecordAccumulator()

        func flush() {
            if let entry = inventoryEntry(from: record.fields) {
                entries.append(entry)
            }
            record.reset()
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = SevenZipRecordAccumulator.stripCarriageReturn(String(rawLine))
            if !reachedEntries {
                if line.hasPrefix("----------") { reachedEntries = true }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            record.consume(line)
        }
        flush()
        return entries
    }

    static func inventoryEntry(from fields: [String: String]) -> ExtractionInventoryEntry? {
        guard let path = fields["Path"], !path.isEmpty else { return nil }
        let attributes = fields["Attributes"] ?? ""
        let kind = classifyKind(
            folder: fields["Folder"] ?? "",
            attributes: attributes
        )
        return ExtractionInventoryEntry(
            path: path,
            kind: kind,
            size: UInt64(fields["Size"] ?? "") ?? 0,
            linkTarget: nil,
            isExplicitDirectory: kind == .directory,
            posixMode: parsePOSIXMode(attributes: attributes)
        )
    }

    /// Extracts the permission bits from 7zz's POSIX mode token, or `nil` when
    /// the archive recorded no mode.
    ///
    /// Only the low 9 bits are produced. The set-user-ID, set-group-ID and
    /// sticky bits are intentionally not decoded: an archive must not be able to
    /// ask for privileged bits on extraction. Their presence is still handled
    /// correctly for the bits we do read, because `s`/`S` and `t`/`T` encode the
    /// execute bit as well as the special bit (`s` and `t` mean execute is set,
    /// `S` and `T` mean it is not).
    static func parsePOSIXMode(attributes: String) -> UInt16? {
        for token in attributes.split(separator: " ") where isPOSIXModeToken(token) {
            var mode: UInt16 = 0
            for (offset, character) in token.dropFirst().enumerated() {
                let bit: UInt16 = 0o400 >> offset
                switch character {
                case "r", "w":
                    mode |= bit
                case "x", "s", "t":
                    mode |= bit
                case "-", "S", "T":
                    continue
                default:
                    continue
                }
            }
            return mode
        }
        return nil
    }

    /// Classifies a node kind from 7zz's `Folder` flag and `Attributes`. 7zz
    /// prints a POSIX mode string (e.g. `drwxr-xr-x`, `-rw-r--r--`,
    /// `lrwxrwxrwx`) among the space-separated attribute tokens; its first
    /// character is the file-type indicator.
    static func classifyKind(folder: String, attributes: String) -> ExtractionNodeKind {
        if folder == "+" { return .directory }
        if attributes.hasPrefix("D") { return .directory }
        for token in attributes.split(separator: " ") where isPOSIXModeToken(token) {
            switch token.first {
            case "l": return .symbolicLink
            case "d": return .directory
            case "-": return .regularFile
            default: continue
            }
        }
        return .regularFile
    }

    /// Whether `token` is a POSIX mode string like `drwxr-xr-x`: a type char
    /// (`d`/`l`/`-`, plus other file types) followed by exactly nine permission
    /// characters drawn from `rwxsStT-`. Validating the permission tail avoids
    /// misclassifying an unrelated ≥10-char attribute flag that merely happens
    /// to start with `l`/`d`/`-`.
    private static func isPOSIXModeToken(_ token: Substring) -> Bool {
        guard token.count == 10 else { return false }
        let permissionChars: Set<Character> = ["r", "w", "x", "s", "S", "t", "T", "-"]
        return token.dropFirst().allSatisfy { permissionChars.contains($0) }
    }
}

struct SevenZipIncrementalListingParser {
    static let defaultMaxPhysicalLineBytes = 1_048_576
    static let defaultMaxRecordBytes = 8_388_608

    private(set) var entries: [ArchiveEntry] = []
    private(set) var reachedEntryLimit = false

    private var currentLine = Data()
    private var record = SevenZipRecordAccumulator()
    private var currentRecordBytes = 0
    private var reachedEntries = false

    private let entryLimit: Int?
    private let maxPhysicalLineBytes: Int
    private let maxRecordBytes: Int

    init(
        entryLimit: Int? = nil,
        maxPhysicalLineBytes: Int = Self.defaultMaxPhysicalLineBytes,
        maxRecordBytes: Int = Self.defaultMaxRecordBytes
    ) {
        self.entryLimit = entryLimit
        self.maxPhysicalLineBytes = maxPhysicalLineBytes
        self.maxRecordBytes = maxRecordBytes
    }

    mutating func feed(_ chunk: Data) throws {
        guard !reachedEntryLimit else { return }

        for byte in chunk {
            if byte == 0x0A {
                try consumePhysicalLine(terminatedByLF: true)
                if reachedEntryLimit { return }
            } else {
                currentLine.append(byte)
                guard currentLine.count <= maxPhysicalLineBytes else {
                    throw SevenZipListingParserError.physicalLineTooLong(
                        limit: maxPhysicalLineBytes
                    )
                }
            }
        }
    }

    mutating func finish() throws {
        guard !reachedEntryLimit else { return }

        if !currentLine.isEmpty {
            try consumePhysicalLine(terminatedByLF: false)
        }
        flushRecord()
    }

    private mutating func consumePhysicalLine(terminatedByLF: Bool) throws {
        defer { currentLine.removeAll(keepingCapacity: true) }

        // Strip CR before any other test. Previously the record-boundary check
        // was `currentLine.isEmpty` on the raw bytes, so under CRLF output a
        // blank separator line still held a CR and was treated as record content
        // rather than a boundary, merging adjacent entries.
        let line = SevenZipRecordAccumulator.stripCarriageReturn(
            String(decoding: currentLine, as: UTF8.self)
        )
        if !reachedEntries {
            if line.hasPrefix("----------") { reachedEntries = true }
            return
        }

        if line.isEmpty {
            flushRecord()
            return
        }

        currentRecordBytes += currentLine.count + (terminatedByLF ? 1 : 0)
        guard currentRecordBytes <= maxRecordBytes else {
            throw SevenZipListingParserError.recordTooLarge(limit: maxRecordBytes)
        }

        record.consume(line)
    }

    private mutating func flushRecord() {
        defer {
            record.reset()
            currentRecordBytes = 0
        }

        guard let entry = SevenZipListingParser.entry(from: record.fields) else { return }
        if let entryLimit, entries.count >= entryLimit {
            reachedEntryLimit = true
            return
        }

        entries.append(entry)
        if let entryLimit, entries.count >= entryLimit {
            reachedEntryLimit = true
        }
    }
}

/// Parses 7-Zip `-bsp1` progress lines into `ArchiveProgress`.
///
/// Progress lines look like:  " 42% 12 - folder/file.txt"  or  " 42%".
public enum SevenZipProgressParser {
    public static func parse(_ line: String) -> ArchiveProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let percentRange = trimmed.range(of: "%") else { return nil }

        // Extract the integer immediately preceding '%'.
        let beforePercent = trimmed[trimmed.startIndex..<percentRange.lowerBound]
        let digits = beforePercent.reversed().prefix { $0.isNumber }.reversed()
        guard let percent = Int(String(digits)) else { return nil }

        // Optional "current entry" after " - ".
        var entry: String?
        if let dashRange = trimmed.range(of: " - ") {
            entry = String(trimmed[dashRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if entry?.isEmpty == true { entry = nil }
        }

        return ArchiveProgress(
            fraction: min(max(Double(percent) / 100.0, 0), 1),
            currentEntry: entry
        )
    }
}
