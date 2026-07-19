import Foundation

/// Editing operations on an existing archive (add, delete, rename entries).
///
/// Design: the Interface Segregation Principle. Not every engine supports
/// in-place editing, so this stays separate from `ArchiveEngine`. Callers that
/// only compress/extract need not depend on editing capability.
public protocol ArchiveEditing: Sendable {
    /// Add or update files inside an existing archive. When `workingDirectory`
    /// is given, each file is stored at its path relative to that directory, so
    /// the caller can control the in-archive location (e.g. add under a
    /// subfolder). When nil, 7zz stores files by basename at the archive root.
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws
    /// Delete entries (by their in-archive paths) from an archive.
    func delete(entries: [String], from archive: URL, password: String?) async throws
    /// Rename many entries in one pass (in-archive path → new in-archive path).
    /// Used to rename a folder and all of its descendants together. Pairs whose
    /// source does not exist are ignored by 7zz.
    func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws
    /// Update one entry's data in place, preserving its archive path. The edited
    /// file must live at `workingDirectory`/`entryPath`.
    func update(entry entryPath: String, from workingDirectory: URL, in archive: URL, password: String?) async throws
    /// Add files to a compressed tarball (`.tar.gz`, `.tgz`, …) by repacking:
    /// decompress → update the inner tar → recompress → atomically replace the
    /// original. `onStep` fires as each stage begins.
    func addViaRepack(files: [URL], to archive: URL, onStep: @escaping @Sendable (RepackStep) -> Void) async throws
}

public extension ArchiveEditing {
    /// Convenience: add files at the archive root (no working directory).
    func add(files: [URL], to archive: URL, password: String?) async throws {
        try await add(files: files, to: archive, password: password, workingDirectory: nil)
    }

    /// Convenience over the single protocol requirement (`rename(pairs:)`).
    /// Keeping this in the extension means a future editor implementation isn't
    /// forced to implement a redundant one-entry method.
    func rename(entry: String, to newName: String, in archive: URL, password: String?) async throws {
        try await rename(pairs: [(entry, newName)], in: archive, password: password)
    }
}

/// The stages of a tarball repack, in execution order (drives the progress UI).
public enum RepackStep: Int, CaseIterable, Sendable, Comparable {
    case decompress
    case addFiles
    case recompress

