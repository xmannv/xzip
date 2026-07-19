import Foundation
import XZIPCore

/// App-facing facade over `XZIPCore`: resolves the bundled engine, runs
/// compress/extract/list/test, and exposes the password & preset repositories.
///
/// Design: a Facade + composition root for the backend. Views talk to
/// `AppModel`, `AppModel` talks to this one service, and this service is the
/// only place that knows about `ArchiveEngineFactory`, `BinaryLocator`, etc.
/// This keeps the SwiftUI layer free of backend wiring and easy to preview.
struct ArchiveService: Sendable {
    let engineFactory: any ArchiveEngineProviding
    let editor: any ArchiveEditing
    let passwordStore: any PasswordStoring
    let presetStore: PresetStore
    let commentService: ArchiveCommentService
    let splitJoiner: SplitArchiveJoiner
    /// Caches the most recent successful listing per archive, keyed by
    /// modification date, so the many redundant `7zz l` passes (open → list,
    /// pre-extract conflict scan, the zip-slip guard inside every extract, each
    /// Quick Look / drag-out) collapse to a single listing per archive revision.
    /// A default value keeps it out of the memberwise initializer.
    let listingCache = ListingCache()
    /// Caches the content-detected format (magic bytes) per archive revision so
    /// capability checks (can this be modified / edited?) don't re-read the header
    /// on every SwiftUI render.
    let formatCache = FormatCache()

    // MARK: - Construction

    /// Production wiring: locate `7zz` inside the app bundle's Resources/bin.
    static func live() -> ArchiveService {
        let binDir = Bundle.main.resourceURL?.appendingPathComponent("bin")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin")
        let locator = BinaryLocator(searchDirectories: [binDir])
        let runner = FoundationProcessRunner()
        return ArchiveService(
            engineFactory: ArchiveEngineFactory.makeDefault(runner: runner, locator: locator),
            editor: SevenZipArchiveEditor(runner: runner, locator: locator),
            passwordStore: KeychainPasswordStore(),
            presetStore: PresetStore(),
            commentService: ArchiveCommentService(runner: runner),
            splitJoiner: SplitArchiveJoiner()
        )
    }

    // MARK: - Archive comment (mockup 4a)

    func readComment(for archive: URL) async throws -> String {
        // ZIP is read/written via the `zip`/`unzip` tools. Other formats that
        // carry a comment (RAR) are read-only, via the 7zz engine.
        if ArchiveCommentService.canEditComment(for: archive) {
            return try await commentService.readComment(for: archive)
        }
        let engine = try engineFactory.engine(forArchive: archive)
        return try await engine.readComment(archive: archive, password: nil)
    }

    func writeComment(_ comment: String, to archive: URL) async throws {
        try await commentService.writeComment(comment, to: archive)
    }

    func canEditComment(for archive: URL) -> Bool {
        ArchiveCommentService.canEditComment(for: archive)
    }

    // MARK: - Split archives (mockup 4b)

    func detectSplit(part: URL) -> SplitArchiveJoiner.DetectionResult? {
        splitJoiner.detect(part: part)
    }

    func joinSplit(parts: [URL], destination: URL) -> AsyncThrowingStream<Double, Error> {
        Self.fractionStream(from: splitJoiner.join(parts: parts, destination: destination))
    }

    // MARK: - Operations

