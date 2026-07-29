import Foundation
import XCTest
@testable import XZIPCore

/// Integration tests that exercise the real bundled `7zz` binary.
/// Skipped automatically if the binary has not been fetched.
final class SevenZipEngineIntegrationTests: XCTestCase {

    private var engine: SevenZipEngine!
    private var workDir: URL!

    override func setUpWithError() throws {
        try TestSupport.requireSevenZip()
        engine = SevenZipEngine(
            runner: FoundationProcessRunner(),
            locator: TestSupport.locator
        )
        workDir = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// Writes a small tree of sample files and returns the source directory.
    private func makeSampleTree() throws -> URL {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "hello world".write(
            to: src.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "nested content".write(
            to: src.appendingPathComponent("nested/inner.txt"), atomically: true, encoding: .utf8)
        return src
    }

    // MARK: - Roundtrip across formats

    func testRoundtripFormats() async throws {
        for format in [ArchiveFormat.sevenZip, .zip, .tar] {
            let src = try makeSampleTree()
            let archive = workDir.appendingPathComponent("out.\(format.fileExtensions[0])")

            let compress = engine.compress(
                sources: [src],
                destination: archive,
                options: CompressionOptions(format: format, level: .fast)
            )
            let progress = try await TestSupport.drain(compress)
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                          "\(format) archive should exist")
            XCTAssertEqual(progress.last?.fraction, 1.0)

            let outDir = workDir.appendingPathComponent("out-\(format.rawValue)")
            let extract = engine.extract(
                archive: archive,
                destination: outDir,
                options: ExtractionOptions(overwrite: true)
            )
            _ = try await TestSupport.drain(extract)

            let extractedFile = outDir.appendingPathComponent("src/hello.txt")
            let content = try String(contentsOf: extractedFile, encoding: .utf8)
            XCTAssertEqual(content, "hello world", "roundtrip content mismatch for \(format)")

            // Clean up between iterations.
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: archive)
        }
    }

    // MARK: - Listing

    func testListEntries() async throws {
        let src = try makeSampleTree()
        let archive = workDir.appendingPathComponent("list.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip)))

        let entries = try await engine.list(archive: archive, password: nil)
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains { $0.hasSuffix("hello.txt") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("inner.txt") })
    }


    func testBoundedListEntries() async throws {
        let first = workDir.appendingPathComponent("first.txt")
        let second = workDir.appendingPathComponent("second.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("bounded-list.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [first, second], destination: archive,
            options: CompressionOptions(format: .sevenZip)))

        let aboveLimit = try await engine.list(
            archive: archive, password: nil, limit: 3)
        XCTAssertEqual(aboveLimit.entries.count, 2)
        XCTAssertFalse(aboveLimit.truncated)

        let exactLimit = try await engine.list(
            archive: archive, password: nil, limit: 2)
        XCTAssertEqual(exactLimit.entries.count, 2)
        XCTAssertFalse(exactLimit.truncated)

