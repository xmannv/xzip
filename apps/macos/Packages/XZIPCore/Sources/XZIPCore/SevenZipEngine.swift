import Foundation

/// `ArchiveEngine` backed by the bundled `7zz` (7-Zip) console binary.
///
/// Design:
/// - **Strategy**: one concrete implementation of `ArchiveEngine`, selected by
///   `ArchiveEngineFactory` for the formats 7-Zip handles best.
/// - **Dependency Injection**: `ProcessRunning` and `BinaryLocating` are
///   injected, so tests run against the repo binary and can stub execution.
///
/// Security considerations:
/// - Arguments are passed as an array (no shell), preventing injection.
/// - Passwords are fed to 7zz's interactive `Enter password:` prompt via STDIN
///   on every path — reading (extract/list/test) AND creating an encrypted
///   archive (`compress`) — so they never appear in argv where `ps` could read
///   them. For compression the `-p` switch is passed WITHOUT an inline value:
///   7-Zip 26.x then reads the new archive's password from the stdin prompt
///   (verified: the resulting archive is `Encrypted = +`), so no password byte
///   is ever placed on the command line.
/// - Extraction uses `-o` with an explicit destination; we additionally verify
///   listed entry paths to guard against path traversal (zip-slip), always
///   against a freshly read listing (never a caller-cached one).
public struct SevenZipEngine: ArchiveEngine {
    private let runner: ProcessRunning
    private let locator: BinaryLocating

    public init(runner: ProcessRunning, locator: BinaryLocating) {
        self.runner = runner
        self.locator = locator
    }

    public var supportedFormats: Set<ArchiveFormat> {
        [
            .zip, .sevenZip, .tar, .gzip, .bzip2, .xz, .zstd, .rar,
            .iso, .cab, .deb, .rpm, .cpio, .lzh, .wim, .chm, .arj, .xip,
            .unixCompress, .lzma, .udf, .squashfs
        ]
    }

    private func binaryPath() throws -> String {
        guard let path = locator.path(for: .sevenZip) else {
            throw BinaryLocatorError.notFound(.sevenZip)
        }
        return path
    }

    /// Returns the path with its last component spelled exactly as stored on
    /// disk. Foundation URLs NFD-decompose paths (`URL(fileURLWithPath:)`),
    /// while APFS preserves the creator's normalization and readdir returns the
    /// true bytes. Only the last component matters for archived names: 7zz
    /// stores the basename it was given and recurses into folders via readdir
    /// itself. Symlinks are deliberately not resolved. Falls back to the input
    /// when the parent cannot be listed (e.g. the file vanished).
    static func onDiskSpelling(of path: String) -> String {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let last = ns.lastPathComponent
        guard !parent.isEmpty, !last.isEmpty,
              let children = try? FileManager.default.contentsOfDirectory(atPath: parent),
              // Swift's == compares canonical equivalence, so an NFD `last`
              // matches the NFC on-disk spelling (and vice versa).
              let match = children.first(where: { $0 == last })
        else { return path }
        return parent + "/" + match
    }

