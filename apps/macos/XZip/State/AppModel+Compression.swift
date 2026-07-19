import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

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
            password: encryptionEnabled ? password : nil,
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
        let baseName: String = {
            guard let typed = archiveName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !typed.isEmpty else { return derivedBaseName }
            // Strip a trailing extension the user typed that already matches the
            // chosen format — including a compound one like ".tar.gz" (NSString
            // .pathExtension only sees ".gz", so compare the whole suffix).
            let suffix = "." + ext.lowercased()
            return typed.lowercased().hasSuffix(suffix) ? String(typed.dropLast(suffix.count)) : typed
        }()
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
        // Never write onto an existing archive: `7zz a` would UPDATE it (merging
        // in stale entries and possibly leaking old files), unlike Finder which
        // makes "Archive 2.zip". Pick a unique destination instead.
        let destination = Self.uniqueDestinationURL(
            destinationDir.appendingPathComponent("\(baseName).\(ext)"))

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
        }) { [service] in
            try service.compress(sources: sources, destination: destination, options: coreOptions)
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

    /// Returns `url` if nothing exists there, otherwise the first free
    /// "name N.ext" sibling (Finder-style), so compression never overwrites or
    /// merges into an existing archive.
    static func uniqueDestinationURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