        let bounded = try await engine.list(
            archive: archive, password: nil, limit: 1)
        XCTAssertEqual(bounded.entries.count, 1)
        XCTAssertTrue(bounded.truncated)
    }

    // MARK: - Encryption

    func testEncryptedRoundtrip() async throws {
        let src = try makeSampleTree()
        let archive = workDir.appendingPathComponent("secret.7z")
        let password = "correct horse battery staple"

        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip, password: password)))

        // Wrong password must fail (list + test both feed the password via stdin).
        do {
            _ = try await engine.list(archive: archive, password: "wrong")
            XCTFail("Expected failure with wrong password")
        } catch {
            // Expected.
        }
        do {
            _ = try await engine.test(archive: archive, password: "wrong")
            XCTFail("Expected test failure with wrong password")
        } catch {
            // Expected.
        }

        // Correct password (via stdin) verifies and extracts fine.
        let verified = try await engine.test(archive: archive, password: password)
        XCTAssertTrue(verified)

        // Correct password extracts fine.
        let outDir = workDir.appendingPathComponent("dec")
        _ = try await TestSupport.drain(engine.extract(
            archive: archive, destination: outDir,
            options: ExtractionOptions(password: password, overwrite: true)))
        let content = try String(
            contentsOf: outDir.appendingPathComponent("src/hello.txt"), encoding: .utf8)
        XCTAssertEqual(content, "hello world")
    }

    func testEncryptedExtractionWithoutPasswordRequestsPassword() async throws {
        let src = try makeSampleTree()
        let archive = workDir.appendingPathComponent("password-required.zip")
        let destination = workDir.appendingPathComponent("password-required-output")

        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .zip, password: "secret")))

        do {
            _ = try await TestSupport.drain(engine.extract(
                archive: archive,
                destination: destination,
                options: ExtractionOptions(password: nil, overwrite: true)))
            XCTFail("Expected passwordRequired")
        } catch let error as ArchiveEngineError {
            guard case .passwordRequired = error else {
                return XCTFail("Expected passwordRequired, got \(error)")
            }
        }
    }

    /// A failed extraction must not leave anything behind in the destination.
    ///
    /// `7zz` creates each output file *before* it discovers it cannot decrypt the
    /// data, so a password failure used to leave a 0-byte file sitting in the
    /// destination. The error was reported correctly, but the user was left with
    /// a file that looks like a successful extraction and silently truncates
    /// whatever it overwrote.
    ///
    /// Covers both ways a password can be wrong: absent and incorrect.
    func testFailedPasswordLeavesNoPartialFiles() async throws {
        for password in [nil, "wrong-password"] as [String?] {
            let src = try makeSampleTree()
            let label = password == nil ? "absent" : "incorrect"
            let archive = workDir.appendingPathComponent("partial-\(label).zip")
            let destination = workDir.appendingPathComponent("partial-\(label)-output")

            _ = try await TestSupport.drain(engine.compress(
                sources: [src], destination: archive,
                options: CompressionOptions(format: .zip, password: "secret")))

            do {
                _ = try await TestSupport.drain(engine.extract(
                    archive: archive,
                    destination: destination,
                    options: ExtractionOptions(password: password, overwrite: true)))
                XCTFail("expected extraction to fail with password \(label)")
            } catch is ArchiveEngineError {
                // Expected; the assertion below is what this test is about.
            }

            // Enumerating rather than checking a single path: any file at all is
            // a leak, whatever 7zz happened to name it.
            let leftovers = FileManager.default
                .enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                ?? []
            XCTAssertEqual(
                leftovers.map(\.lastPathComponent), [],
                "password \(label): failed extraction left files behind"
            )
        }
    }

    /// Cleanup after a failure must never touch files it did not create.
    ///
    /// The guard against the previous test's fix becoming a data-loss bug:
    /// extracting into a folder the user already has (Documents, Desktop) and
    /// getting the password wrong must leave that folder exactly as it was.
    func testFailedPasswordPreservesPreexistingDestinationFiles() async throws {
        let src = try makeSampleTree()
        let archive = workDir.appendingPathComponent("preserve.zip")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .zip, password: "secret")))

        // A destination the user already owns: one unrelated file, plus one whose
        // name collides with an archive entry.
        let destination = workDir.appendingPathComponent("preserve-output")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("src"),
            withIntermediateDirectories: true)
        let unrelated = destination.appendingPathComponent("my-notes.txt")
        let colliding = destination.appendingPathComponent("src/hello.txt")
        try "keep me".write(to: unrelated, atomically: true, encoding: .utf8)
        try "my own version".write(to: colliding, atomically: true, encoding: .utf8)

        do {
            _ = try await TestSupport.drain(engine.extract(
                archive: archive,
                destination: destination,
                options: ExtractionOptions(password: "wrong-password", overwrite: true)))
            XCTFail("expected extraction to fail")
        } catch is ArchiveEngineError {
            // Expected.
        }

        XCTAssertEqual(
            try? String(contentsOf: unrelated, encoding: .utf8), "keep me",
            "cleanup deleted a file it did not create")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: colliding.path),
            "cleanup deleted a pre-existing file that collided with an archive entry")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "cleanup removed a destination directory it did not create")
    }

    // MARK: - Integrity

    func testIntegrityGoodAndCorrupted() async throws {
        let src = try makeSampleTree()
        let archive = workDir.appendingPathComponent("intact.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip)))

        let ok = try await engine.test(archive: archive, password: nil)
        XCTAssertTrue(ok)

        // Corrupt the archive and confirm the test throws.
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: 64)
        handle.write(Data(repeating: 0xFF, count: 128))
        try handle.close()

        do {
            _ = try await engine.test(archive: archive, password: nil)
            XCTFail("Corrupted archive should fail integrity test")
        } catch {
            // Expected.
        }
    }

    // MARK: - Split / Join

    func testSplitAndJoinRoundtrip() async throws {
        // Create ~250 KB of data so a 100 KB volume size yields multiple parts.
        let src = workDir.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let payload = Data((0..<250_000).map { UInt8($0 % 251) })
        try payload.write(to: src.appendingPathComponent("data.bin"))

        let archive = workDir.appendingPathComponent("split.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip, level: .store,
                                        volumeSize: 100_000)))

        // 7-Zip writes volumes as split.7z.001, .002, ...
        let firstVolume = URL(fileURLWithPath: archive.path + ".001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstVolume.path),
                      "First volume should exist")
        let secondVolume = URL(fileURLWithPath: archive.path + ".002")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondVolume.path),
                      "Multiple volumes should be produced")

        // Extract from the first volume; 7-Zip rejoins the parts automatically.
        let outDir = workDir.appendingPathComponent("joined")
        _ = try await TestSupport.drain(engine.extract(
            archive: firstVolume, destination: outDir,
            options: ExtractionOptions(overwrite: true)))

        let restored = try Data(contentsOf: outDir.appendingPathComponent("big/data.bin"))
        XCTAssertEqual(restored, payload, "Rejoined content must match original")
    }


    // MARK: - Unicode entry names (NFC vs argv NFD normalization)

    /// Foundation's Process converts argv through fileSystemRepresentation, which
    /// NFD-decomposes Unicode. 7zz matches selected entry names byte-exactly, so
    /// an NFC name passed on argv (e.g. Vietnamese, from a Windows/web zip) never
    /// matches and extraction silently produces nothing. Selected entries must
    /// therefore reach 7zz via a listfile, whose bytes are not normalized.
    func testExtractSelectedEntryWithNFCName() async throws {
        // "tiếng việt.txt" with precomposed (NFC) code points. Escapes keep the
        // normalization explicit regardless of source-file encoding.
        let entryName = "ti\u{1EBF}ng vi\u{1EC7}t.txt"
        let archive = workDir.appendingPathComponent("nfc.zip")
        try TestSupport.writeStoredZip(entryName: entryName, content: "xin chào", to: archive)

        let entries = try await engine.list(archive: archive, password: nil)
        XCTAssertEqual(entries.map(\.path), [entryName], "fixture should list the NFC name")

        let outDir = workDir.appendingPathComponent("nfc-out")
        _ = try await TestSupport.drain(engine.extract(
            archive: archive, destination: outDir,
            options: ExtractionOptions(selectedEntries: [entryName], overwrite: true)))

        let extracted = outDir.appendingPathComponent(entryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path),
                      "selected NFC-named entry should be extracted")
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "xin chào")
    }

    func testSelectiveExtractRejectsListFileControlCharacters() async throws {
        let archive = workDir.appendingPathComponent("control-name.zip")
        try TestSupport.writeStoredZip(
            entryName: "safe",
            content: "safe",
            to: archive
        )
        let archiveContents = try Data(contentsOf: archive)
        let destination = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let runner = RecordingProcessRunner()
        let validationEngine = SevenZipEngine(
            runner: runner,
            locator: TestSupport.locator
        )

        let stream = validationEngine.extract(
            archive: archive,
            destination: destination,
            options: ExtractionOptions(selectedEntries: ["safe\nvictim"])
        )

        await XCTAssertThrowsErrorAsync {
            try await TestSupport.drain(stream)
        }
        XCTAssertEqual(runner.invocationCount, 0)
        XCTAssertEqual(try Data(contentsOf: archive), archiveContents)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("safe").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("victim").path
        ))
    }

    /// Compressing a source whose on-disk name is NFC (created via raw syscall —
    /// e.g. files from git, curl, terminal tools) must store the NFC bytes in
    /// the archive, not an argv-mangled NFD variant.
    func testCompressPreservesOnDiskNameNormalization() async throws {
        let name = "b\u{00E1}o c\u{00E1}o.txt"  // "báo cáo.txt", NFC
        let src = workDir.appendingPathComponent("nfc-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = try TestSupport.createFileRawName(name, in: src, content: "nội dung")

        let archive = workDir.appendingPathComponent("nfc-compress.zip")
        _ = try await TestSupport.drain(engine.compress(
            sources: [file], destination: archive,
            options: CompressionOptions(format: .zip, level: .fast)))

        let entries = try await engine.list(archive: archive, password: nil)
        XCTAssertEqual(entries.count, 1)
        // Swift's == compares by canonical equivalence (NFC == NFD), so the
        // stored normalization must be checked at the byte level.
        XCTAssertEqual(Array(entries[0].path.utf8), Array(name.utf8),
                       "stored entry name should keep the on-disk NFC bytes")
    }
}