    /// Relative-path variant of `onDiskSpelling`: respells EVERY component as
    /// stored on disk, because 7zz archives a relative path with all of its
    /// components as the in-archive name (an absolute source only contributes
    /// its basename).
    static func onDiskRelativeSpelling(of relativePath: String, base: URL) -> String {
        var currentDir = base.path
        var respelled: [String] = []
        for component in relativePath.split(separator: "/").map(String.init) {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: currentDir)) ?? []
            let match = children.first(where: { $0 == component }) ?? component
            respelled.append(match)
            currentDir += "/" + match
        }
        return respelled.joined(separator: "/")
    }

    // MARK: - Compression

    public func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var temporaryDirectory: URL?
                // If we create the destination file and then fail or get
                // cancelled, remove the half-written archive so the user is never
                // left with a corrupt file sitting at the chosen location that
                // looks like a valid archive. A file that already existed is left
                // untouched (the caller owns the overwrite decision).
                let destinationPreexisted = FileManager.default.fileExists(atPath: destination.path)
                var finishedSuccessfully = false
                defer {
                    if let temporaryDirectory {
                        try? FileManager.default.removeItem(at: temporaryDirectory)
                    }
                    if !finishedSuccessfully, !destinationPreexisted {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }

                do {
                    guard options.format.canCompress else {
                        throw ArchiveEngineError.unsupportedFormat(options.format)
                    }
                    let binary = try binaryPath()
                    let temporaryTar: URL
                    if options.format.requiresTarWrapper {
                        let directory = try FileManager.default.url(
                            for: .itemReplacementDirectory,
                            in: .userDomainMask,
                            appropriateFor: destination,
                            create: true
                        )
                        temporaryDirectory = directory
                        let logicalName = destination
                            .deletingPathExtension()
                            .deletingPathExtension()
                            .lastPathComponent
                        let safeName = logicalName.isEmpty ? "Archive" : logicalName
                        temporaryTar = directory.appendingPathComponent(safeName + ".tar")
                    } else {
                        temporaryTar = destination
                    }

                    let stages = Self.compressionStages(
                        destination: destination,
                        sources: sources,
                        options: options,
                        temporaryTar: temporaryTar
                    )
                    for (index, stage) in stages.enumerated() {
                        try Task.checkCancellation()
                        // See compressionArguments: source paths must travel via
                        // a listfile so their bytes reach 7zz un-normalized, and
                        // each last component is respelled as stored on disk
                        // (URL.path is already NFD-decomposed by Foundation).
                        let listFile = FileManager.default.temporaryDirectory
                            .appendingPathComponent("xzip-sources-\(UUID().uuidString).txt")
                        let sourcePaths = stage.sources.map { Self.onDiskSpelling(of: $0.path) }
                        try Data(sourcePaths.joined(separator: "\n").utf8)
                            .write(to: listFile)
                        defer { try? FileManager.default.removeItem(at: listFile) }
                        let args = Self.compressionArguments(
                            destination: stage.destination,
                            sources: stage.sources,
                            options: stage.options,
                            sourceListFile: listFile
                        )
                        try await runParsingProgress(
                            binary: binary,
                            arguments: args,
                            stageIndex: index,
                            stageCount: stages.count,
                            hadPassword: !(stage.options.password ?? "").isEmpty,
                            // Feed the password via stdin so it never lands in
                            // argv. Empty stdin (no password) sends EOF, so 7zz
                            // never blocks on the `Enter password:` prompt.
                            standardInput: stage.options.password ?? "",
                            continuation: continuation
                        )
                    }
                    finishedSuccessfully = true
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Builds `7zz a` arguments. Exposed internally for unit testing.
    struct CompressionStage: Equatable {
        let destination: URL
        let sources: [URL]
        let options: CompressionOptions
    }

    static func compressionStages(
        destination: URL,
        sources: [URL],
        options: CompressionOptions,
        temporaryTar: URL
    ) -> [CompressionStage] {
        guard options.format.requiresTarWrapper else {
            return [CompressionStage(destination: destination, sources: sources, options: options)]
        }

        var tarOptions = options
        tarOptions.format = .tar
        tarOptions.password = nil
        tarOptions.encryptFileNames = false
        tarOptions.volumeSize = nil

        var codecOptions = options
        codecOptions.password = nil
        codecOptions.encryptFileNames = false
        codecOptions.volumeSize = nil
        codecOptions.exclusionPatterns = []

        return [
            CompressionStage(destination: temporaryTar, sources: sources, options: tarOptions),
            CompressionStage(destination: destination, sources: [temporaryTar], options: codecOptions)
        ]
    }

    static func compressionArguments(
        destination: URL,
        sources: [URL],
        options: CompressionOptions,
        sourceListFile: URL
    ) -> [String] {
        var args = ["a", "-bsp1", "-bb0"]

        // Container type. `sevenZipTypeFlag` is the single source of truth for
        // the `-t` switch; it is nil only for formats 7zz cannot write (RAR/DMG/
        // extract-only), which never reach here because `canCompress` is false.
        if let typeFlag = options.format.sevenZipTypeFlag {
            args.append(typeFlag)
        }

        // Compression level.
        args.append("-mx=\(options.level.rawValue)")

        // Timestamps. 7z stores modification time by default; only 7z lets us
        // turn it off. Other containers (zip/tar) always keep mtime.
        if !options.preserveTimestamps, options.format == .sevenZip {
            args.append("-mtm=off")
        }

        // Encryption. `-p` is passed WITHOUT an inline value: the password is fed
        // via stdin (see the compress loop) so it never lands in argv where `ps`
        // could read it. 7zz reads it from its `Enter password:` prompt.
        if let password = options.password, !password.isEmpty,
           options.format.supportsEncryption {
            args.append("-p")
            if options.format == .sevenZip, options.encryptFileNames {
                args.append("-mhe=on")
            }
        }

        // Split volumes.
        if let volumeSize = options.volumeSize, options.format.supportsSplitting {
            args.append("-v\(volumeSize)b")
        }

        // Exclusions.
        for pattern in options.exclusionPatterns {
            args.append("-xr!\(pattern)")
        }

        // Source paths travel via a listfile, NOT argv: NSTask converts argv
        // through fileSystemRepresentation, which NFD-decomposes Unicode, so an
        // NFC-named source (git/curl/terminal-created) would be *stored* under
        // a mangled NFD name. The listfile bytes are written verbatim, keeping
        // the archived name identical to the on-disk one. `@listfile` expansion
        // requires that `--` is absent; that is safe here because every remaining
        // argv token is trusted (destination is an absolute path from the save
        // panel, the listfile path is ours). `-scsUTF-8` pins its charset.
        args.append("-scsUTF-8")
        args.append(destination.path)
        args.append("@\(sourceListFile.path)")
        return args
    }

    // MARK: - Extraction

    public func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let binary = try binaryPath()

                    // Guard against path traversal before writing anything, on a
                    // FRESH listing every time. A caller-supplied cached listing
                    // (`precomputedEntries`) is keyed only by path+mtime, so a
                    // TOCTOU swap of the archive file could smuggle `../` entries
                    // past a stale guard; the guard's freshness is a security
                    // invariant and must not depend on caller-cached data.
                    let entries = try await list(archive: archive, password: options.password)
                    try Self.validateNoPathTraversal(entries: entries, destination: destination)

                    // See extractionArguments: selected entries must travel via a
                    // listfile because NSTask NFD-normalizes argv. A name that
                    // itself contains a newline would split into two patterns and
                    // simply match nothing (fail closed).
                    var entryListFile: URL?
                    if !options.selectedEntries.isEmpty {
                        let listFile = FileManager.default.temporaryDirectory
                            .appendingPathComponent("xzip-entries-\(UUID().uuidString).txt")
                        try Data(options.selectedEntries.joined(separator: "\n").utf8)
                            .write(to: listFile)
                        entryListFile = listFile
                    }
                    defer {
                        if let entryListFile {
                            try? FileManager.default.removeItem(at: entryListFile)
                        }
                    }

                    let args = Self.extractionArguments(
                        archive: archive,
                        destination: destination,
                        options: options,
                        entryListFile: entryListFile
                    )
                    try await runParsingProgress(
                        binary: binary,
                        arguments: args,
                        hadPassword: !(options.password ?? "").isEmpty,
                        // Feed the password via stdin so it never lands in argv.
                        standardInput: options.password ?? "",
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    static func extractionArguments(
        archive: URL,
        destination: URL,
        options: ExtractionOptions,
        entryListFile: URL?
    ) -> [String] {
        // `x` preserves full paths (vs `e` which flattens). `-spd` disables
        // wildcard matching so a selected in-archive entry named e.g.
        // `photo?.jpg` extracts only itself, never every pattern-matching sibling.
        var args = ["x", "-bsp1", "-bb0", "-spd"]
        args.append("-o\(destination.path)")
        switch options.existingFilePolicy {
        case .replace:
            args.append("-aoa")
        case .keepBoth:
            args.append("-aou")
        case .skip:
            args.append("-aos")
        }
        // Selected entry names are passed via a listfile, NEVER on argv: NSTask
        // converts argv through fileSystemRepresentation, which NFD-decomposes
        // Unicode (e.g. Vietnamese NFC names from a Windows/web zip), while 7zz
        // matches entry names byte-exactly — the argv form would silently match
        // nothing. The listfile bytes are written verbatim, so the exact
        // normalization stored in the archive reaches 7zz. `-scsUTF-8` pins the
        // listfile charset regardless of locale.
        if let entryListFile {
            args.append("-scsUTF-8")
            args.append("-i@\(entryListFile.path)")
        }
        // The password is NOT placed on argv (where `ps` could read it); it is
        // fed to 7zz's `Enter password:` prompt via stdin by the caller. An empty
        // stdin (no password) sends EOF, so 7zz never blocks on the prompt.
        // `--` stops switch parsing; entry names live in the listfile, so a name
        // beginning with `-`/`@` (attacker-controlled, coming from the archive
        // listing) can never be reinterpreted as a 7zz switch (e.g. `-o<path>`).
        args.append("--")
        args.append(archive.path)
        return args
    }

    /// Blocks entries that would escape the destination directory.
    static func validateNoPathTraversal(entries: [ArchiveEntry], destination: URL) throws {
        // Two string checks fully cover directory escape: reject any absolute
        // path, and reject any `..` component. They are STRICTER than resolving
        // each path against the destination (which would still permit a harmless
        // `a/../a`), so the previous per-entry URL-standardization pass — an O(n)
        // allocation cost that dominated on large listings — added no security
        // and has been removed. `destination` is retained for API stability.
        for entry in entries {
            guard !entry.path.hasPrefix("/") else {
                throw ArchiveEngineError.pathTraversalDetected(entry.path)
            }
            let pathComponents = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !pathComponents.contains("..") else {
                throw ArchiveEngineError.pathTraversalDetected(entry.path)
            }
        }
    }

    // MARK: - Listing

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
        let binary = try binaryPath()
        // No `-p` on argv: the password is fed via stdin (empty stdin → EOF, so
        // 7zz never blocks on its prompt) so it can't be read from `ps`.
        var args = ["l", "-slt"]
        args.append("--")
        args.append(archive.path)

        let parserLimit = limit.map { $0 == Int.max ? Int.max : $0 + 1 }
        var parser = SevenZipIncrementalListingParser(entryLimit: parserLimit)
        let stream = runner.runRawStreaming(
            executable: binary,
            arguments: args,
            workingDirectory: nil,
            environment: nil,
            standardInput: password ?? ""
        )

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                guard case .stdout(let data) = chunk else { continue }
                try parser.feed(data)
                if parser.reachedEntryLimit { break }
            }
            try Task.checkCancellation()
            try parser.finish()
        } catch ProcessRunnerError.cancelled where Task.isCancelled {
            throw CancellationError()
        } catch ProcessRunnerError.nonZeroExit(_, let standardError) {
            throw Self.mapFailure(
                stderr: standardError,
                stdout: "",
                hadPassword: !(password ?? "").isEmpty
            )
        }

        guard let limit else {
            return ArchiveListingResult(entries: parser.entries, truncated: false)
        }
        return ArchiveListingResult(
            entries: Array(parser.entries.prefix(limit)),
            truncated: parser.entries.count > limit
        )
    }


    // MARK: - Comment (read-only)

    public func readComment(archive: URL, password: String?) async throws -> String {
        let binary = try binaryPath()
        // Same `l -slt` listing as `list`, but we only want the archive-level
        // `Comment` property from the header block (works for ZIP and RAR).
        let result = try await runner.run(
            executable: binary,
            arguments: ["l", "-slt", "--", archive.path],
            workingDirectory: nil,
            environment: nil,
            standardInput: password ?? ""
        )
        guard result.isSuccess else {
            throw Self.mapFailure(
                stderr: result.standardError, stdout: result.standardOutput,
                hadPassword: !(password ?? "").isEmpty)
        }
        return SevenZipListingParser.parseArchiveComment(result.standardOutput)
    }

    // MARK: - Testing

    public func test(archive: URL, password: String?) async throws -> Bool {
        let binary = try binaryPath()
        // Password via stdin, not argv (see `list`).
        var args = ["t"]
        args.append("--")
        args.append(archive.path)

        let result = try await runner.run(
            executable: binary,
            arguments: args,
            workingDirectory: nil,
            environment: nil,
            standardInput: password ?? ""
        )
        if result.isSuccess { return true }
        throw Self.mapFailure(
            stderr: result.standardError, stdout: result.standardOutput,
            hadPassword: !(password ?? "").isEmpty)
    }

    // MARK: - Helpers

    /// Runs a streaming 7-Zip command, translating `-bsp1` progress lines
    /// (e.g. " 42% 3 - file.txt") into `ArchiveProgress`.
    private func runParsingProgress(
        binary: String,
        arguments: [String],
        stageIndex: Int = 0,
        stageCount: Int = 1,
        hadPassword: Bool = false,
        standardInput: String? = nil,
        continuation: AsyncThrowingStream<ArchiveProgress, Error>.Continuation
    ) async throws {
        let stream = runner.runStreaming(
            executable: binary,
            arguments: arguments,
            workingDirectory: nil,
            environment: nil,
            standardInput: standardInput
        )
        var stderrAccumulator = ""
        do {
            for try await line in stream {
                try Task.checkCancellation()
                switch line {
                case .stdout(let text):
                    if let progress = SevenZipProgressParser.parse(text) {
                        let fraction = progress.fraction.map {
                            (Double(stageIndex) + $0) / Double(stageCount)
                        }
                        continuation.yield(
                            ArchiveProgress(fraction: fraction, currentEntry: progress.currentEntry)
                        )
                    }
                case .stderr(let text):
                    stderrAccumulator += text + "\n"
                }
            }
        } catch {
            if case ProcessRunnerError.nonZeroExit = error {
                throw Self.mapFailure(stderr: stderrAccumulator, stdout: "", hadPassword: hadPassword)
            }
            throw error
        }
        continuation.yield(
            ArchiveProgress(fraction: Double(stageIndex + 1) / Double(stageCount))
        )
    }

    /// Maps 7-Zip stderr text to a specific `ArchiveEngineError`.
    ///
    /// `hadPassword` distinguishes "the user's password was wrong" from "this
    /// archive is encrypted and no password was supplied yet": 7zz probes with
    /// an empty `-p` and reports "wrong password" in both cases, so without this
    /// flag a first-open of an encrypted archive would be mislabelled as an
    /// incorrect-password error. Mirrors `DMGEngine.mapAttachFailure`.
    static func mapFailure(stderr: String, stdout: String, hadPassword: Bool = false) -> ArchiveEngineError {
        let haystack = (stderr + "\n" + stdout).lowercased()
        if haystack.contains("wrong password") || haystack.contains("can not open encrypted archive. wrong password") {
            return hadPassword ? .wrongPassword : .passwordRequired
        }
        if haystack.contains("is not archive") || haystack.contains("cannot open the file as archive") {
            return .corruptedArchive(stderr.isEmpty ? stdout : stderr)
        }
        if haystack.contains("crc failed") || haystack.contains("data error") {
            return .corruptedArchive(stderr.isEmpty ? stdout : stderr)
        }
        if haystack.contains("enter password") {
            return .passwordRequired
        }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .engineFailure(detail.isEmpty ? "7-Zip failed." : detail)
    }
}
