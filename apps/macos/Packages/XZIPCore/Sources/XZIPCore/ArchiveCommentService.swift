import Foundation
import XZIPDomain

/// Reads and writes the archive-level comment for ZIP files (mockup 4a).
///
/// Design: uses the system `zip`/`unzip` binaries (always present on macOS) via
/// the injected `ProcessControlling`. `7zz` does not manage ZIP comments, so this is
/// a focused, single-responsibility service separate from `ArchiveEngine`.
/// RAR comments are read-only and handled by listing via `7zz` elsewhere.
public struct ArchiveCommentService: Sendable {
    private let processController: any ProcessControlling
    private let zip = "/usr/bin/zip"
    private let unzip = "/usr/bin/unzip"

    public init(
        runner: any ProcessControlling = ProcessController(
            policy: .production,
            permits: LocalProcessPermitPool(
                limit: ArchiveResourcePolicy.production.scheduling.globalProcessLimit
            )
        )
    ) {
        self.processController = runner
    }

    /// Whether XZip can edit (not just read) the comment for this archive.
    public static func canEditComment(for url: URL) -> Bool {
        ArchiveFormat.infer(fromFilename: url.lastPathComponent) == .zip
    }

    /// Read the archive comment. Returns an empty string when none is set.
    public func readComment(for archive: URL) async throws -> String {
        let result = try await processController.runBuffered(ProcessRequest(
            executable: unzip,
            arguments: ["-z", archive.path],
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        guard result.isSuccess else { return "" }
        let lines = result.standardOutput.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count > 1 else { return "" }
        return lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write (replace) the archive comment. Feeds the text to `zip -z` on stdin.
    public func writeComment(_ comment: String, to archive: URL) async throws {
        guard Self.canEditComment(for: archive) else {
            throw ArchiveEngineError.engineFailure(
                "Comments can only be edited on ZIP archives."
            )
        }
        let result = try await processController.runBuffered(ProcessRequest(
            executable: zip,
            arguments: ["-z", archive.path],
            standardInput: comment.hasSuffix("\n") ? comment : comment + "\n",
            workload: .heavyIO(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        guard result.isSuccess else {
            throw ArchiveEngineError.engineFailure(result.standardError)
        }
    }
}
