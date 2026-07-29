import XCTest
import XZIPDomain
@testable import XZIPCore

/// Pure unit tests that need no binary: argument building, parsing, format logic.
final class PureLogicTests: XCTestCase {

    // MARK: - ArchiveFormat

    func testInferFormatFromFilename() {
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "a.zip"), .zip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "A.7Z"), .sevenZip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "b.tar.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "c.rar"), .rar)
        XCTAssertNil(ArchiveFormat.infer(fromFilename: "note.txt"))
    }

    func testInferExtractOnlyFormats() {
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "disc.iso"), .iso)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "setup.CAB"), .cab)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "pkg.deb"), .deb)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "pkg.rpm"), .rpm)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "initrd.cpio"), .cpio)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "old.lha"), .lzh)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "install.wim"), .wim)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "help.chm"), .chm)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "retro.arj"), .arj)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "Xcode.xip"), .xip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "dump.Z"), .unixCompress)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "payload.lzma"), .lzma)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "disc.udf"), .udf)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "rootfs.squashfs"), .squashfs)
    }

    func testZipFamilyExtensionsInferAsZip() {
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "lib.jar"), .zip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "book.epub"), .zip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "comic.cbz"), .zip)
        XCTAssertEqual(ArchiveFormat.infer(fromFilename: "backup.pax"), .tar)
    }

    func testCapabilities() {
        XCTAssertFalse(ArchiveFormat.rar.canCompress)
        XCTAssertTrue(ArchiveFormat.sevenZip.canCompress)
        XCTAssertTrue(ArchiveFormat.sevenZip.supportsEncryption)
        XCTAssertFalse(ArchiveFormat.tar.supportsEncryption)
        XCTAssertTrue(ArchiveFormat.zip.supportsSplitting)
        XCTAssertFalse(ArchiveFormat.gzip.supportsSplitting)
        // Every 7zz-only container is strictly extract-only.
        for format in [ArchiveFormat.iso, .cab, .deb, .rpm, .cpio, .lzh, .wim,
                       .chm, .arj, .xip, .unixCompress, .lzma, .udf, .squashfs] {
            XCTAssertFalse(format.canCompress, "\(format) must be extract-only")
            XCTAssertNil(format.sevenZipTypeFlag, "\(format) has no 7zz write flag")
            XCTAssertFalse(format.supportsAppending, "\(format) cannot append")
        }
        XCTAssertTrue(ArchiveFormat.dmg.canCompress)
    }

    // MARK: - Compression arguments

    func testCompressionStagesWrapStreamCodecsInTar() {
        let destination = URL(fileURLWithPath: "/tmp/out.tar.zst")
        let sources = [
            URL(fileURLWithPath: "/tmp/one"),
            URL(fileURLWithPath: "/tmp/two")
        ]
        let temporaryTar = URL(fileURLWithPath: "/tmp/staging.tar")

        for format in [ArchiveFormat.gzip, .bzip2, .xz, .zstd] {
            let options = CompressionOptions(
                format: format,
                level: .maximum,
                password: "must-not-leak",
                volumeSize: 1_000
            )
            let stages = SevenZipEngine.compressionStages(
                destination: destination,
                sources: sources,
                options: options,
                temporaryTar: temporaryTar
            )

            XCTAssertEqual(stages.count, 2)
            XCTAssertEqual(stages[0].destination, temporaryTar)
            XCTAssertEqual(stages[0].sources, sources)
            XCTAssertEqual(stages[0].options.format, .tar)
            XCTAssertNil(stages[0].options.password)
            XCTAssertNil(stages[0].options.volumeSize)
            XCTAssertEqual(stages[1].destination, destination)
            XCTAssertEqual(stages[1].sources, [temporaryTar])
            XCTAssertEqual(stages[1].options.format, format)
            XCTAssertNil(stages[1].options.password)
            XCTAssertNil(stages[1].options.volumeSize)
        }
    }

    func testCompressionStagesKeepContainerFormatsSingleStage() {
        let destination = URL(fileURLWithPath: "/tmp/out.zip")
        let sources = [URL(fileURLWithPath: "/tmp/input")]
        let temporaryTar = URL(fileURLWithPath: "/tmp/staging.tar")

        for format in [ArchiveFormat.zip, .sevenZip, .tar] {
            let options = CompressionOptions(format: format)
            let stages = SevenZipEngine.compressionStages(
                destination: destination,
                sources: sources,
                options: options,
                temporaryTar: temporaryTar
            )
            XCTAssertEqual(stages.count, 1)
            XCTAssertEqual(stages[0].destination, destination)
            XCTAssertEqual(stages[0].sources, sources)
            XCTAssertEqual(stages[0].options, options)
        }
    }

    func testCompressionArgumentsBasic() {
        let opts = CompressionOptions(format: .sevenZip, level: .maximum)
        let args = SevenZipEngine.compressionArguments(
            destination: URL(fileURLWithPath: "/tmp/out.7z"),
            sources: [URL(fileURLWithPath: "/tmp/in")],
            options: opts,
            sourceListFile: URL(fileURLWithPath: "/tmp/list.txt")
        )
        XCTAssertEqual(args.first, "a")
        XCTAssertTrue(args.contains("-t7z"))
        XCTAssertTrue(args.contains("-mx=7"))
        XCTAssertTrue(args.contains("/tmp/out.7z"))
        // Source paths must never appear on argv (NSTask NFD-normalizes it,
        // mangling the stored names); they travel via the listfile.
        XCTAssertFalse(args.contains("/tmp/in"))
        XCTAssertTrue(args.contains("@/tmp/list.txt"))
        XCTAssertTrue(args.contains("-scsUTF-8"))
    }

    func testCompressionArgumentsEncryptionAndSplit() {
        let opts = CompressionOptions(
            format: .sevenZip,
            level: .normal,
            password: "s3cret",
            encryptFileNames: true,
            volumeSize: 1_000_000,
            exclusionPatterns: [".DS_Store", "__MACOSX"]
        )
        let args = SevenZipEngine.compressionArguments(
            destination: URL(fileURLWithPath: "/tmp/out.7z"),
            sources: [URL(fileURLWithPath: "/tmp/in")],
            options: opts,
            sourceListFile: URL(fileURLWithPath: "/tmp/list.txt")
        )
        // The password is NEVER inlined into argv (where `ps` could read it):
        // `-p` is bare and the value is fed to 7zz via stdin by the caller.
        XCTAssertTrue(args.contains("-p"))
        XCTAssertFalse(args.contains { $0.hasPrefix("-p") && $0 != "-p" })
        XCTAssertFalse(args.contains { $0.contains("s3cret") })
        XCTAssertTrue(args.contains("-mhe=on"))
        XCTAssertTrue(args.contains("-v1000000b"))
        XCTAssertTrue(args.contains("-xr!.DS_Store"))
        XCTAssertTrue(args.contains("-xr!__MACOSX"))
    }

    func testExtractionArgumentsOverwriteVsRename() {
        let overwrite = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/a.zip"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            options: ExtractionOptions(overwrite: true),
            entryListFile: nil
        )
        XCTAssertTrue(overwrite.contains("-aoa"))
        XCTAssertTrue(overwrite.contains("-o/tmp/out"))

        let rename = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/a.zip"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            options: ExtractionOptions(overwrite: false),
            entryListFile: nil
        )
        XCTAssertTrue(rename.contains("-aou"))
    }


    func testExtractionArgumentsSkipExisting() {
        let skip = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/a.zip"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            options: ExtractionOptions(existingFilePolicy: .skip),
            entryListFile: nil
        )
        XCTAssertTrue(skip.contains("-aos"))
        XCTAssertFalse(skip.contains("-aoa"))
        XCTAssertFalse(skip.contains("-aou"))
    }

    func testFailExtractionDetectsExistingSelectedDestination() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipFailConflict-\(UUID().uuidString)", isDirectory: true)
        let nested = destination.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        let existing = nested.appendingPathComponent("existing.txt")
        try Data("existing".utf8).write(to: existing)
        let entries = [
            ArchiveEntry(
                path: "folder/existing.txt",
                uncompressedSize: 1,
                compressedSize: 1,
                modificationDate: nil,
                isDirectory: false,
                isEncrypted: false
            )
        ]

        let conflict = try SevenZipEngine.firstDestinationConflict(
            entries: entries,
            destination: destination,
            selectedEntries: ["folder"]
        )

        XCTAssertEqual(conflict, existing.path)
    }


    func testFailCompressionRejectsDestinationCreatedAfterProcessStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipLateCompressionConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("output.zip")
        let externalBytes = Data("external".utf8)
        try Data("source".utf8).write(to: source)

        let runner = LateConflictProcessRunner(
            mode: .compression(contents: Data("archive".utf8))
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = CompressionOptions(format: .zip)
            options.existingFilePolicy = .fail
            for try await progress in engine.compress(
                sources: [source],
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilProcessStarts()
        try externalBytes.write(to: destination)
        await runner.releaseProcess()

        do {
            try await operation.value
            XCTFail("Expected destination conflict")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: destination.path))
        }
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
        XCTAssertEqual(try Data(contentsOf: destination), externalBytes)
    }


    func testFailCompressionEmitsTerminalProgressOnlyAfterSuccessfulPublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipSuccessfulPublicationProgress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("output.zip")
        let archiveBytes = Data("archive".utf8)
        try Data("source".utf8).write(to: source)

        let runner = LateConflictProcessRunner(
            mode: .compression(contents: archiveBytes)
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = CompressionOptions(format: .zip)
            options.existingFilePolicy = .fail
            for try await progress in engine.compress(
                sources: [source],
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilProcessStarts()
        await runner.releaseProcess()
        try await operation.value

        let fractions = await recorder.values()
        XCTAssertEqual(fractions.last!, 1)
        XCTAssertEqual(try Data(contentsOf: destination), archiveBytes)
    }


    func testSevenZipProgressStreamKeepsOnlyNewestDerivedValue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SevenZipBoundedProgress-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("output.zip")
        try Data("source".utf8).write(to: source)

        let production = ArchiveResourcePolicy.production
        let policy = ArchiveResourcePolicy(
            listing: production.listing,
            output: production.output,
            process: .init(
                stdoutBufferByteCap: production.process.stdoutBufferByteCap,
                stderrTailByteCap: production.process.stderrTailByteCap,
                rawChunkByteCap: production.process.rawChunkByteCap,
                progressEventBufferCount: 1,
                progressInterval: 0,
                terminationGracePeriod: production.process.terminationGracePeriod
            ),
            cache: production.cache,
            split: production.split,
            command: production.command,
            journal: production.journal,
            scheduling: production.scheduling
        )
        let (producerFinished, producerFinishedContinuation) =
            AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let engine = SevenZipEngine(
            runner: BurstProgressProcessController(),
            locator: ConflictBoundaryBinaryLocator(),
            policy: policy,
            producerCompletion: {
                producerFinishedContinuation.yield()
                producerFinishedContinuation.finish()
            }
        )

        let stream = engine.compress(
            sources: [source],
            destination: destination,
            options: CompressionOptions(format: .zip)
        )
        var producerIterator = producerFinished.makeAsyncIterator()
        let producerDidFinish: Void? = await producerIterator.next()
        XCTAssertNotNil(producerDidFinish)

        var fractions: [Double?] = []
        for try await progress in stream {
            fractions.append(progress.fraction)
        }

        XCTAssertEqual(fractions, [1])
    }

    func testFailCompressionRejectsDestinationParentChangedToSymlinkBeforePublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipParentSymlinkConflict-\(UUID().uuidString)", isDirectory: true)
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        let replacementParent = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = destinationParent.appendingPathComponent("output.zip")
        let replacementOutput = replacementParent.appendingPathComponent("output.zip")
        let sentinel = replacementParent.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external".utf8)
        try Data("source".utf8).write(to: source)
        try sentinelBytes.write(to: sentinel)

        let runner = LateConflictProcessRunner(
            mode: .compression(contents: Data("archive".utf8))
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let operation = Task {
            var options = CompressionOptions(format: .zip)
            options.existingFilePolicy = .fail
            for try await _ in engine.compress(
                sources: [source],
                destination: destination,
                options: options
            ) {}
        }

        await runner.waitUntilProcessStarts()
        try FileManager.default.moveItem(
            at: destinationParent,
            to: root.appendingPathComponent("original-destination", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(
            at: destinationParent,
            withDestinationURL: replacementParent
        )
        await runner.releaseProcess()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementOutput.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

    func testFailCompressionRejectsDestinationParentReplacementBeforePublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipParentReplacementConflict-\(UUID().uuidString)", isDirectory: true)
        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        let replacementParent = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.txt")
        let destination = destinationParent.appendingPathComponent("output.zip")
        let replacementOutput = destinationParent.appendingPathComponent("output.zip")
        let replacementSentinel = replacementParent.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external".utf8)
        try Data("source".utf8).write(to: source)
        try sentinelBytes.write(to: replacementSentinel)

        let runner = LateConflictProcessRunner(
            mode: .compression(contents: Data("archive".utf8))
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let operation = Task {
            var options = CompressionOptions(format: .zip)
            options.existingFilePolicy = .fail
            for try await _ in engine.compress(
                sources: [source],
                destination: destination,
                options: options
            ) {}
        }

        await runner.waitUntilProcessStarts()
        try FileManager.default.moveItem(
            at: destinationParent,
            to: root.appendingPathComponent("original-destination", isDirectory: true)
        )
        try FileManager.default.moveItem(at: replacementParent, to: destinationParent)
        await runner.releaseProcess()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementOutput.path))
        XCTAssertEqual(
            try Data(contentsOf: destinationParent.appendingPathComponent("sentinel.txt")),
            sentinelBytes
        )
    }

    func testFailExtractionRejectsChildCreatedAfterProcessStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipLateExtractionConflict-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("archive.zip")
        let target = destination.appendingPathComponent("late.txt")
        let externalBytes = Data("external".utf8)
        try Data("archive".utf8).write(to: archive)
        let expectedRootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )

        let runner = LateConflictProcessRunner(
            mode: .extraction(
                entryPath: "late.txt",
                contents: Data("extracted".utf8)
            )
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationRootIdentity = expectedRootIdentity
            for try await _ in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {}
        }

        await runner.waitUntilProcessStarts()
        try externalBytes.write(to: target)
        await runner.releaseProcess()

        do {
            try await operation.value
            XCTFail("Expected destination conflict")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: target.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), externalBytes)
    }


    func testFailExtractionRejectsDestinationRootReplacementAfterProcessStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SevenZipExtractionRootReplacement-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let originalDestination = root.appendingPathComponent(
            "original-output",
            isDirectory: true
        )
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacement,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("archive.zip")
        try Data("archive".utf8).write(to: archive)
        let sentinel = replacement.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("replacement-sentinel".utf8)
        try sentinelBytes.write(to: sentinel)
        let expectedRootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )

        let runner = LateConflictProcessRunner(
            mode: .extraction(
                entryPath: "new.txt",
                contents: Data("extracted".utf8)
            )
        )
        let engine = SevenZipEngine(
            runner: runner,
            locator: ConflictBoundaryBinaryLocator()
        )
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationRootIdentity = expectedRootIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilProcessStarts()
        try FileManager.default.moveItem(
            at: destination,
            to: originalDestination
        )
        try FileManager.default.moveItem(at: replacement, to: destination)
        await runner.releaseProcess()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("sentinel.txt")),
            sentinelBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("new.txt").path
            )
        )
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
    }

    func testExtractionArgumentsSelectedEntriesGoViaListfile() {
        let args = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/a.zip"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            options: ExtractionOptions(selectedEntries: ["-o/evil", "normal.txt"]),
            entryListFile: URL(fileURLWithPath: "/tmp/entries.txt")
        )
        // Selected entry names must never appear on argv: NSTask NFD-normalizes
        // argv (breaking byte-exact matching of NFC names), and a name beginning
        // with `-` (attacker-controlled, from the listing) could otherwise be
        // reinterpreted as a 7zz switch such as `-o<path>`. They travel via the
        // listfile instead; only the include switch and the archive path remain.
        XCTAssertFalse(args.contains("-o/evil"))
        XCTAssertFalse(args.contains("normal.txt"))
        XCTAssertTrue(args.contains("-i@/tmp/entries.txt"))
        XCTAssertTrue(args.contains("-scsUTF-8"))
        // The listfile switch must precede `--` (it would otherwise be treated
        // as a path), and the archive path must follow it.
        let separator = args.firstIndex(of: "--")
        let archive = args.firstIndex(of: "/tmp/a.zip")
        let include = args.firstIndex(of: "-i@/tmp/entries.txt")
        XCTAssertNotNil(separator)
        XCTAssertNotNil(archive)
        XCTAssertNotNil(include)
        if let separator, let archive, let include {
            XCTAssertLessThan(include, separator)
            XCTAssertLessThan(separator, archive)
        }
    }


    func testExtractionOptionsPoliciesAndLegacyCompatibility() {
        var legacy = ExtractionOptions(overwrite: false)
        XCTAssertEqual(legacy.existingFilePolicy, .keepBoth)
        legacy.overwrite = true
        XCTAssertEqual(legacy.existingFilePolicy, .replace)

        var skip = ExtractionOptions(existingFilePolicy: .skip)
        XCTAssertFalse(skip.overwrite)
        skip.overwrite = false
        XCTAssertEqual(skip.existingFilePolicy, .keepBoth)
    }

    // MARK: - Path traversal guard

    func testPathTraversalDetection() {
        let dest = URL(fileURLWithPath: "/tmp/extract")
        let evil = [
            ArchiveEntry(path: "../../etc/passwd", uncompressedSize: 1,
                         compressedSize: 1, modificationDate: nil,
                         isDirectory: false, isEncrypted: false)
        ]
        XCTAssertThrowsError(
            try SevenZipEngine.validateNoPathTraversal(entries: evil, destination: dest)
        )

        let safe = [
            ArchiveEntry(path: "sub/file.txt", uncompressedSize: 1,
                         compressedSize: 1, modificationDate: nil,
                         isDirectory: false, isEncrypted: false)
        ]
        XCTAssertNoThrow(
            try SevenZipEngine.validateNoPathTraversal(entries: safe, destination: dest)
        )
    }


    func testPathTraversalDetectionRejectsAbsolutePaths() {
        let dest = URL(fileURLWithPath: "/tmp/extract")
        let absolute = [
            ArchiveEntry(path: "/tmp/extract/looks-safe.txt", uncompressedSize: 1,
                         compressedSize: 1, modificationDate: nil,
                         isDirectory: false, isEncrypted: false)
        ]
        XCTAssertThrowsError(
            try SevenZipEngine.validateNoPathTraversal(entries: absolute, destination: dest)
        )
    }

    // MARK: - Progress parser

    func testProgressParser() {
        XCTAssertEqual(SevenZipProgressParser.parse(" 42% 3 - a/b.txt")?.fraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(SevenZipProgressParser.parse(" 42% 3 - a/b.txt")?.currentEntry, "a/b.txt")
        XCTAssertEqual(SevenZipProgressParser.parse("100%")?.fraction ?? -1, 1.0, accuracy: 0.001)
        XCTAssertNil(SevenZipProgressParser.parse("no percentage here"))
    }


    func testStreamingProcessCancellationReturnsPromptly() async {
        let runner = FoundationProcessRunner()
        let stream = runner.runStreaming(
            executable: "/bin/sleep",
            arguments: ["10"],
            workingDirectory: nil,
            environment: nil
        )
        let task = Task {
            for try await _ in stream {}
        }

        try? await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(2))
    }

    // MARK: - Listing parser

    func testListingParser() {
        let sample = """
        7-Zip 26.02

        Listing archive: test.7z

        ----------
        Path = folder/hello.txt
        Size = 12
        Packed Size = 20
        Modified = 2026-07-16 08:52:31
        Attributes = A
        Encrypted = -

        Path = folder
        Size = 0
        Folder = +
        Modified = 2026-07-16 08:52:31
        Attributes = D
        """
        let entries = SevenZipListingParser.parse(sample)
        XCTAssertEqual(entries.count, 2)
        let file = entries.first { $0.path == "folder/hello.txt" }
        XCTAssertEqual(file?.uncompressedSize, 12)
        XCTAssertEqual(file?.compressedSize, 20)
        XCTAssertEqual(file?.isDirectory, false)
        XCTAssertNotNil(file?.modificationDate)
        let dir = entries.first { $0.path == "folder" }
        XCTAssertEqual(dir?.isDirectory, true)
    }

    func testErrorMapping() {
        // 7zz reports "Wrong password?" both when the supplied password is wrong
        // and when it probes an encrypted archive with an empty `-p`. Only a
        // password the user actually entered maps to `.wrongPassword`; otherwise
        // the archive simply needs one.
        XCTAssertEqual(
            SevenZipEngine.mapFailure(stderr: "ERROR: Wrong password?", stdout: "", hadPassword: true),
            .wrongPassword
        )
        XCTAssertEqual(
            SevenZipEngine.mapFailure(stderr: "ERROR: Wrong password?", stdout: "", hadPassword: false),
            .passwordRequired
        )
        XCTAssertEqual(
            SevenZipEngine.mapFailure(stderr: "Cannot open the file as archive", stdout: ""),
            .corruptedArchive("Cannot open the file as archive")
        )
    }

    func testWildcardMatchingDisabledForEntryPaths() {
        // Entry/file paths that legally contain `*`/`?` must be matched literally
        // by 7zz (`-spd`), never expanded as masks against sibling entries.
        let extractArgs = SevenZipEngine.extractionArguments(
            archive: URL(fileURLWithPath: "/tmp/a.7z"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            options: ExtractionOptions(selectedEntries: ["photo?.jpg"]),
            entryListFile: URL(fileURLWithPath: "/tmp/entries.txt")
        )
        XCTAssertTrue(extractArgs.contains("-spd"))

        let renameArgs = SevenZipArchiveEditor.renameArguments(
            archive: URL(fileURLWithPath: "/tmp/a.7z"),
            listFile: URL(fileURLWithPath: "/tmp/pairs.txt"), password: nil
        )
        XCTAssertTrue(renameArgs.contains("-spd"))
    }

    func testListFileEntryValidationRejectsCRLFAndNUL() {
        let invalidEntries = [
            "folder/carriage\rreturn.txt",
            "folder/line\nfeed.txt",
            "folder/null\u{0}byte.txt",
        ]

        for entry in invalidEntries {
            XCTAssertThrowsError(
                try SevenZipArchiveEditor.writeEntryListFile([entry])
            ) { error in
                guard let archiveError = error as? ArchiveEngineError else {
                    return XCTFail("Expected ArchiveEngineError, got \(error)")
                }
                guard case let .unsupportedEntryName(rejectedEntry, reason) = archiveError else {
                    return XCTFail("Expected unsupportedEntryName, got \(archiveError)")
                }
                XCTAssertEqual(rejectedEntry, entry)
                XCTAssertFalse(reason.isEmpty)
            }
        }
    }

    func testListFileEntryValidationAcceptsLiteralSlashSeparatedPath() throws {
        let listFile = try SevenZipArchiveEditor.writeEntryListFile(
            ["folder/a*[1]?.txt"]
        )
        defer { try? FileManager.default.removeItem(at: listFile) }

        XCTAssertEqual(
            try String(contentsOf: listFile, encoding: .utf8),
            "folder/a*[1]?.txt"
        )
    }

    func testParseArchiveCommentMultiLine() {
        // 7zz -slt prints the archive comment as a multi-line `Comment = …`
        // property in the header block, ending at the next `Key = value` line.
        let output = """
        Listing archive: c.zip

        --
        Path = c.zip
        Type = zip
        Comment =\u{20}
        My archive comment line1
        line2
        Physical Size = 190

        ----------
        Path = f.txt
        Size = 6
        Comment = should-not-read-this
        """
        XCTAssertEqual(
            SevenZipListingParser.parseArchiveComment(output),
            "My archive comment line1\nline2")
    }

    func testParseArchiveCommentInlineAndEmpty() {
        XCTAssertEqual(
            SevenZipListingParser.parseArchiveComment("--\nType = rar\nComment = hello\nSolid = -\n----------\n"),
            "hello")
        XCTAssertEqual(
            SevenZipListingParser.parseArchiveComment("--\nType = rar\nSolid = -\n----------\n"),
            "")
    }

    func testListingParserReconstructsEmbeddedNewlinePath() {
        // A filename with an embedded newline (legal, printed raw by 7zz) must be
        // reassembled so the `..` stays visible to the path-traversal guard
        // rather than being truncated to a "safe"-looking prefix.
        let sample = """
        ----------
        Path = safe
        ../../evil
        Size = 3
        Attributes = A
        """
        let entries = SevenZipListingParser.parse(sample)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "safe\n../../evil")
        XCTAssertThrowsError(
            try SevenZipEngine.validateNoPathTraversal(
                entries: entries, destination: URL(fileURLWithPath: "/tmp/out"))
        )
    }

    func testParseArchiveCommentKeepsFreeTextKeyValueLines() {
        // A user comment whose lines look like "Key = value" (e.g. "Author =
        // John") must NOT be mistaken for the next property and truncated; only a
        // real 7zz archive-level property key (here "Characteristics") ends it.
        let output = """
        --
        Path = c.rar
        Type = rar
        Comment = First line
        Author = John Doe
        Version = 2
        Last line
        Characteristics = Volume
        ----------
        Path = f.txt
        """
        XCTAssertEqual(
            SevenZipListingParser.parseArchiveComment(output),
            "First line\nAuthor = John Doe\nVersion = 2\nLast line")
    }

    func testTreeBuilderPromotesFileNodeWhenChildArrives() throws {
        // A file entry "docs" followed by "docs/readme.txt" proves "docs" is a
        // directory; it must be promoted so its child counts toward totalSize
        // instead of being orphaned under a file node.
        let entries = [
            ArchiveEntry(path: "docs", uncompressedSize: 5, compressedSize: 5,
                         modificationDate: nil, isDirectory: false, isEncrypted: false),
            ArchiveEntry(path: "docs/readme.txt", uncompressedSize: 100, compressedSize: 40,
                         modificationDate: nil, isDirectory: false, isEncrypted: false),
        ]
        let tree = ArchiveTreeBuilder.build(from: entries)
        XCTAssertEqual(tree.count, 1)
        let docs = try XCTUnwrap(tree.first)
        XCTAssertTrue(docs.isDirectory, "docs must be promoted to a directory")
        XCTAssertEqual(docs.children.count, 1)
        XCTAssertEqual(docs.totalSize, 100, "directory size must include its child")
    }

    func testDMGValidateSelectedEntriesRejectsTraversal() {
        XCTAssertThrowsError(try DMGEngine.validateSelectedEntries(["../escape"]))
        XCTAssertThrowsError(try DMGEngine.validateSelectedEntries(["/abs/path"]))
        XCTAssertThrowsError(try DMGEngine.validateSelectedEntries(["a/../../b"]))
        XCTAssertNoThrow(try DMGEngine.validateSelectedEntries(["docs/readme.txt", "a/b/c"]))
    }

    func testDMGKeepBothUsesSevenZipNamingConvention() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("report.txt")
        try Data().write(to: target)
        XCTAssertEqual(DMGEngine.uniqueURL(for: target).lastPathComponent, "report_1.txt")
        try Data().write(to: dir.appendingPathComponent("report_1.txt"))
        XCTAssertEqual(DMGEngine.uniqueURL(for: target).lastPathComponent, "report_2.txt")
    }

    func testDMGStagingSelectedEntryRejectsSymlinkAncestorBeforeWriting() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("secret".utf8).write(
            to: outside.appendingPathComponent("secret.txt")
        )
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "escape": .symbolicLink(outside.path)
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "escape", kind: .directory),
            .init(relativePath: "escape/secret.txt", kind: .regularFile)
        ])
        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: ["escape/secret.txt"],
                    authority: authority,
                    preserveTimestamps: true,
                    policy: .production,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()

        await XCTAssertThrowsErrorAsync { _ = try await task.value }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            []
        )
    }

    func testDMGStagingCopiesSelectedSymlinkWithoutFollowingTarget() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideFile = root.appendingPathComponent("outside.txt")
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try Data("secret".utf8).write(to: outsideFile)
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "link": .symbolicLink(outsideFile.path)
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "link", kind: .symbolicLink)
        ])

        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: ["link"],
                    authority: authority,
                    preserveTimestamps: true,
                    policy: .production,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        _ = try await task.value

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: staging.appendingPathComponent("link").path
            ),
            outsideFile.path
        )
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("secret".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            ["link"]
        )
    }

    func testDMGStagingRejectsHardLinkedRegularFileBeforeWriting() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "original.txt": .file(Data("shared".utf8)),
            "alias.txt": .hardLink("original.txt")
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "alias.txt", kind: .regularFile)
        ])

        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: ["alias.txt"],
                    authority: authority,
                    preserveTimestamps: false,
                    policy: .production,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()

        do {
            _ = try await task.value
            XCTFail("Expected hard-linked regular file to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .unsupportedNode(path: "alias.txt", kind: .hardLink)
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            []
        )
    }

    func testDMGStagingCopiesOnlyAuthorizedSelectedSubtree() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "a.txt": .file(Data("a".utf8)),
            "b.txt": .file(Data("b".utf8))
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "a.txt", kind: .regularFile)
        ])

        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: ["a.txt"],
                    authority: authority,
                    preserveTimestamps: false,
                    policy: .production,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        _ = try await task.value

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            ["a.txt"]
        )
        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent("a.txt")),
            Data("a".utf8)
        )
    }

    func testDMGInventoryStopsEnumerationAtListingHardCap() throws {
        let mountPoint = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let probe = DirectoryEnumerationProbe(nodes: (0..<4).map { index in
            FileNode(
                name: "entry-\(index)",
                identity: FileNodeIdentity(
                    device: 1,
                    inode: UInt64(index + 1),
                    generation: nil,
                    kind: .regularFile
                ),
                byteCount: 1,
                linkTarget: nil
            )
        })
        let copier = DMGStagingCopier(
            fileSystem: DarwinFileSystemOperations(),
            nodeEnumerator: probe
        )
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            listingHardCap: 2
        )

        XCTAssertThrowsError(try copier.inventory(
            mountPoint: mountPoint,
            selectedEntries: [],
            policy: policy
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .entryCountExceeded(limit: 2)
            )
        }
        XCTAssertEqual(probe.pullCount, 3)
    }

    func testDMGInventoryStopsEnumerationAtTotalPathByteCap() throws {
        let mountPoint = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let probe = DirectoryEnumerationProbe(nodes: ["aa", "bb", "cc", "dd"].enumerated().map {
            index, name in
            FileNode(
                name: name,
                identity: FileNodeIdentity(
                    device: 1,
                    inode: UInt64(index + 1),
                    generation: nil,
                    kind: .regularFile
                ),
                byteCount: 1,
                linkTarget: nil
            )
        })
        let copier = DMGStagingCopier(
            fileSystem: DarwinFileSystemOperations(),
            nodeEnumerator: probe
        )
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            listingHardCap: 100,
            totalPathByteCap: 4
        )

        XCTAssertThrowsError(try copier.inventory(
            mountPoint: mountPoint,
            selectedEntries: [],
            policy: policy
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .totalPathByteCountExceeded(limit: 4)
            )
        }
        XCTAssertEqual(probe.pullCount, 3)
    }

    func testDMGStagingByteCapRejectsBeforeFirstFileWrite() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "oversized.bin": .file(Data([0, 1]))
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "oversized.bin", kind: .regularFile)
        ])
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            stagingByteCap: 1
        )

        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: [],
                    authority: authority,
                    preserveTimestamps: true,
                    policy: policy,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()

        await XCTAssertThrowsErrorAsync { _ = try await task.value }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: staging.path),
            []
        )
    }

    func testDMGStagingPreservesModificationTimeWhenRequested() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.dmg")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_100)
        try Data("image".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let runner = GatedDMGExtractionProcessRunner(mountedEntries: [
            "dated.txt": .file(
                Data("dated".utf8),
                modificationDate: expectedDate
            )
        ])
        let engine = DMGEngine(runner: runner)
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "dated.txt", kind: .regularFile)
        ])

        let task = Task {
            try await TestSupport.drain(
                engine.extractToEmptyStagingDirectory(
                    archive: archive,
                    destination: staging,
                    selectedEntries: ["dated.txt"],
                    authority: authority,
                    preserveTimestamps: true,
                    policy: .production,
                    password: nil
                )
            )
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        _ = try await task.value

        let attributes = try FileManager.default.attributesOfItem(
            atPath: staging.appendingPathComponent("dated.txt").path
        )
        XCTAssertEqual(
            try XCTUnwrap(attributes[.modificationDate] as? Date)
                .timeIntervalSince1970,
            expectedDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }


    func testDMGFailExtractionRejectsDestinationParentSymlinkReplacementAfterAttachStarts() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationParent = root.appendingPathComponent("parent-a", isDirectory: true)
        let originalParent = root.appendingPathComponent("original-parent", isDirectory: true)
        let replacementParent = root.appendingPathComponent("parent-b", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: false)
        let destination = destinationParent.appendingPathComponent("output", isDirectory: true)
        let sentinel = replacementParent.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external-parent".utf8)
        try sentinelBytes.write(to: sentinel)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destinationParent)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": Data("mounted".utf8)]
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            options.destinationRootIdentity = nil
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        try FileManager.default.moveItem(at: destinationParent, to: originalParent)
        try FileManager.default.createSymbolicLink(
            at: destinationParent,
            withDestinationURL: replacementParent
        )
        await runner.releaseAttach()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: replacementParent
                    .appendingPathComponent("output/new.txt")
                    .path
            )
        )
        XCTAssertEqual(runner.detachCount, 1)
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
    }

    func testDMGFailExtractionRejectsDestinationParentPlainReplacementAfterAttachStarts() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationParent = root.appendingPathComponent("parent-a", isDirectory: true)
        let originalParent = root.appendingPathComponent("original-parent", isDirectory: true)
        let replacementParent = root.appendingPathComponent("parent-b", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacementParent, withIntermediateDirectories: false)
        let destination = destinationParent.appendingPathComponent("output", isDirectory: true)
        let sentinel = replacementParent.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external-parent".utf8)
        try sentinelBytes.write(to: sentinel)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destinationParent)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": Data("mounted".utf8)]
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        try FileManager.default.moveItem(at: destinationParent, to: originalParent)
        try FileManager.default.moveItem(at: replacementParent, to: destinationParent)
        await runner.releaseAttach()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(
            try Data(contentsOf: destinationParent.appendingPathComponent("sentinel.txt")),
            sentinelBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationParent
                    .appendingPathComponent("output/new.txt")
                    .path
            )
        )
        XCTAssertEqual(runner.detachCount, 1)
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
    }

    func testDMGFailExtractionRejectsExistingDestinationRootReplacementAfterAttachStarts() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let originalDestination = root.appendingPathComponent("original-output", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let sentinel = replacement.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("external-root".utf8)
        try sentinelBytes.write(to: sentinel)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let rootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": Data("mounted".utf8)]
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            options.destinationRootIdentity = rootIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        try FileManager.default.moveItem(at: destination, to: originalDestination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        await runner.releaseAttach()

        do {
            try await operation.value
            XCTFail("Expected archiveChanged")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .archiveChanged)
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("sentinel.txt")),
            sentinelBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("new.txt").path
            )
        )
        XCTAssertEqual(runner.detachCount, 1)
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
    }

    func testDMGFailExtractionRejectsLateLeafConflictAfterAttachStarts() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let target = destination.appendingPathComponent("new.txt")
        let externalBytes = Data("external-leaf".utf8)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let rootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": Data("mounted".utf8)]
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            options.destinationRootIdentity = rootIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        try externalBytes.write(to: target)
        await runner.releaseAttach()

        do {
            try await operation.value
            XCTFail("Expected destination conflict")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error, .destinationConflict(path: target.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), externalBytes)
        XCTAssertEqual(runner.detachCount, 1)
        let fractions = await recorder.values()
        XCTAssertFalse(fractions.contains { $0 == 1 })
    }

    func testDMGFailExtractionPublishesStagedFilesBeforeTerminalProgress() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let expectedBytes = Data("mounted".utf8)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let rootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": expectedBytes]
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            options.destinationRootIdentity = rootIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        try await operation.value

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("new.txt")),
            expectedBytes
        )
        XCTAssertEqual(runner.detachCount, 1)
        let fractions = await recorder.values()
        XCTAssertEqual(fractions.compactMap { $0 }.last, 1)
    }


    /// Selecting entries that are not on the mounted volume must fail loudly.
    ///
    /// The copy loop skips a missing source, so before this was checked the
    /// extraction reported success — terminal progress and all — while leaving
    /// the destination empty. That is the same "it said it worked but the folder
    /// is empty" shape as the transactional bug, on the legacy DMG path.
    func testDMGExtractionFailsWhenSelectedEntriesAreMissingFromTheVolume() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["present.txt": Data("here".utf8)]
        )
        let engine = DMGEngine(runner: runner)

        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .replace)
            options.selectedEntries = ["present.txt", "gone.txt"]
            for try await _ in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {}
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()

        do {
            try await operation.value
            XCTFail("a missing selected entry should fail the extraction")
        } catch let error as ArchiveEngineError {
            XCTAssertEqual(error, .missingSelectedEntries(entries: ["gone.txt"]))
        }

        // Nothing is published, so a caller cannot mistake a partial tree for a
        // complete one.
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [],
            []
        )
        XCTAssertEqual(runner.detachCount, 1)
    }

    /// A disk image that genuinely contains nothing extracts to an empty
    /// destination and succeeds.
    ///
    /// This is the deliberate counterpart to the check above: whole-volume
    /// extraction cannot tell "this image is empty" from "the mount showed us
    /// nothing", and an empty image is legitimate, so it must not be turned into
    /// an error.
    func testDMGWholeVolumeExtractionOfAnEmptyImageSucceeds() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let runner = GatedDMGExtractionProcessRunner(mountedFiles: [:])
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()

        let operation = Task {
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: ExtractionOptions(existingFilePolicy: .replace)
            ) {
                await recorder.record(progress)
            }
        }
        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        try await operation.value

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path),
            []
        )
        let fractions = await recorder.values()
        XCTAssertEqual(fractions.compactMap { $0 }.last, 1)
    }

    func testDMGFailExtractionDetachFailurePreventsPublicationAndFinalProgress() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        let archive = root.appendingPathComponent("archive.dmg")
        try Data("image".utf8).write(to: archive)
        let parentIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let rootIdentity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: destination)
        )
        let runner = GatedDMGExtractionProcessRunner(
            mountedFiles: ["new.txt": Data("mounted".utf8)],
            detachResult: ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "detach failed"
            )
        )
        let engine = DMGEngine(runner: runner)
        let recorder = ProgressRecorder()
        let operation = Task {
            var options = ExtractionOptions(existingFilePolicy: .fail)
            options.destinationParentIdentity = parentIdentity
            options.destinationRootIdentity = rootIdentity
            for try await progress in engine.extract(
                archive: archive,
                destination: destination,
                options: options
            ) {
                await recorder.record(progress)
            }
        }

        await runner.waitUntilAttachStarts()
        await runner.releaseAttach()
        do {
            try await operation.value
            XCTFail("Expected detach failure")
        } catch ArchiveEngineError.engineFailure(let message) {
            XCTAssertTrue(message.contains("detach failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("new.txt").path
        ))
        XCTAssertGreaterThanOrEqual(runner.detachCount, 1)
        let fractions = await recorder.values().compactMap { $0 }
        XCTAssertFalse(fractions.contains(1))
    }
}


