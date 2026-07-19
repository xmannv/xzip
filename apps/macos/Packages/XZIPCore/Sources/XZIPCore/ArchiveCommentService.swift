import Foundation

/// Reads and writes the archive-level comment for ZIP files (mockup 4a).
///
/// Design: uses the system `zip`/`unzip` binaries (always present on macOS) via
/// the injected `ProcessRunning`. `7zz` does not manage ZIP comments, so this is
/// a focused, single-responsibility service separate from `ArchiveEngine`.
/// RAR comments are read-only and handled by listing via `7zz` elsewhere.
public struct ArchiveCommentService: Sendable {
    private let runner: ProcessRunning
    private let zip = "/usr/bin/zip"
    private let unzip = "/usr/bin/unzip"

    public init(runner: ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
    }

    /// Whether XZip can edit (not just read) the comment for this archive.
    public static func canEditComment(for url: URL) -> Bool {
        ArchiveFormat.infer(fromFilename: url.lastPathComponent) == .zip
    }

    /// Read the archive comment. Returns an empty string when none is set.
    public func readComment(for archive: URL) async throws -> String {
        // `unzip -z` prints the archive comment after the header lines.
        let result = try await runner.run(
            executable: unzip,
            arguments: ["-z", archive.path],
            workingDirectory: nil,
            environment: nil
        )
        guard result.isSuccess else { return "" }
        // Output format: first line is the archive name/summary, remaining lines
        // are the comment. Drop the first line and trim.
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write (replace) the archive comment. Feeds the text to `zip -z` on stdin.
    public func writeComment(_ comment: String, to archive: URL) async throws {
        guard Self.canEditComment(for: archive) else {
            throw ArchiveEngineError.engineFailure("Comments can only be edited on ZIP archives.")
        }
        let result = try await runner.run(
            executable: zip,
            arguments: ["-z", archive.path],
            workingDirectory: nil,
            environment: nil,
            standardInput: comment.hasSuffix("\n") ? comment : comment + "\n"
        )
        guard result.isSuccess else {
            throw ArchiveEngineError.engineFailure(result.standardError)
        }
    }
}
