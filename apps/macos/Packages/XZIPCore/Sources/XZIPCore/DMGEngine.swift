import Foundation
import XZIPDomain

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
public struct DMGEngine: ArchiveEngine, ArchiveStagingExtracting {
    private let processController: any ProcessControlling
    private let stagingCopier: DMGStagingCopier
    private let makeDirectoryIterator: @Sendable (
        URL,
        [URLResourceKey]
    ) -> any DMGDirectoryIterating
    private let afterAttachTermination: @Sendable () async -> Void
    private let hdiutil = "/usr/bin/hdiutil"

    public init(
        runner: any ProcessControlling = ProcessController(
            policy: .production,
            permits: LocalProcessPermitPool(
                limit: ArchiveResourcePolicy.production.scheduling.globalProcessLimit
            )
        )
    ) {
        self.processController = runner
        self.stagingCopier = DMGStagingCopier(
            fileSystem: DarwinFileSystemOperations()
        )
        self.makeDirectoryIterator = { mountPoint, keys in
            FileManagerDMGDirectoryIterator(mountPoint: mountPoint, keys: keys)
        }
        self.afterAttachTermination = {}
    }

    init(
        runner: any ProcessControlling,
        makeDirectoryIterator: @escaping @Sendable (
            URL,
            [URLResourceKey]
        ) -> any DMGDirectoryIterating,
        afterAttachTermination: @escaping @Sendable () async -> Void = {},
        fileSystem: any FileSystemOperations & FileTimestampOperations =
            DarwinFileSystemOperations()
    ) {
        self.processController = runner
        self.stagingCopier = DMGStagingCopier(fileSystem: fileSystem)
        self.makeDirectoryIterator = makeDirectoryIterator
        self.afterAttachTermination = afterAttachTermination
    }

    public var supportedFormats: Set<ArchiveFormat> { [.dmg] }

    // MARK: - Compress (create a UDZO disk image from sources)

    public func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var publicationWorkspace: URL?
                // Only `.replace` may write straight at the destination: it is
                // the one policy whose contract is "destroy what is there".
                //
                // Previously this was `== .fail`, so `.skip` and `.keepBoth`
                // pointed `hdiutil create -ov` directly at the destination and
                // deleted the user's existing image — the exact outcome both
                // policies exist to prevent. Every non-`.replace` policy now
                // builds into a workspace and decides at publication time, using
                // an exclusive rename so the decision cannot be raced.
                let usesAtomicPublication = options.existingFilePolicy != .replace
                let destinationPreexisted = FileManager.default.fileExists(
                    atPath: destination.path
                )