    /// Compress `sources` into `destination`, streaming 0...1 progress.
    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        let engine = try engineFactory.engine(for: options.format)
        let raw = engine.compress(sources: sources, destination: destination, options: options)
        return Self.fractionStream(from: raw)
    }

    /// Extract `archive` into `destination`, streaming 0...1 progress.
    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) throws -> AsyncThrowingStream<Double, Error> {
        let engine = try engineFactory.engine(forArchive: archive)
        // No precomputed listing: the engine's zip-slip guard always re-lists
        // fresh, because a cached (mtime-keyed) listing is TOCTOU-unsafe — a
        // swapped archive could otherwise smuggle `../` entries past a stale guard.
        let raw = engine.extract(archive: archive, destination: destination, options: options)
        return Self.fractionStream(from: raw)
    }

    /// The content-detected (magic-byte) format of `archive`, cached per revision.
    /// Capability checks use this instead of the filename so a mislabeled archive
    /// (e.g. a RAR named `.zip`) is judged by what it actually is — the same way
    /// the read path routes engines — rather than offered edits 7zz will reject
    /// and Edit & Save Back would then discard.
    func detectedFormat(for archive: URL) -> XZIPCore.ArchiveFormat? {
        if let hit = formatCache.cached(for: archive) { return hit }
        guard let format = ArchiveFormatDetector.detect(fileAt: archive) else { return nil }
        formatCache.store(format, for: archive)
        return format
    }

    func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] {
        if let cached = listingCache.cached(for: archive) { return cached }
        let engine = try engineFactory.engine(forArchive: archive)
        let entries = try await engine.list(archive: archive, password: password)
        listingCache.store(entries, for: archive)
        return entries
    }

    func test(archive: URL, password: String?) async throws -> Bool {
        let engine = try engineFactory.engine(forArchive: archive)
        return try await engine.test(archive: archive, password: password)
    }

    // MARK: - Editing (add / delete / rename entries)

    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL? = nil) async throws {
        try await editor.add(files: files, to: archive, password: password, workingDirectory: workingDirectory)
    }

    func addViaRepack(files: [URL], to archive: URL, onStep: @escaping @Sendable (RepackStep) -> Void) async throws {
        try await editor.addViaRepack(files: files, to: archive, onStep: onStep)
    }

    func delete(entries: [String], from archive: URL, password: String?) async throws {
        try await editor.delete(entries: entries, from: archive, password: password)
    }

    func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws {
        try await editor.rename(pairs: pairs, in: archive, password: password)
    }

    /// Update one entry's data in place, preserving its archive path (used by
    /// Edit & Save Back). The edited file lives at `workingDirectory`/`entryPath`.
    func update(entry entryPath: String, from workingDirectory: URL, in archive: URL, password: String?) async throws {
        try await editor.update(entry: entryPath, from: workingDirectory, in: archive, password: password)
    }

    // MARK: - Password vault (Keychain-backed)

    func savedPassword(for archiveKey: String) -> String? {
        try? passwordStore.password(for: archiveKey)
    }

    func savePassword(_ password: String, for archiveKey: String) throws {
        try passwordStore.save(password: password, for: archiveKey)
    }

    func deletePassword(for archiveKey: String) throws {
        try passwordStore.delete(for: archiveKey)
    }

    func vaultKeys() -> [String] {
        (try? passwordStore.allKeys()) ?? []
    }

    /// Thread-safe listing cache keyed by (archive path, modification date).
    /// Mutating an archive (add/delete/rename) bumps its mtime, so the next
    /// listing misses and re-reads — the cache is self-invalidating, no explicit
    /// purge needed.
    final class ListingCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entriesByPath: [String: (mtime: Date, entries: [XZIPCore.ArchiveEntry])] = [:]

        func cached(for url: URL) -> [XZIPCore.ArchiveEntry]? {
            guard let mtime = Self.modificationDate(of: url) else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard let hit = entriesByPath[url.path], hit.mtime == mtime else { return nil }
            return hit.entries
        }

        func store(_ entries: [XZIPCore.ArchiveEntry], for url: URL) {
            guard let mtime = Self.modificationDate(of: url) else { return }
            lock.lock(); defer { lock.unlock() }
            // Bound the cache so a long session browsing many archives can't grow
            // it without limit (each entry can hold a 100k-item listing).
            if entriesByPath.count >= 32, let evict = entriesByPath.keys.first {
                entriesByPath.removeValue(forKey: evict)
            }
            entriesByPath[url.path] = (mtime, entries)
        }

        private static func modificationDate(of url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// Thread-safe cache of the content-detected format, keyed by (path, mtime)
    /// so a replaced file is re-detected. Bounded to avoid unbounded growth.
    final class FormatCache: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: (mtime: Date, format: XZIPCore.ArchiveFormat)] = [:]

        func cached(for url: URL) -> XZIPCore.ArchiveFormat? {
            guard let mtime = Self.modificationDate(of: url) else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard let hit = byPath[url.path], hit.mtime == mtime else { return nil }
            return hit.format
        }

        func store(_ format: XZIPCore.ArchiveFormat, for url: URL) {
            guard let mtime = Self.modificationDate(of: url) else { return }
            lock.lock(); defer { lock.unlock() }
            if byPath.count >= 64, let evict = byPath.keys.first {
                byPath.removeValue(forKey: evict)
            }
            byPath[url.path] = (mtime, format)
        }

        private static func modificationDate(of url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// Adapt the engine's `ArchiveProgress` stream into a plain fraction stream
    /// (what the kit UI expects). Indeterminate updates are dropped.
    private static func fractionStream(
        from raw: AsyncThrowingStream<ArchiveProgress, Error>
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await progress in raw {
                        if let fraction = progress.fraction {
                            continuation.yield(fraction)
                        }
                    }
                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
