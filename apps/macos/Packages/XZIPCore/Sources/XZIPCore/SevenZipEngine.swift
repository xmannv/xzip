import Foundation
import XZIPDomain

/// `ArchiveEngine` backed by the bundled `7zz` (7-Zip) console binary.
///
/// Design:
/// - **Strategy**: one concrete implementation of `ArchiveEngine`, selected by
///   `ArchiveEngineFactory` for the formats 7-Zip handles best.
/// - **Dependency Injection**: `ProcessControlling` and `BinaryLocating` are
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
private struct BoundedProgressLineParser {
    private let maximumLineByteCount: Int
    private var buffer = Data()

    init(maximumLineByteCount: Int) {
        self.maximumLineByteCount = maximumLineByteCount
    }

    mutating func consume(_ data: Data) throws -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A || byte == 0x0D || byte == 0x08 {
                if !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
                continue
            }
            guard buffer.count < maximumLineByteCount else {
                throw SevenZipListingParserError.physicalLineTooLong(
                    limit: maximumLineByteCount
                )
            }
            buffer.append(byte)
        }
        return lines
    }

    mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [String(decoding: buffer, as: UTF8.self)]
    }
}

public struct SevenZipEngine: ArchiveEngine {
    private let processController: any ProcessControlling
    private let locator: BinaryLocating
    private let policy: ArchiveResourcePolicy
    private let producerCompletion: (@Sendable () -> Void)?

    public init(
        runner: any ProcessControlling,
        locator: BinaryLocating,
        policy: ArchiveResourcePolicy = .production
    ) {
        self.processController = runner
        self.locator = locator
        self.policy = policy
        self.producerCompletion = nil
    }