                // `.skip` means "leave the existing image alone", so there is no
                // point building a possibly multi-gigabyte image just to discard
                // it. Publication still re-checks, which covers the file
                // appearing after this point.
                if options.existingFilePolicy == .skip, destinationPreexisted {
                    continuation.yield(ArchiveProgress(fraction: 1))
                    continuation.finish()
                    return
                }
                var finishedSuccessfully = false
                defer {
                    if let publicationWorkspace {
                        try? FileManager.default.removeItem(at: publicationWorkspace)
                    }
                    if !finishedSuccessfully,
                       !usesAtomicPublication,
                       !destinationPreexisted {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
                do {
                    let destinationParent = try usesAtomicPublication
                        ? AtomicDestinationInstaller.prepareDestinationParent(
                            for: destination,
                            expectedIdentity: options.destinationParentIdentity
                        )
                        : nil
                    continuation.yield(.indeterminate)
                    let (srcFolder, cleanup) = try Self.stageSources(sources)
                    defer { cleanup() }

                    let operationDestination: URL
                    if usesAtomicPublication {
                        let workspace = try FileManager.default.url(
                            for: .itemReplacementDirectory,
                            in: .userDomainMask,
                            appropriateFor: destination,
                            create: true
                        )
                        publicationWorkspace = workspace
                        operationDestination = workspace.appendingPathComponent(
                            destination.lastPathComponent
                        )
                    } else {
                        operationDestination = destination
                    }

                    let volName = destination.deletingPathExtension().lastPathComponent
                    let result = try await processController.runBuffered(ProcessRequest(
                        executable: hdiutil,
                        arguments: [
                            "create",
                            "-volname", volName,
                            "-srcfolder", srcFolder.path,
                            "-ov",
                            "-format", "UDZO",
                            operationDestination.path
                        ],
                        workload: .heavyIO(volumeIDs: processVolumeIDs(
                            for: sources + [operationDestination]
                        ))
                    ))
                    guard result.isSuccess else {
                        throw ArchiveEngineError.engineFailure(result.standardError)
                    }
                    if let destinationParent {
                        try Task.checkCancellation()
                        try Self.publishCreatedImage(
                            at: operationDestination,
                            to: destination,
                            destinationParent: destinationParent,
                            policy: options.existingFilePolicy
                        )
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

    // MARK: - Transactional staging extraction

    public func freshExtractionInventory(
        archive: URL,
        selectedEntries: [String],
        password: String?,
        policy: ArchiveResourcePolicy
    ) async throws -> ExtractionInventory {
        let mountPoint = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let workload = ProcessWorkload.metadata(
            volumeIDs: processVolumeIDs(for: [archive, mountPoint])
        )
        return try await withAttachedMount(
            archive: archive,
            mountPoint: mountPoint,
            password: password,
            workload: workload
        ) {
            try Task.checkCancellation()
            return try stagingCopier.inventory(
                mountPoint: mountPoint,
                selectedEntries: selectedEntries,
                policy: policy
            )
        }
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
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let mountPoint: URL
                do {
                    mountPoint = try Self.makeTempDirectory()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer { try? FileManager.default.removeItem(at: mountPoint) }

                do {
                    continuation.yield(.indeterminate)
                    let workload = ProcessWorkload.heavyIO(
                        volumeIDs: processVolumeIDs(for: [archive, destination])
                    )
                    try await withAttachedMount(
                        archive: archive,
                        mountPoint: mountPoint,
                        password: password,
                        workload: workload
                    ) {
                        try Task.checkCancellation()
                        try stagingCopier.copy(
                            mountPoint: mountPoint,
                            destination: destination,
                            selectedEntries: selectedEntries,
                            authority: authority,
                            preserveTimestamps: preserveTimestamps,
                            policy: policy
                        )
                        try Task.checkCancellation()
                    }
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
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var publicationWorkspace: URL?
                let mountPoint: URL
                do {
                    mountPoint = try Self.makeTempDirectory()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                defer {
                    if let publicationWorkspace {
                        try? FileManager.default.removeItem(at: publicationWorkspace)
                    }
                    try? FileManager.default.removeItem(at: mountPoint)
                }

                do {
                    let usesAtomicPublication =
                        options.existingFilePolicy == .fail
                    let destinationParent: AtomicDestinationInstaller
                        .DestinationParentHandle?
                    let destinationRoot: AtomicDestinationInstaller
                        .DestinationRootHandle?
                    if usesAtomicPublication {
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

                    let operationDestination: URL
                    var operationOptions = options
                    if usesAtomicPublication {
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
                    }

                    continuation.yield(.indeterminate)
                    let workload = ProcessWorkload.heavyIO(
                        volumeIDs: processVolumeIDs(for: [archive, destination])
                    )
                    try await withAttachedMount(
                        archive: archive,
                        mountPoint: mountPoint,
                        password: options.password,
                        workload: workload
                    ) {
                        try Task.checkCancellation()
                        try Self.copyMountedContents(
                            from: mountPoint,
                            to: operationDestination,
                            options: operationOptions
                        )
                    }

                    if let destinationParent {
                        try Task.checkCancellation()
                        try AtomicDestinationInstaller.installDirectoryTree(
                            at: operationDestination,
                            to: destination,
                            destinationParent: destinationParent,
                            destinationRoot: destinationRoot
                        )
                    }
                    continuation.yield(ArchiveProgress(fraction: 1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    private static func copyMountedContents(
        from mountPoint: URL,
        to destination: URL,
        options: ExtractionOptions
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let jobs: [(source: URL, target: URL)]
        if options.selectedEntries.isEmpty {
            jobs = try fileManager.contentsOfDirectory(
                at: mountPoint,
                includingPropertiesForKeys: nil
            ).map {
                ($0, destination.appendingPathComponent($0.lastPathComponent))
            }
        } else {
            try validateSelectedEntries(options.selectedEntries)
            jobs = options.selectedEntries.map {
                (
                    mountPoint.appendingPathComponent($0),
                    destination.appendingPathComponent($0)
                )
            }
            // A selection names its entries explicitly, so one that is absent
            // from the mounted volume is a failure rather than something to pass
            // over: the loop below skips any missing source, which would
            // otherwise report success with an empty destination. Checked up
            // front so a partial tree is never left behind either.
            //
            // The whole-volume branch above deliberately has no equivalent
            // check. An empty destination is the correct outcome for a disk
            // image that genuinely contains nothing, and `contentsOfDirectory`
            // cannot distinguish that from an unexpected mount.
            let missing = options.selectedEntries.filter {
                !fileManager.fileExists(
                    atPath: mountPoint.appendingPathComponent($0).path
                )
            }
            if !missing.isEmpty {
                throw ArchiveEngineError.missingSelectedEntries(entries: missing)
            }
        }

        for job in jobs {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: job.source.path) else {
                continue
            }
            try fileManager.createDirectory(
                at: job.target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let exists = fileManager.fileExists(atPath: job.target.path)
            switch options.existingFilePolicy {
            case .replace:
                if exists {
                    try fileManager.removeItem(at: job.target)
                }
                try fileManager.copyItem(at: job.source, to: job.target)
            case .skip:
                if !exists {
                    try fileManager.copyItem(at: job.source, to: job.target)
                }
            case .keepBoth:
                try fileManager.copyItem(
                    at: job.source,
                    to: exists ? uniqueURL(for: job.target) : job.target
                )
            case .fail:
                if exists {
                    throw ArchiveFailure.destinationConflict(
                        path: job.target.path
                    )
                }
                try fileManager.copyItem(at: job.source, to: job.target)
            }
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

        let workload = ProcessWorkload.metadata(
            volumeIDs: processVolumeIDs(for: [archive, mountPoint])
        )
        return try await withAttachedMount(
            archive: archive,
            mountPoint: mountPoint,
            password: password,
            workload: workload
        ) {
            try enumerateEntries(at: mountPoint, limit: limit)
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
        let hasPassword = !(password ?? "").isEmpty
        var arguments = ["verify"]
        if hasPassword { arguments.append("-stdinpass") }
        arguments.append(archive.path)

        let result = try await processController.runBuffered(ProcessRequest(
            executable: hdiutil,
            arguments: arguments,
            standardInput: hasPassword ? password : nil,
            workload: .metadata(volumeIDs: processVolumeIDs(for: [archive]))
        ))
        if result.isSuccess { return true }
        // Throwing rather than returning false, which matches `SevenZipEngine.test`
        // and is what callers need. `false` collapsed every cause into one
        // outcome, and the UI renders it as "Archive failed the integrity test" —
        // so testing an encrypted image with the wrong password told the user
        // their file was damaged, with no way to retry.
        throw Self.mapHDIUtilFailure(result.standardError, hadPassword: hasPassword)
    }


    private func detach(
        _ mountPoint: URL,
        workload: ProcessWorkload
    ) async throws {
        let result = try await runDetach(mountPoint, workload: workload)
        try Task.checkCancellation()
        guard result.isSuccess else {
            throw ArchiveEngineError.engineFailure(result.standardError)
        }
    }


    private func withAttachedMount<T>(
        archive: URL,
        mountPoint: URL,
        password: String?,
        workload: ProcessWorkload,
        operation: () async throws -> T
    ) async throws -> T {
        // Attach stays inside the do/catch on purpose. A failed `hdiutil attach`
        // does not mean nothing was mounted: attach can create the device node and
        // then fail at a later stage, and under cancellation the process is
        // terminated when the volume may already be attached. Detaching after a
        // failure is cleanup for those partial states, not a wasted process, and
        // `hdiutil detach -force` on nothing is harmless. See
        // DMGEngineListingTests for the cancellation cases this protects.
        do {
            try await attach(
                archive,
                mountPoint: mountPoint,
                password: password,
                workload: workload
            )
            let value = try await operation()
            try await detach(mountPoint, workload: workload)
            return value
        } catch {
            await detachBestEffort(mountPoint, workload: workload)
            throw error
        }
    }

    private func detachBestEffort(
        _ mountPoint: URL,
        workload: ProcessWorkload
    ) async {
        _ = try? await runDetach(mountPoint, workload: workload)
    }

    private func runDetach(
        _ mountPoint: URL,
        workload: ProcessWorkload
    ) async throws -> ProcessResult {
        let processController = self.processController
        let hdiutil = self.hdiutil
        return try await Task.detached {
            try await processController.runBuffered(ProcessRequest(
                executable: hdiutil,
                arguments: ["detach", mountPoint.path, "-force"],
                workload: workload
            ))
        }.value
    }

    /// Attaches `archive` read-only at `mountPoint`. For an encrypted image the
    /// passphrase is piped via stdin (`-stdinpass`) so it never appears in argv
    /// (where `ps` could read it).
    private func attach(
        _ archive: URL,
        mountPoint: URL,
        password: String?,
        workload: ProcessWorkload
    ) async throws {
        var args = ["attach", archive.path, "-nobrowse", "-readonly",
                    "-mountpoint", mountPoint.path]
        let hasPassword = !(password ?? "").isEmpty
        if hasPassword { args.append("-stdinpass") }

        let stream = processController.run(ProcessRequest(
            executable: hdiutil,
            arguments: args,
            standardInput: hasPassword ? password : nil,
            workload: workload
        ))
        let terminalTask = Task.detached {
            for try await event in stream {
                if case .terminated(let result) = event { return result }
            }
            throw ProcessRunnerError.launchFailed(
                "Process stream ended without a terminal result."
            )
        }
        let result: ProcessResult
        do {
            result = try await withTaskCancellationHandler {
                try await terminalTask.value
            } onCancel: {
                stream.requestTermination()
            }
        } catch ProcessRunnerError.cancelled where Task.isCancelled {
            throw CancellationError()
        }

        await afterAttachTermination()
        if !result.isSuccess, !result.wasTerminatedByRequest {
            throw Self.mapHDIUtilFailure(result.standardError, hadPassword: hasPassword)
        }
        try Task.checkCancellation()
        guard result.isSuccess else {
            throw Self.mapHDIUtilFailure(result.standardError, hadPassword: hasPassword)
        }
    }

    /// Classifies an `hdiutil` failure (from `attach` or `verify`),
    /// distinguishing encryption/passphrase errors so the UI can prompt for (or
    /// re-prompt for) a password.
    ///
    /// Mirrored by `SevenZipEngine.mapFailure`. Internal rather than private so
    /// the classification can be unit tested directly, as `uniqueURL` is.
    static func mapHDIUtilFailure(
        _ stderr: String,
        hadPassword: Bool
    ) -> ArchiveEngineError {
        let h = stderr.lowercased()

        // Unambiguous encryption signals: report a password problem regardless of
        // whether one was supplied, so the caller can prompt.
        let statesEncryption = h.contains("authentication error")
            || h.contains("passphrase")
            || h.contains("password")
        if statesEncryption {
            return hadPassword ? .wrongPassword : .passwordRequired
        }

        // "corrupt image" is genuinely ambiguous: hdiutil emits it both for a bad
        // passphrase and for an image that is actually damaged. Treating it as an
        // encryption signal unconditionally meant a corrupt *unencrypted* image
        // was reported as needing a password, leaving the user to retype a
        // password that was never the problem.
        //
        // Resolved by what the caller did: a password was supplied, so "wrong
        // password" is the likely explanation and is retryable. With no password
        // supplied there is nothing to suggest encryption, so report corruption.
        if h.contains("corrupt image") {
            return hadPassword ? .wrongPassword : .corruptedArchive(stderr)
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

    /// Moves a freshly created image from its workspace to `destination`,
    /// applying `policy` when the destination name is already taken.
    ///
    /// The conflict is always detected by the exclusive rename inside
    /// `installItem` rather than by a preceding `fileExists` check, so a file
    /// appearing between the check and the move cannot be silently clobbered.
    /// That is why each policy is expressed as a *reaction* to
    /// `destinationConflict` instead of a pre-flight branch.
    private static func publishCreatedImage(
        at source: URL,
        to destination: URL,
        destinationParent: AtomicDestinationInstaller.DestinationParentHandle,
        policy: ExistingFilePolicy
    ) throws {
        switch policy {
        case .fail:
            try AtomicDestinationInstaller.installItem(
                at: source,
                to: destination,
                destinationParent: destinationParent
            )

        case .skip:
            do {
                try AtomicDestinationInstaller.installItem(
                    at: source,
                    to: destination,
                    destinationParent: destinationParent
                )
            } catch ArchiveFailure.destinationConflict {
                // The existing image wins; the staged copy is discarded by the
                // caller's workspace cleanup.
                return
            }

        case .keepBoth:
            // `uniqueURL` is a check-then-create guess, so another process can
            // take the name first. Retry on conflict instead of trusting the
            // guess; bounded so a directory being filled concurrently cannot
            // spin here forever.
            var attempt = 0
            let maximumAttempts = 100
            var candidate = destination
            while true {
                do {
                    try AtomicDestinationInstaller.installItem(
                        at: source,
                        to: candidate,
                        destinationParent: destinationParent
                    )
                    return
                } catch ArchiveFailure.destinationConflict {
                    attempt += 1
                    guard attempt < maximumAttempts else {
                        throw ArchiveFailure.destinationConflict(
                            path: candidate.path
                        )
                    }
                    candidate = uniqueURL(for: destination)
                }
            }

        case .replace:
            // `.replace` writes straight at the destination and never builds a
            // workspace, so it never reaches publication. Handled explicitly
            // rather than via `default` so adding a policy is a compile error
            // here instead of a silent fallthrough.
            try AtomicDestinationInstaller.installItem(
                at: source,
                to: destination,
                destinationParent: destinationParent
            )
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

    /// Creates a private scratch directory used as a DMG mount point or as
    /// staging for image creation.
    ///
    /// The mode is explicit because the default (0755 after a typical umask) made
    /// these world-readable, and a mount point exposes the *decrypted* contents of
    /// an encrypted image for as long as it stays mounted — readable by every
    /// local user on a shared Mac. `withIntermediateDirectories: false` so the
    /// requested permissions are the ones actually applied: the intermediate form
    /// silently succeeds on an existing directory, which would leave whatever
    /// mode that directory already had. The UUID makes a collision the real
    /// error it would be.
    ///
    /// Internal rather than private so the mode can be asserted directly.
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}
