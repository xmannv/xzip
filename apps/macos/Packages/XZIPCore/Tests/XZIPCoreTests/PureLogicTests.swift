import XCTest
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
}

// Allow equating ArchiveEngineError in assertions above.
extension ArchiveEngineError: Equatable {
    public static func == (lhs: ArchiveEngineError, rhs: ArchiveEngineError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
