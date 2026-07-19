import Foundation

protocol DMGDirectoryIterating: Sendable {
    func nextURL() throws -> URL?
}

private final class FileManagerDMGDirectoryIterator: DMGDirectoryIterating, @unchecked Sendable {
    private let enumerator: FileManager.DirectoryEnumerator?

    init(mountPoint: URL, keys: [URLResourceKey]) {
        enumerator = FileManager.default.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: keys
        )
    }

    func nextURL() throws -> URL? {
        while let object = enumerator?.nextObject() {
            if let url = object as? URL { return url }
        }
        return nil
    }
}

/// `ArchiveEngine` backed by macOS `hdiutil` for `.dmg` disk images.
///
/// Design: another Strategy alongside `SevenZipEngine`, registered in
/// `ArchiveEngineFactory` for the `.dmg` format. `hdiutil` is a system binary
/// at a fixed path, so this engine does not need `BinaryLocating`. Progress is
/// reported as indeterminate then complete, since `hdiutil`'s machine-readable
/// progress is coarse; the queue UI shows an indeterminate bar meanwhile.
public struct DMGEngine: ArchiveEngine {
    private let runner: ProcessRunning
    private let makeDirectoryIterator: @Sendable (
        URL,
        [URLResourceKey]
    ) -> any DMGDirectoryIterating
    private let hdiutil = "/usr/bin/hdiutil"

    public init(runner: ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
        self.makeDirectoryIterator = { mountPoint, keys in
            FileManagerDMGDirectoryIterator(mountPoint: mountPoint, keys: keys)
        }
    }

    init(
        runner: ProcessRunning,
        makeDirectoryIterator: @escaping @Sendable (
            URL,
            [URLResourceKey]
        ) -> any DMGDirectoryIterating
    ) {
        self.runner = runner
        self.makeDirectoryIterator = makeDirectoryIterator
    }

    public var supportedFormats: Set<ArchiveFormat> { [.dmg] }

    // MARK: - Compress (create a UDZO disk image from sources)