private enum ConflictBoundaryRunnerError: Error {
    case unexpectedInvocation
    case missingOutputArgument
}

private struct ConflictBoundaryBinaryLocator: BinaryLocating {
    func path(for binary: BundledBinary) -> String? {
        "/usr/bin/7zz"
    }
}

private actor ConflictBoundaryGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}


private actor ProgressRecorder {
    private var fractions: [Double?] = []

    func record(_ progress: ArchiveProgress) {
        fractions.append(progress.fraction)
    }

    func values() -> [Double?] {
        fractions
    }
}

private final class BurstProgressProcessController:
    ProcessControlling,
    @unchecked Sendable
{
    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let listIndex = request.arguments.lastIndex(where: {
                        $0.hasPrefix("@")
                    }), listIndex > request.arguments.startIndex else {
                        throw ConflictBoundaryRunnerError.missingOutputArgument
                    }
                    let output = URL(fileURLWithPath: request.arguments[
                        request.arguments.index(before: listIndex)
                    ])
                    try FileManager.default.createDirectory(
                        at: output.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("archive".utf8).write(to: output)

                    let progress = (1...99)
                        .map { " \($0)%\r" }
                        .joined()
                    continuation.yield(.stdout(Data(progress.utf8)))
                    continuation.yield(.terminated(ProcessResult(
                        exitCode: 0,
                        standardOutput: "",
                        standardError: ""
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        })
    }
}


private final class LateConflictProcessRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    enum Mode: Sendable {
        case compression(contents: Data)
        case extraction(entryPath: String, contents: Data)
    }

    private let mode: Mode
    private let gate = ConflictBoundaryGate()

    init(mode: Mode) {
        self.mode = mode
    }


    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if request.arguments.first == "l" {
                        guard case .extraction(let entryPath, _) = mode else {
                            throw ConflictBoundaryRunnerError.unexpectedInvocation
                        }
                        let listing = """
                        ----------
                        Path = \(entryPath)
                        Size = 9
                        Packed Size = 9
                        Attributes = A

                        """
                        continuation.yield(.stdout(Data(listing.utf8)))
                    } else {
                        await gate.markStarted()
                        await gate.waitUntilReleased()
                        try Task.checkCancellation()
                        try writeProcessOutput(arguments: request.arguments)
                    }
                    continuation.yield(.terminated(ProcessResult(
                        exitCode: 0,
                        standardOutput: "",
                        standardError: ""
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        })
    }

    func waitUntilProcessStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseProcess() async {
        await gate.release()
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        throw ConflictBoundaryRunnerError.unexpectedInvocation
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        throw ConflictBoundaryRunnerError.unexpectedInvocation
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await gate.markStarted()
                    await gate.waitUntilReleased()
                    try Task.checkCancellation()
                    try writeProcessOutput(arguments: arguments)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { continuation in
            guard case .extraction(let entryPath, _) = mode else {
                continuation.finish(throwing: ConflictBoundaryRunnerError.unexpectedInvocation)
                return
            }
            let listing = """
            ----------
            Path = \(entryPath)
            Size = 9
            Packed Size = 9
            Attributes = A

            """
            continuation.yield(.stdout(Data(listing.utf8)))
            continuation.finish()
        }
    }

    private func writeProcessOutput(arguments: [String]) throws {
        switch mode {
        case .compression(let contents):
            guard let listIndex = arguments.lastIndex(where: { $0.hasPrefix("@") }),
                  listIndex > arguments.startIndex else {
                throw ConflictBoundaryRunnerError.missingOutputArgument
            }
            let output = URL(fileURLWithPath: arguments[arguments.index(before: listIndex)])
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: output)

        case .extraction(let entryPath, let contents):
            guard let outputArgument = arguments.first(where: { $0.hasPrefix("-o") }) else {
                throw ConflictBoundaryRunnerError.missingOutputArgument
            }
            let outputRoot = URL(
                fileURLWithPath: String(outputArgument.dropFirst(2)),
                isDirectory: true
            )
            let output = outputRoot.appendingPathComponent(entryPath)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: output.path) {
                try contents.write(to: output)
            }
        }
    }
}


