import Foundation

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

        var current: [String: String] = [:]
        // The last key seen in the current block. A `-slt` value may itself
        // contain newlines (filenames legally can), and 7zz prints those raw, so
        // the continuation lines arrive as lines that do not match ` = `. They
        // are appended back onto the last value; otherwise a crafted entry name
        // like "safe\n../../evil" would list as "safe", hiding the `..` from the
        // path-traversal guard while 7zz still extracts to the real name.
        var lastKey: String?
        func flush() {
            if let entry = Self.entry(from: current) {
                entries.append(entry)
            }
            current.removeAll()
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if !reachedEntries {
                // The header block ends at a line of dashes.
                if line.hasPrefix("----------") { reachedEntries = true }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                lastKey = nil
                continue
            }

            if let eq = line.range(of: " = ") {
                let key = String(line[line.startIndex..<eq.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(line[eq.upperBound...])
                current[key] = value
                lastKey = key
            } else if let lastKey {
                // Continuation of a multi-line value (e.g. an embedded newline in
                // the filename): re-attach it so the reconstructed value is exact.
                current[lastKey, default: ""] += "\n" + line
            }
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

struct SevenZipIncrementalListingParser {
    static let defaultMaxPhysicalLineBytes = 1_048_576
    static let defaultMaxRecordBytes = 8_388_608

    private(set) var entries: [ArchiveEntry] = []
    private(set) var reachedEntryLimit = false

    private var currentLine = Data()
    private var currentFields: [String: String] = [:]
    private var currentRecordBytes = 0
    private var lastKey: String?
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

        let line = String(decoding: currentLine, as: UTF8.self)
        if !reachedEntries {
            if line.hasPrefix("----------") { reachedEntries = true }
            return
        }

        if currentLine.isEmpty {
            flushRecord()
            return
        }

        currentRecordBytes += currentLine.count + (terminatedByLF ? 1 : 0)
        guard currentRecordBytes <= maxRecordBytes else {
            throw SevenZipListingParserError.recordTooLarge(limit: maxRecordBytes)
        }

        if let eq = line.range(of: " = ") {
            let key = String(line[line.startIndex..<eq.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            currentFields[key] = String(line[eq.upperBound...])
            lastKey = key
        } else if let lastKey {
            currentFields[lastKey, default: ""] += "\n" + line
        }
    }

    private mutating func flushRecord() {
        defer {
            currentFields.removeAll(keepingCapacity: true)
            currentRecordBytes = 0
            lastKey = nil
        }

        guard let entry = SevenZipListingParser.entry(from: currentFields) else { return }
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
