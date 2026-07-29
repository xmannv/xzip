import Foundation
import XZIPCore

public protocol ArchiveBackend: Sendable {
    func readComment(for archive: URL) async throws -> String
    func writeComment(_ comment: String, to archive: URL) async throws
    func canEditComment(for archive: URL) -> Bool
    func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult?
    func joinSplit(parts: [URL], destination: URL) -> AsyncThrowingStream<Double, Error>
    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error>
    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error>
    func detectedFormat(for archive: URL) -> ArchiveFormat?
    func list(archive: URL, password: String?) async throws -> [ArchiveEntry]
    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult
    func test(archive: URL, password: String?) async throws -> Bool
    func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws
    func delete(entries: [String], from archive: URL, password: String?) async throws
    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws
    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws
}

public extension ArchiveBackend {
}
