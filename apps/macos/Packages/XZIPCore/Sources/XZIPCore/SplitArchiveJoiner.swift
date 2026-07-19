import Foundation

/// Detects and joins multi-part split archives (e.g. `.001` / `.002` / `.003`
/// or `.7z.001`). Mirrors the flow in mockup 4b.
///
/// Design: a small, pure-ish domain service. Detection is filesystem-only and
/// synchronous; joining concatenates parts into a single file. Kept separate
/// from `ArchiveEngine` because splitting spans formats and is orthogonal to
/// compression strategy.
public struct SplitArchiveJoiner: Sendable {

    /// The outcome of scanning a folder for the parts of a split archive.
    public struct DetectionResult: Sendable, Equatable, Identifiable {
        /// The ordered part URLs found on disk.
        public let foundParts: [URL]
        /// Part numbers expected but missing (empty when the set is complete).
        public let missingParts: [Int]
        /// The base name without the numeric suffix (e.g. `backup-2025.7z`).
        public let baseName: String

        /// Stable identity for SwiftUI `.sheet(item:)` — the base name is unique
        /// per detected split set within a folder.
        public var id: String { baseName }

        public var isComplete: Bool { missingParts.isEmpty && !foundParts.isEmpty }
    }

    public init() {}

    /// Regex-free suffix parse: returns (base, index) for a `.NNN` tail.
    /// e.g. `backup.7z.002` -> ("backup.7z", 2).
    static func splitComponents(of url: URL) -> (base: String, index: Int)? {
        let name = url.lastPathComponent
        guard let dotRange = name.range(of: ".", options: .backwards) else { return nil }
        let suffix = String(name[dotRange.upperBound...])
        guard suffix.count >= 2, suffix.allSatisfy(\.isNumber), let index = Int(suffix) else {
            return nil
        }
        let base = String(name[..<dotRange.lowerBound])
        return (base, index)
    }

    /// Scan the folder containing `part` for all sibling parts of the same set.
    public func detect(part: URL) -> DetectionResult? {
        guard let (base, _) = Self.splitComponents(of: part) else { return nil }
        let folder = part.deletingLastPathComponent()
        let fm = FileManager.default
        let siblings = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        // Collect index -> url for every sibling sharing the base name.
        var byIndex: [Int: URL] = [:]
        for sibling in siblings {
            if let (siblingBase, index) = Self.splitComponents(of: sibling), siblingBase == base {
                byIndex[index] = sibling
            }
        }
        guard let minIndex = byIndex.keys.min(), let maxIndex = byIndex.keys.max() else {
            return nil
        }
        // Reject a lone high-numbered file that merely happens to end in digits
        // (e.g. `movie.2024`), which previously produced a spurious "missing 2023
        // parts" prompt. Treat something as a split set only when several parts
        // share the base name, or the single part is a plausible first part
        // (index 0 or 1).
        guard byIndex.count >= 2 || minIndex <= 1 else { return nil }
        // Split sets are numbered from `.000` or `.001`. Anchor the expected
        // range at 0 only when a `.000` part is actually present; otherwise start
        // at 1 so a missing first part is surfaced as `missingParts` instead of
        // being silently treated as complete (which would join a corrupt file).
        // Anchoring this way also avoids the `Array(1...0)` range trap when only
        // a `.00`/`.000` part exists.
        let lowerBound = byIndex.keys.contains(0) ? 0 : 1
        guard maxIndex >= lowerBound else { return nil }
        let expected = Array(lowerBound...maxIndex)
        let missing = expected.filter { byIndex[$0] == nil }
        let found = expected.compactMap { byIndex[$0] }
        return DetectionResult(foundParts: found, missingParts: missing, baseName: base)
    }

    /// Concatenate the detected parts into `destination` (the joined archive).
    /// Streams 0...1 progress across the total byte count.
    public func join(
        parts: [URL],
        destination: URL
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let fm = FileManager.default
                // Write to a sibling temp file and atomically swap it in only on
                // success. This never truncates a pre-existing file at the
                // destination up front, and a cancel/error mid-join leaves no
                // partial archive wearing the real name.
                let tempURL = destination.deletingLastPathComponent()
                    .appendingPathComponent(".xzip-join-\(UUID().uuidString).part")
                var committed = false
                defer { if !committed { try? fm.removeItem(at: tempURL) } }
                do {
                    guard fm.createFile(atPath: tempURL.path, contents: nil),
                          let handle = try? FileHandle(forWritingTo: tempURL) else {
                        throw ArchiveEngineError.engineFailure("Cannot create joined file.")
                    }

                    let total = parts.reduce(UInt64(0)) { sum, url in
                        sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0)
                    }
                    // Stream each part through a fixed-size buffer instead of
                    // loading whole parts (potentially multiple GB) into memory.
                    let chunkSize = 4 << 20 // 4 MiB
                    var written: UInt64 = 0
                    for part in parts {
                        try Task.checkCancellation()
                        guard let input = try? FileHandle(forReadingFrom: part) else {
                            throw ArchiveEngineError.engineFailure(
                                "Cannot read part \(part.lastPathComponent).")
                        }
                        defer { try? input.close() }
                        while true {
                            try Task.checkCancellation()
                            let chunk = try input.read(upToCount: chunkSize) ?? Data()
                            if chunk.isEmpty { break }
                            try handle.write(contentsOf: chunk)
                            written += UInt64(chunk.count)
                            let fraction = total > 0 ? Double(written) / Double(total) : nil
                            continuation.yield(ArchiveProgress(
                                fraction: fraction, currentEntry: part.lastPathComponent))
                        }
                    }
                    try handle.close()
                    try Task.checkCancellation()
                    // Atomic swap: replace an existing destination in place, or
                    // move the temp file into position when none exists.
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
                    } else {
                        try fm.moveItem(at: tempURL, to: destination)
                    }
                    committed = true
                    continuation.yield(ArchiveProgress(fraction: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