private final class DirectoryEnumerationProbe:
    DirectoryNodeEnumerating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let nodes: [FileNode]
    private var pullCountStorage = 0

    init(nodes: [FileNode]) {
        self.nodes = nodes
    }

    var pullCount: Int {
        lock.withLock { pullCountStorage }
    }

    func forEachNode(
        in _: DirectoryHandle,
        _ body: (FileNode) throws -> Void
    ) throws {
        for node in nodes {
            lock.withLock { pullCountStorage += 1 }
            try body(node)
        }
    }
}

private enum MountedDMGEntry {
    case file(Data, modificationDate: Date? = nil)
    case directory
    case symbolicLink(String)
    case hardLink(String)
}

private final class GatedDMGExtractionProcessRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    private let mountedEntries: [String: MountedDMGEntry]
    private let detachResult: ProcessResult
    private let gate = ConflictBoundaryGate()
    private let lock = NSLock()
    private var detachCountStorage = 0

    init(
        mountedEntries: [String: MountedDMGEntry],
        detachResult: ProcessResult = ProcessResult(
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    ) {
        self.mountedEntries = mountedEntries
        self.detachResult = detachResult
    }

    convenience init(
        mountedFiles: [String: Data],
        detachResult: ProcessResult = .init(
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    ) {
        self.init(
            mountedEntries: mountedFiles.mapValues { .file($0) },
            detachResult: detachResult
        )
    }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await execute(arguments: request.arguments)
                    continuation.yield(.terminated(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        })
    }

    var detachCount: Int {
        lock.withLock { detachCountStorage }
    }

    func waitUntilAttachStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseAttach() async {
        await gate.release()
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try await execute(arguments: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try await execute(arguments: arguments)
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: ConflictBoundaryRunnerError.unexpectedInvocation
            )
        }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: ConflictBoundaryRunnerError.unexpectedInvocation
            )
        }
    }

    private func execute(arguments: [String]) async throws -> ProcessResult {
        guard let command = arguments.first else {
            throw ConflictBoundaryRunnerError.unexpectedInvocation
        }
        switch command {
        case "attach":
            guard let mountPointIndex = arguments.firstIndex(of: "-mountpoint"),
                  arguments.indices.contains(mountPointIndex + 1) else {
                throw ConflictBoundaryRunnerError.missingOutputArgument
            }
            await gate.markStarted()
            await gate.waitUntilReleased()
            try Task.checkCancellation()
            let mountPoint = URL(
                fileURLWithPath: arguments[mountPointIndex + 1],
                isDirectory: true
            )
            let sortedEntries = mountedEntries.sorted(by: { $0.key < $1.key })
            for (path, entry) in sortedEntries {
                guard case .directory = entry else { continue }
                try FileManager.default.createDirectory(
                    at: mountPoint.appendingPathComponent(path, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            for (path, entry) in sortedEntries {
                guard case let .file(bytes, modificationDate) = entry else { continue }
                let output = mountPoint.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: output)
                if let modificationDate {
                    try FileManager.default.setAttributes(
                        [.modificationDate: modificationDate],
                        ofItemAtPath: output.path
                    )
                }
            }
            for (path, entry) in sortedEntries {
                guard case let .symbolicLink(target) = entry else { continue }
                let output = mountPoint.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    atPath: output.path,
                    withDestinationPath: target
                )
            }
            for (path, entry) in sortedEntries {
                guard case let .hardLink(target) = entry else { continue }
                let output = mountPoint.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.linkItem(
                    at: mountPoint.appendingPathComponent(target),
                    to: output
                )
            }
            return ProcessResult(
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            )

        case "detach":
            lock.withLock { detachCountStorage += 1 }
            return detachResult

        default:
            throw ConflictBoundaryRunnerError.unexpectedInvocation
        }
    }
}

// Allow equating ArchiveEngineError in assertions above.
extension ArchiveEngineError: Equatable {
    public static func == (lhs: ArchiveEngineError, rhs: ArchiveEngineError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
