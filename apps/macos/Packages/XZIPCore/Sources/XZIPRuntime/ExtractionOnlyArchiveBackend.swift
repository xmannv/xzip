import Foundation
import XZIPCore

/// The `ArchiveBackend` used by the extraction-only production cutover.
///
/// `ArchiveRuntime` requires a backend for the operations it does not handle
/// itself, but State Task 9 routes **only** extraction through the runtime:
/// every other operation (list, compress, comment, edit) still goes through the
/// app's existing `ArchiveService`. Extraction never reaches a backend either,
/// because the runtime dispatches it to the injected transactional handler —
/// which is exactly what `TrappingLegacyBackend` asserts in
/// `LiveExtractionAssemblyTests`.
///
/// So every member here is unreachable by construction. Each one throws
/// `ExtractionOnlyBackendMisuse` rather than calling `fatalError`, so a future
/// wiring mistake surfaces as a diagnosable error instead of crashing a user's
/// app. The two members that cannot throw return an empty answer and are
/// documented individually.
///
/// When the remaining operations are eventually moved onto the runtime, this
/// type is replaced by a real adapter over `ArchiveEngineFactory` — it is
/// deliberately not that adapter, to keep the cutover's blast radius at
/// extraction only.
public struct ExtractionOnlyArchiveBackend: ArchiveBackend {

    public init() {}

    private func misuse(_ operation: String) -> ExtractionOnlyBackendMisuse {
        ExtractionOnlyBackendMisuse(operation: operation)
    }

    // MARK: - Extraction (dispatched to the transactional handler, never here)

    public func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        throw misuse("extract")
    }

    // MARK: - Comment

    public func readComment(for archive: URL) async throws -> String {
        throw misuse("readComment")
    }

    public func writeComment(_ comment: String, to archive: URL) async throws {
        throw misuse("writeComment")
    }

    /// Non-throwing in the protocol. Reports "not editable" so a caller that
    /// reaches this by mistake takes its read-only path instead of proceeding
    /// into `writeComment` and failing mid-operation.
    public func canEditComment(for archive: URL) -> Bool { false }

    // MARK: - Split archives

    public func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult? {
        throw misuse("detectSplit")
    }

    public func joinSplit(
        parts: [URL],
        destination: URL
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { $0.finish(throwing: misuse("joinSplit")) }
    }

    // MARK: - Compression

    public func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        throw misuse("compress")
    }

    // MARK: - Inspection

    /// Non-throwing in the protocol. Reports "unknown format" rather than
    /// guessing, so capability checks fail closed.
    public func detectedFormat(for archive: URL) -> ArchiveFormat? { nil }

    public func list(archive: URL, password: String?) async throws -> [ArchiveEntry] {
        throw misuse("list")
    }

    public func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        throw misuse("list(limit:)")
    }

    public func test(archive: URL, password: String?) async throws -> Bool {
        throw misuse("test")
    }

    // MARK: - Mutation

    public func add(
        files: [URL],
        to archive: URL,
        password: String?,
        workingDirectory: URL?
    ) async throws {
        throw misuse("add")
    }

    public func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        throw misuse("addViaRepack")
    }

    public func delete(
        entries: [String],
        from archive: URL,
        password: String?
    ) async throws {
        throw misuse("delete")
    }

    public func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {
        throw misuse("rename")
    }

    public func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {
        throw misuse("update")
    }
}

/// Thrown when the extraction-only backend is asked to perform an operation
/// that the production wiring is supposed to route elsewhere. Reaching this is
/// always a wiring defect, never a user error.
public struct ExtractionOnlyBackendMisuse: Error, Equatable, Sendable, CustomStringConvertible {
    public let operation: String

    public init(operation: String) {
        self.operation = operation
    }

    public var description: String {
        """
        ExtractionOnlyArchiveBackend received '\(operation)'. Only extraction is \
        routed through ArchiveRuntime; every other operation must go through \
        ArchiveService. This indicates a wiring defect.
        """
    }
}
