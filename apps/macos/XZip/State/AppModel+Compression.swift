import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore
import XZIPDomain

extension AppModel {
    // MARK: - Compression

    /// Kick off a real compression of the current inputs using the draft
    /// settings, tracking progress in `operations`.
    /// - Parameter quiet: when true (one-shot Finder compress) the post-compress
    ///   Share card is suppressed so the user isn't interrupted by a dialog.
    func startCompression(quiet: Bool = false, archiveName: String? = nil) {
        let sources = compressionInputs.map(\.url)
        guard let first = sources.first else { return }

        let coreOptions = ModelMapping.compressionOptions(
            format: selectedFormat,
            level: selectedLevel,
            password: encryptionEnabled ? compressionPassword : nil,
            splitSizeMB: splitArchiveEnabled ? splitSizeMB : nil,
            excludeMacNoise: excludeMacNoise,
            preserveTimestamps: XZIPDefaults.preservesTimestamps
        )
        // Use the UI format's on-disk extension (e.g. "tar.gz"), not the core
        // codec's single extension ("gz"): a tar.gz written as "Photos.gz" can't
        // be reopened for editing and breaks tools that key off ".tar.gz".
        let ext = selectedFormat.fileExtension
        // Prefer the name the user typed in the sheet's "Save As" field; fall
        // back to deriving one from the source. Drop a trailing extension the
        // user may have typed that already matches the chosen format.
        let derivedBaseName = sources.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        let proposedBaseName: String = {
            guard let typed = archiveName, !typed.isEmpty else { return derivedBaseName }
            // Strip a trailing extension the user typed that already matches the
            // chosen format — including a compound one like ".tar.gz" (NSString
            // .pathExtension only sees ".gz", so compare the whole suffix).
            let suffix = "." + ext.lowercased()
            return typed.lowercased().hasSuffix(suffix)
                ? String(typed.dropLast(suffix.count))
                : typed
        }()
        let validatedBaseName: String
        do {
            validatedBaseName = try ArchiveComponentValidator.validate(proposedBaseName)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Choose the folder to write into. Normally it's alongside the source,
        // but files shared via the Share extension are staged inside the (hidden)
        // App Group container — writing the archive there would bury it out of
        // sight and, worse, `pruneSharedInbox` would later delete it. Redirect
        // those to Downloads so the result is actually reachable.
        let sourceDir = first.deletingLastPathComponent()
        let destinationDir: URL = {
            if let container = XZIPAppGroup.containerURL,
               sourceDir.standardizedFileURL.path.hasPrefix(container.standardizedFileURL.path) {
                return FileManager.default
                    .urls(for: .downloadsDirectory, in: .userDomainMask).first ?? sourceDir
            }
            return sourceDir
        }()
        let proposedDestination: URL
        do {
            proposedDestination = try ArchivePathContainment.childURL(
                parent: destinationDir,
                component: "\(validatedBaseName).\(ext)"
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Never write onto an existing archive: `7zz a` would UPDATE it (merging
        // in stale entries and possibly leaking old files), unlike Finder which
        // makes "Archive 2.zip". Pick a unique destination instead. The name is
        // claimed on disk here and released in the compress closure below.
        let destination = Self.uniqueDestinationURL(proposedDestination)

        let op = ArchiveOperation(
            title: String(localized: "Compressing \(destination.lastPathComponent)"),
            kind: .compress, state: .running, progress: 0,
            currentItem: String(localized: "Starting…"),
            detail: String(localized: "\(sources.count) items"))
        let wasEncrypted = encryptionEnabled
        run(op, outputURL: destination, onComplete: { [weak self] url in
            guard let info = await AppModel.makeCompressionShareInfo(
                outputURL: url,
                sources: sources,
                quiet: quiet,
                wasEncrypted: wasEncrypted,
                sizeScanner: { AppModel.totalInputBytes(of: $0) }
            ) else { return }
            self?.shareArchive = info
        }, onTerminal: { succeeded in
            // Drop the Share extension's copies as soon as they have been read.
            // They are duplicates of the user's files sitting in a folder they
            // cannot see, and the launch-time prune would otherwise keep them for
            // a day. Only on success: a failed operation can be retried, and
            // Retry re-reads these exact paths.
            guard succeeded else { return }
            XZIPAppGroup.releaseStaged(sources)
        }) { [service] in
            // Release the claim from `uniqueDestinationURL` right before handing
            // the path to 7zz: it rejects a 0-byte target outright ("Is not
            // archive"), so the placeholder cannot survive into the call.
            //
            // NOT atomic: a window remains between this unlink and 7zz creating
            // the file, so two compressions can still collide if they interleave
            // here. See `uniqueDestinationURL` for why, and for the fix.
            try? FileManager.default.removeItem(at: destination)
            return try service.compress(
                sources: sources, destination: destination, options: coreOptions)
        }
    }

    /// Recursively totals regular-file bytes for the post-compress saved-ratio.
    /// Runs only from a detached utility-priority task (never on the main actor).
    nonisolated static func totalInputBytes(of sources: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        for source in sources {
            if let values = try? source.resourceValues(forKeys: keys),
               values.isRegularFile == true {
                let size = Int64(clamping: values.fileSize ?? 0)
                total = ByteCountMath.adding(size, to: total)
                continue
            }
            guard let enumerator = fm.enumerator(
                at: source, includingPropertiesForKeys: Array(keys),
                options: []) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                let size = Int64(clamping: values.fileSize ?? 0)
                total = ByteCountMath.adding(size, to: total)
            }
        }
        return total
    }


    nonisolated static func makeCompressionShareInfo(
        outputURL: URL?,
        sources: [URL],
        quiet: Bool,
        wasEncrypted: Bool,
        sizeScanner: @escaping @Sendable ([URL]) -> Int64
    ) async -> ShareArchiveInfo? {
        guard let outputURL, !quiet else { return nil }

        let outputBytes = (
            try? FileManager.default
                .attributesOfItem(atPath: outputURL.path)[.size] as? Int64
        ).flatMap { $0 } ?? 0

        let inputBytes = await Task.detached(priority: .utility) {
            sizeScanner(sources)
        }.value

        return ShareArchiveInfo(
            url: outputURL,
            sizeBytes: outputBytes,
            savedPercent: ArchiveBrowsing.savedPercent(
                inputBytes: inputBytes,
                outputBytes: outputBytes
            ),
            isEncrypted: wasEncrypted
        )
    }

    /// Returns `url` if that name is free, otherwise the first free
    /// "name N.ext" sibling (Finder-style), so compression never overwrites or
    /// merges into an existing archive.
    ///
    /// The chosen name is **claimed** with an empty file rather than merely
    /// tested for existence: two compressions started in quick succession both
    /// used to see the same name as free and pick it, and the second `7zz a`
    /// would then UPDATE the first one's output. The caller must remove the
    /// placeholder before invoking 7zz (see `startCompression`), because 7zz
    /// refuses a 0-byte target.
    ///
    /// This narrows the race but does **not** close it: between the caller's
    /// unlink and 7zz creating the file, another call can claim the same name.
    /// Closing it properly means never naming the final file until it exists —
    /// let 7zz write to a private temp name, then `renameatx_np(..., RENAME_EXCL)`
    /// onto the destination and retry with the next candidate if that reports
    /// `EEXIST`. Two findings make that more than a local edit, which is why it is
    /// not done here: 7zz picks its output format from the **filename extension**
    /// (a temp name must keep `.zip`/`.7z`, an extensionless one fails outright),
    /// and a split archive does not produce one file at `destination` at all
    /// (`7zz a -v100k out.zip` writes `out.zip.001`, ...), so the rename step has
    /// to handle a whole volume set.
    ///
    /// Falls back to returning the candidate unclaimed if the claim itself fails
    /// for a reason other than "already exists" (an unwritable directory, say):
    /// compression should still be attempted so the user gets the real error from
    /// 7zz instead of a silent no-op.
    static func uniqueDestinationURL(_ url: URL) -> URL {
        if claimName(at: url) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        // Bounded so a pathological directory cannot spin forever; past the
        // bound, fall back to a name that cannot collide.
        while n < 10_000 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if claimName(at: candidate) { return candidate }
            n += 1
        }
        let unique = UUID().uuidString
        let name = ext.isEmpty ? "\(base) \(unique)" : "\(base) \(unique).\(ext)"
        return dir.appendingPathComponent(name)
    }

    /// Atomically create an empty file at `url`, returning whether this call was
    /// the one that created it. `O_EXCL` is what makes the check-and-claim a
    /// single step; `FileManager.fileExists` followed by a write is not.
    private static func claimName(at url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        }
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