    public func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Remove a half-written .dmg if create fails or is cancelled, so
                // no corrupt image is left at the destination. A pre-existing file
                // is left alone (caller owns the overwrite decision).
                let destinationPreexisted = FileManager.default.fileExists(atPath: destination.path)
                var finishedSuccessfully = false
                defer {
                    if !finishedSuccessfully, !destinationPreexisted {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                do {
                    continuation.yield(.indeterminate)
                    // hdiutil create needs a single source folder. If multiple
                    // inputs are given, stage them into a temp folder first.
                    let (srcFolder, cleanup) = try Self.stageSources(sources)
                    defer { cleanup() }

                    let volName = destination.deletingPathExtension().lastPathComponent
                    let result = try await runner.run(
                        executable: hdiutil,
                        arguments: [
                            "create",
                            "-volname", volName,
                            "-srcfolder", srcFolder.path,
                            "-ov",
                            "-format", "UDZO",
                            destination.path
                        ],
                        workingDirectory: nil,
                        environment: nil
                    )
                    guard result.isSuccess else {
                        throw ArchiveEngineError.engineFailure(result.standardError)
                    }
                    finishedSuccessfully = true
                    continuation.yield(ArchiveProgress(fraction: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Extract (attach, copy out, detach)

    public func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.indeterminate)
                    let mountPoint = try Self.makeTempDirectory()
                    defer { try? FileManager.default.removeItem(at: mountPoint) }

                    try await attach(archive, mountPoint: mountPoint, password: options.password)

                    do {
                        let fm = FileManager.default
                        try fm.createDirectory(
                            at: destination, withIntermediateDirectories: true)
                        // Honour `selectedEntries`: when the user extracts a
                        // subset from the browser, copy only those archive-relative
                        // paths (preserving their folder structure) instead of the
                        // whole volume. Empty selection = extract everything.
                        let jobs: [(src: URL, target: URL)]
                        if options.selectedEntries.isEmpty {
                            jobs = try fm.contentsOfDirectory(
                                at: mountPoint, includingPropertiesForKeys: nil
                            ).map { ($0, destination.appendingPathComponent($0.lastPathComponent)) }
                        } else {
                            // Guard against path traversal: each selected name is
                            // joined onto both the mount point (read) and the
                            // destination (write), so a `..`/absolute component
                            // could escape either. Fail closed.
                            try Self.validateSelectedEntries(options.selectedEntries)
                            jobs = options.selectedEntries.map {
                                (mountPoint.appendingPathComponent($0),
                                 destination.appendingPathComponent($0))
                            }
                        }
                        for job in jobs {
                            try Task.checkCancellation()
                            guard fm.fileExists(atPath: job.src.path) else { continue }
                            try fm.createDirectory(
                                at: job.target.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                            let exists = fm.fileExists(atPath: job.target.path)
                            switch options.existingFilePolicy {
                            case .replace:
                                if exists { try fm.removeItem(at: job.target) }
                                try fm.copyItem(at: job.src, to: job.target)
                            case .skip:
                                if !exists { try fm.copyItem(at: job.src, to: job.target) }
                            case .keepBoth:
                                try fm.copyItem(
                                    at: job.src, to: exists ? Self.uniqueURL(for: job.target) : job.target)
                            }
                        }
                    } catch {
                        await detach(mountPoint)
                        throw error
                    }

                    await detach(mountPoint)
                    continuation.yield(ArchiveProgress(fraction: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - List (attach read-only, enumerate, detach)

    public func list(archive: URL, password: String?) async throws -> [ArchiveEntry] {
        try await listing(archive: archive, password: password, limit: nil).entries
    }

    public func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        guard limit >= 0 else {
            throw ArchiveEngineError.engineFailure("Listing limit must be non-negative.")
        }
        return try await listing(archive: archive, password: password, limit: limit)
    }

    private func listing(
        archive: URL,
        password: String?,
        limit: Int?
    ) async throws -> ArchiveListingResult {
        let mountPoint = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: mountPoint) }

        try await attach(archive, mountPoint: mountPoint, password: password)

        do {
            let result = try enumerateEntries(at: mountPoint, limit: limit)
            await detach(mountPoint)
            return result
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    /// Synchronous directory walk (kept non-async: `FileManager.enumerator`'s
    /// iterator is unavailable from async contexts).
    private func enumerateEntries(
        at mountPoint: URL,
        limit: Int?
    ) throws -> ArchiveListingResult {
        var entries: [ArchiveEntry] = []
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let iterator = makeDirectoryIterator(mountPoint, keys)
        // `FileManager.enumerator` yields paths with a leading "/private" (the
        // real location of /var, /tmp, etc.), e.g.
        //   /private/var/folders/.../mount/XZip.app/Contents
        // while `mountPoint.path` is the unresolved /var/folders/.../mount.
        // Note `resolvingSymlinksInPath()` *strips* /private (giving /var), so it
        // would NOT match the enumerator's /private-prefixed paths — the previous
        // approach fell back to `lastPathComponent` for every nested item, which
        // flattened the tree and broke sub-folder navigation. Instead, canonicalize
        // both sides with a pure-string /private strip (no symlink following, so
        // internal DMG symlinks like "Applications" are left intact) and take the
        // remainder as the archive-relative path.
        func canonicalize(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let basePrefix = canonicalize(mountPoint.path) + "/"

        while true {
            try Task.checkCancellation()
            guard let url = try iterator.nextURL() else { break }
            if let limit, entries.count >= limit {
                return ArchiveListingResult(entries: entries, truncated: true)
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            let full = canonicalize(url.path)
            let rel = full.hasPrefix(basePrefix)
                ? String(full.dropFirst(basePrefix.count))
                : url.lastPathComponent
            entries.append(ArchiveEntry(
                path: rel,
                uncompressedSize: size,
                compressedSize: size,
                modificationDate: values?.contentModificationDate,
                isDirectory: isDir,
                isEncrypted: false
            ))
        }
        return ArchiveListingResult(entries: entries, truncated: false)
    }

    // MARK: - Test (verify checksum)

    public func test(archive: URL, password: String?) async throws -> Bool {
        // Encrypted images need the passphrase to verify; pipe it via stdin so it
        // never lands in argv. Without this, verifying an encrypted DMG always
        // failed with an authentication error rather than a checksum result.
        let hasPassword = !(password ?? "").isEmpty
        let result: ProcessResult
        if hasPassword {
            result = try await runner.run(
                executable: hdiutil,
                arguments: ["verify", "-stdinpass", archive.path],
                workingDirectory: nil, environment: nil, standardInput: password)
        } else {
            result = try await runner.run(
                executable: hdiutil,
                arguments: ["verify", archive.path],
                workingDirectory: nil, environment: nil
            )
        }
        return result.isSuccess
    }


    private func detach(_ mountPoint: URL) async {
        let runner = self.runner
        let hdiutil = self.hdiutil
        await Task.detached {
            _ = try? await runner.run(
                executable: hdiutil,
                arguments: ["detach", mountPoint.path, "-force"],
                workingDirectory: nil,
                environment: nil
            )
        }.value
    }

    /// Attaches `archive` read-only at `mountPoint`. For an encrypted image the
    /// passphrase is piped via stdin (`-stdinpass`) so it never appears in argv
    /// (where `ps` could read it).
    private func attach(_ archive: URL, mountPoint: URL, password: String?) async throws {
        var args = ["attach", archive.path, "-nobrowse", "-readonly",
                    "-mountpoint", mountPoint.path]
        let hasPassword = !(password ?? "").isEmpty
        let result: ProcessResult
        if hasPassword {
            args.append("-stdinpass")
            result = try await runner.run(
                executable: hdiutil, arguments: args,
                workingDirectory: nil, environment: nil, standardInput: password)
        } else {
            result = try await runner.run(
                executable: hdiutil, arguments: args,
                workingDirectory: nil, environment: nil)
        }
        guard result.isSuccess else {
            throw Self.mapAttachFailure(result.standardError, hadPassword: hasPassword)
        }
    }

    /// Maps `hdiutil attach` failures, distinguishing encryption/passphrase
    /// errors so the UI can prompt for (or re-prompt for) a password.
    private static func mapAttachFailure(_ stderr: String, hadPassword: Bool) -> ArchiveEngineError {
        let h = stderr.lowercased()
        let looksEncrypted = h.contains("authentication error")
            || h.contains("passphrase")
            || h.contains("password")
            || h.contains("corrupt image") // hdiutil's message for a bad passphrase
        if looksEncrypted {
            return hadPassword ? .wrongPassword : .passwordRequired
        }
        return .engineFailure(stderr)
    }

    /// Returns a non-colliding sibling URL using 7zz's keep-both convention:
    /// `name_1.ext`, `name_2.ext`, … . DMG extraction previously used
    /// `name (2).ext`, so the same `.keepBoth` policy produced different names
    /// depending on the engine. Internal for unit testing.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - Helpers

    /// If a single folder is given, use it directly; otherwise stage all inputs
    /// into a temp folder so `hdiutil create -srcfolder` has one root.
    private static func stageSources(_ sources: [URL]) throws -> (URL, () -> Void) {
        let fm = FileManager.default
        if sources.count == 1 {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sources[0].path, isDirectory: &isDir), isDir.boolValue {
                return (sources[0], {})
            }
        }
        let staging = try makeTempDirectory()
        for src in sources {
            // Two sources from different folders can share a basename
            // (/a/report.txt and /b/report.txt); disambiguate the collision so
            // copyItem doesn't fail the whole job with "file exists".
            let target = staging.appendingPathComponent(src.lastPathComponent)
            let destination = fm.fileExists(atPath: target.path) ? uniqueURL(for: target) : target
            try fm.copyItem(at: src, to: destination)
        }
        return (staging, { try? fm.removeItem(at: staging) })
    }

    /// Rejects selected entry names that would escape via a `..` component or an
    /// absolute path — each is joined onto both the mount point and the
    /// destination, so either could be escaped. Exposed for unit testing.
    static func validateSelectedEntries(_ entries: [String]) throws {
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.hasPrefix("/"), !components.contains("..") else {
                throw ArchiveEngineError.pathTraversalDetected(entry)
            }
        }
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