    init(
        runner: any ProcessControlling,
        locator: BinaryLocating,
        policy: ArchiveResourcePolicy = .production,
        producerCompletion: @escaping @Sendable () -> Void
    ) {
        self.processController = runner
        self.locator = locator
        self.policy = policy
        self.producerCompletion = producerCompletion
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
        let producerCompletion = producerCompletion
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                defer { producerCompletion?() }
                var temporaryDirectories: [URL] = []
                var publicationWorkspace: URL?
                let usesAtomicPublication = options.existingFilePolicy == .fail
                let destinationPreexisted = FileManager.default.fileExists(
                    atPath: destination.path
                )
                var finishedSuccessfully = false
                defer {
                    for directory in temporaryDirectories.reversed() {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    if !finishedSuccessfully,
                       !usesAtomicPublication,
                       !destinationPreexisted {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }

                do {
                    guard options.format.canCompress else {
                        throw ArchiveEngineError.unsupportedFormat(options.format)
                    }
                    let destinationParent: AtomicDestinationInstaller
                        .DestinationParentHandle?
                    if usesAtomicPublication {
                        destinationParent = try AtomicDestinationInstaller
                            .prepareDestinationParent(
                                for: destination,
                                expectedIdentity: options.destinationParentIdentity
                            )
                    } else {
                        destinationParent = nil
                    }
                    let binary = try binaryPath()
                    let operationDestination: URL
                    if usesAtomicPublication {
                        let workspace = try FileManager.default.url(
                            for: .itemReplacementDirectory,
                            in: .userDomainMask,
                            appropriateFor: destination,
                            create: true
                        )
                        temporaryDirectories.append(workspace)
                        publicationWorkspace = workspace
                        operationDestination = workspace.appendingPathComponent(
                            destination.lastPathComponent
                        )
                    } else {
                        operationDestination = destination
                    }

                    let temporaryTar: URL
                    if options.format.requiresTarWrapper {
                        let directory: URL
                        if let publicationWorkspace {
                            directory = publicationWorkspace.appendingPathComponent(
                                "tar-workspace",
                                isDirectory: true
                            )
                            try FileManager.default.createDirectory(
                                at: directory,
                                withIntermediateDirectories: false
                            )
                        } else {
                            directory = try FileManager.default.url(
                                for: .itemReplacementDirectory,
                                in: .userDomainMask,
                                appropriateFor: destination,
                                create: true
                            )
                            temporaryDirectories.append(directory)
                        }
                        let logicalName = destination
                            .deletingPathExtension()
                            .deletingPathExtension()
                            .lastPathComponent
                        let safeName = logicalName.isEmpty ? "Archive" : logicalName
                        temporaryTar = directory.appendingPathComponent(safeName + ".tar")
                    } else {
                        temporaryTar = operationDestination
                    }

                    let stages = Self.compressionStages(
                        destination: operationDestination,
                        sources: sources,
                        options: options,
                        temporaryTar: temporaryTar
                    )
                    for (index, stage) in stages.enumerated() {
                        try Task.checkCancellation()
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
                            volumeIDs: processVolumeIDs(
                                for: stage.sources + [stage.destination]
                            ),
                            stageIndex: index,
                            stageCount: stages.count,
                            hadPassword: !(stage.options.password ?? "").isEmpty,
                            standardInput: stage.options.password ?? "",
                            withholdsTerminalCompletion:
                                usesAtomicPublication && index == stages.count - 1,
                            continuation: continuation
                        )
                    }

                    if let publicationWorkspace, let destinationParent {
                        let baseName = operationDestination.lastPathComponent
                        let artifacts = try FileManager.default.contentsOfDirectory(
                            at: publicationWorkspace,
                            includingPropertiesForKeys: nil,
                            options: []
                        ).filter {
                            let name = $0.lastPathComponent
                            return name == baseName || name.hasPrefix(baseName + ".")
                        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                        guard !artifacts.isEmpty else {
                            throw ArchiveEngineError.engineFailure(
                                "Compression produced no staged output."
                            )
                        }
                        for artifact in artifacts {
                            try Task.checkCancellation()
                            let suffix = artifact.lastPathComponent.dropFirst(baseName.count)
                            let finalName = destination.lastPathComponent + suffix
                            let finalURL = destination
                                .deletingLastPathComponent()
                                .appendingPathComponent(finalName)
                            try AtomicDestinationInstaller.installItem(
                                at: artifact,
                                to: finalURL,
                                destinationParent: destinationParent
                            )
                        }
                        continuation.yield(ArchiveProgress(fraction: 1))
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
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var entryListFile: URL?
                var publicationWorkspace: URL?
                defer {
                    if let entryListFile {
                        try? FileManager.default.removeItem(at: entryListFile)
                    }
                    if let publicationWorkspace {
                        try? FileManager.default.removeItem(at: publicationWorkspace)
                    }
                }
                // Whether the destination already existed before this operation.
                //
                // Except under `.fail`, 7zz writes straight into the destination
                // (the conflict policies are its own `-ao*` switches, which need
                // to see the real directory contents to uniquify or skip). It
                // creates each output file *before* it finds out it cannot
                // decrypt the data, so a failure part-way through leaves debris
                // behind — a wrong password used to leave 0-byte files sitting
                // in the destination, looking like a successful extraction.
                //
                // A destination this operation created is ours to remove on
                // failure. One that already existed is not: its other contents
                // belong to the user, so it is left alone.
                let destinationPreexisted = FileManager.default.fileExists(
                    atPath: destination.path
                )
                // Destination paths this operation may create, and which of them
                // already existed. Populated only when 7zz writes straight into
                // the destination, the only case that can leave debris there.
                var plannedPaths: [URL] = []
                var preexistingPaths: Set<String> = []

                do {
                    if !options.selectedEntries.isEmpty {
                        entryListFile = try SevenZipArchiveEditor.writeEntryListFile(
                            options.selectedEntries
                        )
                    }

                    let destinationParent: AtomicDestinationInstaller
                        .DestinationParentHandle?
                    let destinationRoot: AtomicDestinationInstaller
                        .DestinationRootHandle?
                    if options.existingFilePolicy == .fail {
                        let parent = try AtomicDestinationInstaller
                            .prepareDestinationParent(
                                for: destination,
                                expectedIdentity: options.destinationParentIdentity
                            )
                        destinationParent = parent
                        destinationRoot = try AtomicDestinationInstaller
                            .prepareDestinationRoot(
                                for: destination,
                                expectedIdentity: options.destinationRootIdentity,
                                destinationParent: parent
                            )
                    } else {
                        destinationParent = nil
                        destinationRoot = nil
                    }
                    let binary = try binaryPath()
                    let entries = try await list(
                        archive: archive,
                        password: options.password
                    )
                    try Self.validateNoPathTraversal(
                        entries: entries,
                        destination: destination
                    )
                    if options.existingFilePolicy == .fail,
                       let conflict = try Self.firstDestinationConflict(
                           entries: entries,
                           destination: destination,
                           selectedEntries: options.selectedEntries
                       ) {
                        throw ArchiveFailure.destinationConflict(path: conflict)
                    }

                    let operationDestination: URL
                    var operationOptions = options
                    if options.existingFilePolicy == .fail {
                        let workspace = try FileManager.default.url(
                            for: .itemReplacementDirectory,
                            in: .userDomainMask,
                            appropriateFor: destination,
                            create: true
                        )
                        publicationWorkspace = workspace
                        operationDestination = workspace.appendingPathComponent(
                            "extracted",
                            isDirectory: true
                        )
                        try FileManager.default.createDirectory(
                            at: operationDestination,
                            withIntermediateDirectories: false
                        )
                        operationOptions.existingFilePolicy = .replace
                    } else {
                        operationDestination = destination
                        // Deepest first, so removing debris takes files before
                        // the directories that contain them.
                        plannedPaths = entries
                            .map { destination.appendingPathComponent($0.path) }
                            .sorted { $0.pathComponents.count > $1.pathComponents.count }
                        preexistingPaths = Set(
                            plannedPaths
                                .map(\.path)
                                .filter { FileManager.default.fileExists(atPath: $0) }
                        )
                    }

                    let args = Self.extractionArguments(
                        archive: archive,
                        destination: operationDestination,
                        options: operationOptions,
                        entryListFile: entryListFile
                    )
                    try await runParsingProgress(
                        binary: binary,
                        arguments: args,
                        volumeIDs: processVolumeIDs(
                            for: [archive, operationDestination]
                        ),
                        hadPassword: !(options.password ?? "").isEmpty,
                        standardInput: options.password ?? "",
                        withholdsTerminalCompletion: destinationParent != nil,
                        continuation: continuation
                    )

                    if let destinationParent {
                        try Task.checkCancellation()
                        try AtomicDestinationInstaller.installDirectoryTree(
                            at: operationDestination,
                            to: destination,
                            destinationParent: destinationParent,
                            destinationRoot: destinationRoot
                        )
                        continuation.yield(ArchiveProgress(fraction: 1))
                    }
                    continuation.finish()
                } catch {
                    Self.removeExtractionDebris(
                        at: destination,
                        destinationPreexisted: destinationPreexisted,
                        plannedPaths: plannedPaths,
                        preexistingPaths: preexistingPaths
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Removes what a failed extraction wrote into the destination.
    ///
    /// Only reachable when 7zz extracted straight into the destination (every
    /// policy except `.fail`, which stages in a workspace and publishes
    /// atomically). 7zz creates each output file before it can tell whether the
    /// data decrypts, so a mid-flight failure leaves debris — most visibly a set
    /// of 0-byte files after a wrong password, which look like a successful
    /// extraction and hide the fact that nothing was really written.
    ///
    /// Deliberately conservative: it removes only paths this operation created.
    /// A destination that already existed keeps everything that was in it, so a
    /// failed "extract into my Documents folder" can never take user files with
    /// it.
    ///
    /// Known gap: under `.keepBoth`, 7zz uniquifies a colliding name (`a.txt` ->
    /// `a_1.txt`), and the new name is not derivable from the archive listing, so
    /// debris under a uniquified name into a *pre-existing* destination is not
    /// removed. Cleaning that up would mean diffing the whole destination tree
    /// before and after, which costs a full walk of a directory that may be
    /// large. The common case — extracting into a folder this operation created —
    /// is fully covered, because the whole folder is removed.
    static func removeExtractionDebris(
        at destination: URL,
        destinationPreexisted: Bool,
        plannedPaths: [URL],
        preexistingPaths: Set<String>
    ) {
        let manager = FileManager.default
        // Nothing was planned, so 7zz never wrote here (`.fail` staged elsewhere,
        // or the failure predates the extraction step).
        guard !plannedPaths.isEmpty else { return }

        // The whole directory is ours, debris and intermediate directories alike.
        guard destinationPreexisted else {
            try? manager.removeItem(at: destination)
            return
        }

        // `plannedPaths` arrives deepest-first, so files go before the
        // directories holding them.
        for path in plannedPaths where !preexistingPaths.contains(path.path) {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                // A directory may also hold files that were already there (or
                // that `.keepBoth` renamed), so remove it only once empty.
                let contents = try? manager.contentsOfDirectory(atPath: path.path)
                guard contents?.isEmpty ?? false else { continue }
            }
            try? manager.removeItem(at: path)
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
        case .fail:
            // Preflight above enforces fail semantics; this blocks a late race
            // from overwriting a destination created after the preflight.
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


    /// Whether 7zz will act on `path` given `selectedEntries`.
    ///
    /// An empty selection means "everything". Otherwise a path matches when it
    /// is named outright OR when it is a descendant of a named entry: passing a
    /// directory to 7zz extracts its whole subtree, so any caller reasoning
    /// about "what will be written" has to include those descendants. Deriving a
    /// `StagingWriteAuthority` from a selection that omits them makes the
    /// authority reject nodes the extractor itself created.
    ///
    /// This is the single definition of the rule; both the conflict pre-scan and
    /// the staging inventory use it so they can never disagree about which
    /// entries an extraction covers.
    static func isSelected(path: String, selection: Set<String>) -> Bool {
        selection.isEmpty
            || selection.contains(path)
            || selection.contains(where: { path.hasPrefix($0 + "/") })
    }

    static func firstDestinationConflict(
        entries: [ArchiveEntry],
        destination: URL,
        selectedEntries: [String]
    ) throws -> String? {
        let selected = Set(selectedEntries)
        for entry in entries where !entry.isDirectory {
            guard Self.isSelected(path: entry.path, selection: selected) else { continue }
            let target = try ArchivePathContainment.descendantDirectoryURL(
                root: destination,
                relativePath: entry.path
            )
            if FileManager.default.fileExists(atPath: target.path) {
                return target.path
            }
        }
        return nil
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
        var args = ["l", "-slt"]
        args.append("--")
        args.append(archive.path)

        let parserLimit = limit.map { $0 == Int.max ? Int.max : $0 + 1 }
        var parser = SevenZipIncrementalListingParser(entryLimit: parserLimit)
        let stream = processController.run(ProcessRequest(
            executable: binary,
            arguments: args,
            standardInput: password ?? "",
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        var requestedTermination = false
        var terminalResult: ProcessResult?

        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .stdout(let data):
                    guard !requestedTermination else { continue }
                    try parser.feed(data)
                    if parser.reachedEntryLimit {
                        requestedTermination = true
                        stream.requestTermination()
                    }
                case .stderr:
                    break
                case .terminated(let result):
                    terminalResult = result
                }
            }

            guard let terminalResult else {
                throw ProcessRunnerError.launchFailed(
                    "Process stream ended without a terminal result."
                )
            }
            if !terminalResult.isSuccess,
               !(requestedTermination && terminalResult.wasTerminatedByRequest) {
                throw Self.mapFailure(
                    stderr: terminalResult.standardError,
                    stdout: terminalResult.standardOutput,
                    hadPassword: !(password ?? "").isEmpty
                )
            }
            try Task.checkCancellation()
            try parser.finish()
        } catch ProcessRunnerError.cancelled where Task.isCancelled {
            throw CancellationError()
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
        let stream = processController.run(ProcessRequest(
            executable: binary,
            arguments: ["l", "-slt", "--", archive.path],
            standardInput: password ?? "",
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        var parser = IncrementalSevenZipCommentParser(
            maximumHeaderByteCount: policy.process.stdoutBufferByteCap
        )
        var comment: String?
        var terminalResult: ProcessResult?

        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .stdout(let data):
                    guard comment == nil else { continue }
                    if let parsedComment = try parser.consume(data) {
                        comment = parsedComment
                        stream.requestTermination()
                    }
                case .stderr:
                    break
                case .terminated(let result):
                    terminalResult = result
                }
            }

            guard let terminalResult else {
                throw ProcessRunnerError.launchFailed(
                    "Process stream ended without a terminal result."
                )
            }
            if !terminalResult.isSuccess,
               !(comment != nil && terminalResult.wasTerminatedByRequest) {
                throw Self.mapFailure(
                    stderr: terminalResult.standardError,
                    stdout: terminalResult.standardOutput,
                    hadPassword: !(password ?? "").isEmpty
                )
            }
            try Task.checkCancellation()
            if let comment { return comment }
            return try parser.finish()
        } catch ProcessRunnerError.cancelled where Task.isCancelled {
            throw CancellationError()
        }
    }

    // MARK: - Testing

    public func test(archive: URL, password: String?) async throws -> Bool {
        let binary = try binaryPath()
        var args = ["t"]
        args.append("--")
        args.append(archive.path)

        let result = try await processController.runBuffered(ProcessRequest(
            executable: binary,
            arguments: args,
            standardInput: password ?? "",
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        if result.isSuccess { return true }
        throw Self.mapFailure(
            stderr: result.standardError,
            stdout: result.standardOutput,
            hadPassword: !(password ?? "").isEmpty
        )
    }

    /// Checks `password` by decrypting the single smallest encrypted entry,
    /// rather than the whole archive as `test` does.
    ///
    /// This is what makes verifying on open affordable: `7zz t` decrypts every
    /// entry to check CRCs, so using it here would have made opening a large
    /// encrypted archive wait for a full decryption pass. Restricting the test to
    /// one small entry keeps the cost flat in archive size.
    ///
    /// Nothing encrypted means there is no password to be wrong, so it returns
    /// without running a test.
    public func verifyPassword(archive: URL, password: String?) async throws {
        let entries = try await list(archive: archive, password: password)
        // Directories carry no data to decrypt, so testing one proves nothing.
        let candidates = entries.filter { $0.isEncrypted && !$0.isDirectory }
        guard let probe = candidates.min(by: { $0.uncompressedSize < $1.uncompressedSize })
        else { return }

        let binary = try binaryPath()
        let entryListFile = try SevenZipArchiveEditor.writeEntryListFile([probe.path])
        defer { try? FileManager.default.removeItem(at: entryListFile) }

        let result = try await processController.runBuffered(ProcessRequest(
            executable: binary,
            arguments: ["t", "-i@" + entryListFile.path, "--", archive.path],
            standardInput: password ?? "",
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        if result.isSuccess { return }
        throw Self.mapFailure(
            stderr: result.standardError,
            stdout: result.standardOutput,
            hadPassword: !(password ?? "").isEmpty
        )
    }

    // MARK: - Helpers


    /// Runs a streaming 7-Zip command, translating `-bsp1` progress lines
    /// (e.g. " 42% 3 - file.txt") into `ArchiveProgress`.
    private func runParsingProgress(
        binary: String,
        arguments: [String],
        volumeIDs: Set<UInt64>,
        stageIndex: Int = 0,
        stageCount: Int = 1,
        hadPassword: Bool = false,
        standardInput: String? = nil,
        withholdsTerminalCompletion: Bool = false,
        continuation: AsyncThrowingStream<ArchiveProgress, Error>.Continuation
    ) async throws {
        let processStream = processController.run(ProcessRequest(
            executable: binary,
            arguments: arguments,
            standardInput: standardInput,
            workload: .heavyIO(volumeIDs: volumeIDs)
        ))
        let interval = max(0, policy.process.progressInterval)
        let derivedStream = AsyncThrowingStream<ArchiveProgress, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { derivedContinuation in
            let task = Task {
                var parser = BoundedProgressLineParser(
                    maximumLineByteCount: policy.process.stdoutBufferByteCap
                )
                var lastEmission: Date?

                func emit(_ lines: [String]) {
                    for line in lines {
                        guard let progress = SevenZipProgressParser.parse(line) else {
                            continue
                        }
                        let now = Date()
                        if let lastEmission,
                           now.timeIntervalSince(lastEmission) < interval {
                            continue
                        }
                        lastEmission = now
                        let stageCompletion =
                            Double(stageIndex + 1) / Double(stageCount)
                        let fraction = progress.fraction.map {
                            let mapped =
                                (Double(stageIndex) + $0) / Double(stageCount)
                            return mapped >= stageCompletion
                                ? stageCompletion.nextDown
                                : mapped
                        }
                        derivedContinuation.yield(ArchiveProgress(
                            fraction: fraction,
                            currentEntry: progress.currentEntry
                        ))
                    }
                }

                do {
                    for try await event in processStream {
                        try Task.checkCancellation()
                        switch event {
                        case .stdout(let data):
                            emit(try parser.consume(data))
                        case .stderr:
                            break
                        case .terminated(let result):
                            emit(parser.finish())
                            if result.isSuccess {
                                derivedContinuation.finish()
                            } else {
                                derivedContinuation.finish(throwing: Self.mapFailure(
                                    stderr: result.standardError,
                                    stdout: result.standardOutput,
                                    hadPassword: hadPassword
                                ))
                            }
                            return
                        }
                    }
                    derivedContinuation.finish(throwing: ProcessRunnerError.launchFailed(
                        "Process stream ended without a terminal result."
                    ))
                } catch ProcessRunnerError.cancelled where Task.isCancelled {
                    derivedContinuation.finish(throwing: CancellationError())
                } catch {
                    derivedContinuation.finish(throwing: error)
                }
            }
            derivedContinuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    task.cancel()
                    processStream.cancel()
                }
            }
        }

        for try await progress in derivedStream {
            try Task.checkCancellation()
            continuation.yield(progress)
        }
        try Task.checkCancellation()
        if !withholdsTerminalCompletion {
            continuation.yield(ArchiveProgress(
                fraction: Double(stageIndex + 1) / Double(stageCount)
            ))
        }
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

// MARK: - Transactional staging extraction

/// `ArchiveStagingExtracting` conformance: the Core-tier staging path used by
/// the transactional runtime. `freshExtractionInventory` produces an exact
/// node-kind inventory (needed to build a `StagingWriteAuthority`), and
/// `extractToEmptyStagingDirectory` extracts into a private empty staging
/// directory and then enforces that every staged node is authorized — refusing
/// to leave any unauthorized node behind. This is deliberately independent of
/// `XZIPRuntime`: SevenZip/DMG conform here without importing the runtime.
extension SevenZipEngine: ArchiveStagingExtracting {
    public func freshExtractionInventory(
        archive: URL,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        let binary = try binaryPath()
        let stream = processController.run(ProcessRequest(
            executable: binary,
            arguments: ["l", "-slt", "--", archive.path],
            standardInput: password ?? "",
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))

        // Bound accumulated `-slt` output so memory stays bounded while a
        // legitimate archive is never spuriously rejected. `-slt` prints, per
        // entry, the path (already budgeted by `totalPathByteCap`) PLUS a fixed
        // set of metadata lines (Size, Packed Size, Modified, Attributes, CRC,
        // Encrypted, Method, Block, blank separator). Budget that non-path
        // overhead separately at a generous per-entry allowance times the
        // maximum entry count; entry COUNT itself is capped downstream by
        // `ExtractionInventory.validated`.
        let metadataAllowancePerEntry = 512
        let byteCap = policy.listing.totalPathByteCap
            + policy.listing.listingHardCap * metadataAllowancePerEntry
        var accumulated = Data()
        var terminal: ProcessResult?

        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .stdout(let data):
                    guard accumulated.count + data.count <= byteCap else {
                        throw ArchiveEngineError.engineFailure(
                            "Listing output exceeded the allowed size."
                        )
                    }
                    accumulated.append(data)
                case .stderr:
                    break
                case .terminated(let result):
                    terminal = result
                }
            }
        } catch ProcessRunnerError.cancelled where Task.isCancelled {
            throw CancellationError()
        }

        guard let terminal else {
            throw ProcessRunnerError.launchFailed(
                "Process stream ended without a terminal result."
            )
        }
        guard terminal.isSuccess else {
            throw Self.mapFailure(
                stderr: terminal.standardError,
                stdout: terminal.standardOutput,
                hadPassword: !(password ?? "").isEmpty
            )
        }

        let output = String(decoding: accumulated, as: UTF8.self)
        var parsed = SevenZipInventoryParser.parse(output)
        if !selectedEntries.isEmpty {
            // Must match the extractor's own selection semantics exactly. Too
            // narrow (matching only the named paths) and the authority derived
            // from this inventory rejects the descendants 7zz writes for a
            // selected directory, failing the extraction; too broad and staging
            // would be authorized for nodes the archive never declared. The set
            // stays closed over the listing either way.
            let selected = Set(selectedEntries)
            parsed = parsed.filter { Self.isSelected(path: $0.path, selection: selected) }
        }
        return try ExtractionInventory.validated(
            entries: parsed,
            advertisedDictionaryByteCount: 0,
            policy: policy
        )
    }

    public func extractToEmptyStagingDirectory(
        archive: URL,
        destination: URL,
        selectedEntries: [String],
        authority: StagingWriteAuthority,
        preserveTimestamps: Bool,
        policy: ArchiveResourcePolicy,
        password: String?
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        // `preserveTimestamps` is honored by 7zz's default extraction behavior,
        // which restores archived modification times; there is no flag to
        // toggle it off here, so the parameter is accepted for protocol
        // conformance and the default (preserve) applies.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    // Staging is a private, empty, transaction-owned directory,
                    // so `.replace` is safe and matches the "write only the
                    // staged tree" contract.
                    let options = ExtractionOptions(
                        password: password,
                        selectedEntries: selectedEntries,
                        existingFilePolicy: .replace
                    )
                    let inner = self.extract(
                        archive: archive,
                        destination: destination,
                        options: options
                    )
                    let limit = policy.output.stagingByteCap
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await value in inner {
                                try Task.checkCancellation()
                                continuation.yield(value)
                            }
                        }
                        group.addTask {
                            while true {
                                try Task.checkCancellation()
                                _ = try Self.currentStagingCharge(
                                    root: destination,
                                    limit: limit
                                )
                                try await Task.sleep(for: .milliseconds(25))
                            }
                        }

                        do {
                            _ = try await group.next()
                            try Task.checkCancellation()
                            _ = try Self.currentStagingCharge(
                                root: destination,
                                limit: limit
                            )
                            group.cancelAll()
                            do {
                                while try await group.next() != nil {}
                            } catch is CancellationError {
                                // Expected monitor termination after extraction.
                            }
                        } catch {
                            group.cancelAll()
                            throw error
                        }
                    }
                    try Task.checkCancellation()
                    try Self.enforceStagingAuthority(
                        root: destination,
                        authority: authority
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

    private static func currentStagingCharge(
        root: URL,
        limit: UInt64
    ) throws -> UInt64 {
        let fileSystem = DarwinFileSystemOperations()
        let rootHandle = try fileSystem.openDirectoryNoFollow(at: root)
        defer { rootHandle.close() }

        func walk(
            _ directory: DirectoryHandle,
            current: UInt64
        ) throws -> UInt64 {
            var total = current
            for child in try fileSystem.listNoFollow(directory) {
                total = try StagingByteAccounting.adding(
                    current: total,
                    logical: child.byteCount,
                    allocated: child.allocatedByteCount,
                    limit: limit
                )
                guard child.identity.kind == .directory else { continue }
                do {
                    let childDirectory = try fileSystem.openDirectoryNoFollow(
                        parent: directory,
                        name: child.name,
                        expected: child.identity
                    )
                    defer { childDirectory.close() }
                    total = try walk(childDirectory, current: total)
                }
            }
            return total
        }

        return try walk(rootHandle, current: 0)
    }

    /// Walks the staged tree no-follow and rejects any node the authority does
    /// not permit (an extra file, a kind swap, an unauthorized directory).
    /// Symlinks are classified by their own identity and never traversed.
    ///
    /// Staged directories keep the mode the archive recorded. The transactional
    /// extraction layer repairs that mode when it adopts the tree, which is the
    /// only place the invariant can be guaranteed for a staging directory left
    /// behind by a failed, cancelled, or killed extraction.
    static func enforceStagingAuthority(
        root: URL,
        authority: StagingWriteAuthority
    ) throws {
        func walk(directory: URL, relative: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey
                ],
                options: []
            )
            for child in children {
                let name = child.lastPathComponent
                let childRelative = relative.isEmpty ? name : "\(relative)/\(name)"
                let values = try child.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey
                ])
                let kind: ExtractionNodeKind
                if values.isSymbolicLink == true {
                    // Check symlink FIRST: `.isDirectoryKey` follows the link.
                    kind = .symbolicLink
                } else if values.isDirectory == true {
                    kind = .directory
                } else {
                    kind = .regularFile
                }
                guard authority.isAuthorized(relativePath: childRelative, kind: kind) else {
                    throw ArchiveEngineError.engineFailure(
                        "Staged entry is not authorized: \(childRelative)"
                    )
                }
                if kind == .directory {
                    try walk(directory: child, relative: childRelative)
                }
            }
        }
        try walk(directory: root, relative: "")
    }
}