    public static func < (lhs: RepackStep, rhs: RepackStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// `ArchiveEditing` backed by the bundled `7zz` binary.
///
/// Design: mirrors `SevenZipEngine`'s Dependency Injection (runner + locator)
/// and reuses the same error mapping, so editing errors surface consistently.
public struct SevenZipArchiveEditor: ArchiveEditing {
    private let runner: ProcessRunning
    private let locator: BinaryLocating

    public init(runner: ProcessRunning, locator: BinaryLocating) {
        self.runner = runner
        self.locator = locator
    }

    private func binaryPath() throws -> String {
        guard let path = locator.path(for: .sevenZip) else {
            throw BinaryLocatorError.notFound(.sevenZip)
        }
        return path
    }

    public func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {
        // `-spd` disables wildcard matching so a real on-disk file named e.g.
        // `report*.txt` is added literally rather than being expanded by 7zz
        // (which would silently pull in every sibling matching the pattern).
        var args = ["a", "-bb0", "-spd", "-scsUTF-8"]
        // `-p` WITHOUT an inline value: the password is fed via stdin (below) so
        // it never lands in argv where `ps` could read it. Only pass `-p` when a
        // real password is given — an empty `-p` would encrypt with a blank one.
        if let password, !password.isEmpty { args.append("-p") }
        // File paths travel via a listfile, NOT argv: NSTask NFD-normalizes
        // argv, which would store mangled names for NFC sources. Paths are
        // respelled as stored on disk first (URL.path is already NFD). The
        // `@listfile` expansion requires that `--` is absent; safe because the
        // remaining argv tokens are trusted (absolute archive path, our listfile).
        let paths: [String]
        if let workingDirectory {
            // Store paths relative to the working directory so 7zz preserves the
            // intended in-archive folder structure instead of flattening to the
            // basename (7zz stores relative names when run from `workingDirectory`).
            paths = files.map {
                SevenZipEngine.onDiskRelativeSpelling(
                    of: Self.relativePath($0, to: workingDirectory), base: workingDirectory)
            }
        } else {
            paths = files.map { SevenZipEngine.onDiskSpelling(of: $0.path) }
        }
        let listFile = try Self.writeEntryListFile(paths)
        defer { try? FileManager.default.removeItem(at: listFile) }
        args.append(archive.path)
        args.append("@\(listFile.path)")
        let binary = try binaryPath()
        let result = try await runner.run(
            executable: binary, arguments: args,
            workingDirectory: workingDirectory, environment: nil,
            // Feed the password to 7zz's prompt via stdin (never argv). Writing
            // encrypted data triggers an Enter+Verify prompt pair, so it is sent
            // as two newline-separated lines.
            standardInput: Self.writePasswordStdin(password)
        )
        guard result.isSuccess else {
            throw SevenZipEngine.mapFailure(
                stderr: result.standardError, stdout: result.standardOutput,
                hadPassword: !(password ?? "").isEmpty)
        }
    }

    /// The path of `url` relative to `base`, or its last component when it does
    /// not live under `base`.
    static func relativePath(_ url: URL, to base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(basePath + "/") {
            return String(fullPath.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    public func delete(entries: [String], from archive: URL, password: String?) async throws {
        guard !entries.isEmpty else { return }
        // `-spd` disables wildcard matching: an in-archive entry whose real name
        // contains `*`/`?` (legal on macOS) must be deleted literally, never
        // treated as a mask that would wipe every matching sibling entry.
        // Entry names travel via a listfile, NOT argv: NSTask NFD-normalizes
        // argv while 7zz matches names byte-exactly, so an NFC name (e.g.
        // Vietnamese, from a Windows/web archive) on argv would match nothing.
        let listFile = try Self.writeEntryListFile(entries)
        defer { try? FileManager.default.removeItem(at: listFile) }
        var args = ["d", "-bb0", "-spd", "-scsUTF-8", "-i@\(listFile.path)"]
        // `-p` bare; the password is fed via stdin, never argv.
        if let password, !password.isEmpty { args.append("-p") }
        args.append("--")
        args.append(archive.path)
        try await run(args, standardInput: Self.writePasswordStdin(password))
    }

    public func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws {
        guard !pairs.isEmpty else { return }
        // Old/new names travel via a listfile (alternating lines), NOT argv:
        // NSTask NFD-normalizes argv while 7zz matches names byte-exactly, so an
        // NFC name on argv would match nothing, and a user-typed NFC new name
        // would be stored mangled. `@listfile` expansion requires that `--` is
        // absent; that is safe because the remaining argv tokens are trusted
        // (the archive path is absolute, the listfile path is ours).
        let listFile = try Self.writeEntryListFile(pairs.flatMap { [$0.entry, $0.newName] })
        defer { try? FileManager.default.removeItem(at: listFile) }
        // The password is fed via stdin, never argv.
        try await run(
            Self.renameArguments(archive: archive, listFile: listFile, password: password),
            standardInput: Self.writePasswordStdin(password))
    }

    /// Builds `rn` arguments; exposed for unit testing.
    static func renameArguments(archive: URL, listFile: URL, password: String?) -> [String] {
        // `-spd` disables wildcard matching so the source entry name is matched
        // literally (a name containing `*`/`?` must rename only itself).
        var args = ["rn", "-bb0", "-spd", "-scsUTF-8"]
        // `-p` bare; the password is fed via stdin, never argv.
        if let password, !password.isEmpty { args.append("-p") }
        args.append(archive.path)
        args.append("@\(listFile.path)")
        return args
    }

    /// Writes one name per line, verbatim UTF-8 bytes (see rename/delete: names
    /// must bypass argv's NFD normalization). A name containing a literal
    /// newline would split into two non-matching patterns and fail closed.
    static func writeEntryListFile(_ names: [String]) throws -> URL {
        let listFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-entries-\(UUID().uuidString).txt")
        try Data(names.joined(separator: "\n").utf8).write(to: listFile)
        return listFile
    }

    public func update(entry entryPath: String, from workingDirectory: URL, in archive: URL, password: String?) async throws {
        // `-spd` disables wildcard matching so the relative entry path is added
        // back literally, never expanded against sibling files on disk.
        var args = ["a", "-bb0", "-spd", "-scsUTF-8"]
        // `-p` bare; the password is fed via stdin (below), never argv.
        if let password, !password.isEmpty { args.append("-p") }
        // The entry path (verbatim bytes from the archive listing) travels via a
        // listfile, NOT argv: NSTask NFD-normalizes argv, which would re-add the
        // file under a mangled name — duplicating the entry instead of updating
        // it. Running from `workingDirectory` with the relative path makes 7zz
        // store the file back at its original in-archive location.
        let listFile = try Self.writeEntryListFile([entryPath])
        defer { try? FileManager.default.removeItem(at: listFile) }
        args.append(archive.path)
        args.append("@\(listFile.path)")
        let binary = try binaryPath()
        let result = try await runner.run(
            executable: binary, arguments: args,
            workingDirectory: workingDirectory, environment: nil,
            // Updating an entry re-adds it; encrypting triggers 7zz's Enter+Verify
            // prompt pair, so the password is sent as two stdin lines (never argv).
            standardInput: Self.writePasswordStdin(password)
        )
        guard result.isSuccess else {
            throw SevenZipEngine.mapFailure(
                stderr: result.standardError, stdout: result.standardOutput)
        }
    }

    public func addViaRepack(
        files: [URL],
        to archive: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {
        guard let codec = ArchiveFormat.tarWrapper(fromFilename: archive.lastPathComponent),
              let typeFlag = codec.sevenZipTypeFlag else {
            throw ArchiveEngineError.engineFailure("Not a compressed tarball — repack does not apply.")
        }
        let fm = FileManager.default
        // Prefer a temp dir on the SAME volume as the archive: the final
        // `replaceItemAt` stays an atomic rename (cross-volume it degrades to
        // copy or fails outright), and a large tar doesn't fill the boot disk.
        let tempBase = (try? fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: archive, create: true)) ?? fm.temporaryDirectory
        let tempDir = tempBase
            .appendingPathComponent("xzip-repack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Runs on every exit — success, failure, or cancellation — so no
        // intermediate files are ever left behind.
        defer { try? fm.removeItem(at: tempDir) }

        onStep(.decompress)
        try await runCancellable(["e", "-bb0", "-y", "-o\(tempDir.path)", "--", archive.path])
        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard let innerTar = contents.first(where: { $0.pathExtension.lowercased() == "tar" }) else {
            throw ArchiveEngineError.engineFailure("The archive does not contain a tar payload.")
        }

        onStep(.addFiles)
        // File paths travel via a listfile with on-disk spelling (see `add`):
        // argv would NFD-mangle the stored names.
        let addList = try Self.writeEntryListFile(
            files.map { SevenZipEngine.onDiskSpelling(of: $0.path) })
        defer { try? fm.removeItem(at: addList) }
        try await runCancellable(
            ["a", "-bb0", "-spd", "-scsUTF-8", innerTar.path, "@\(addList.path)"])

        onStep(.recompress)
        // The inner tar's own name is stored in the outer archive, so it goes
        // through a listfile too (it can carry the user's Unicode archive name).
        let repacked = tempDir.appendingPathComponent("repacked." + archive.pathExtension)
        let tarList = try Self.writeEntryListFile(
            [SevenZipEngine.onDiskSpelling(of: innerTar.path)])
        defer { try? fm.removeItem(at: tarList) }
        try await runCancellable(
            ["a", "-bb0", typeFlag, "-scsUTF-8", repacked.path, "@\(tarList.path)"])

        // Point of no return: after this the original is replaced atomically.
        try Task.checkCancellation()
        _ = try fm.replaceItemAt(archive, withItemAt: repacked)
    }

    /// Like `run`, but surfaces a cancelled 7zz (terminated by ProcessRunner's
    /// cancellation handler) as `CancellationError` instead of a raw
    /// engine-failure message.
    private func runCancellable(_ args: [String]) async throws {
        do {
            try await run(args)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
    }

    private func run(_ args: [String], standardInput: String? = nil) async throws {
        let binary = try binaryPath()
        let result = try await runner.run(
            executable: binary, arguments: args,
            workingDirectory: nil, environment: nil,
            standardInput: standardInput
        )
        guard result.isSuccess else {
            throw SevenZipEngine.mapFailure(
                stderr: result.standardError, stdout: result.standardOutput)
        }
    }

    /// Every in-place edit rewrites the archive; when it holds encrypted content
    /// 7zz re-encrypts it and prompts twice — "Enter password:" then "Verify
    /// password:" — so the password is fed on stdin as two newline-separated
    /// lines (a single read would leave the verify prompt hanging → "Break
    /// signaled"). Sending it twice is harmless when only one read is needed.
    /// Returns nil (no stdin pipe attached) when there is no password.
    private static func writePasswordStdin(_ password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        return password + "\n" + password
    }
}
