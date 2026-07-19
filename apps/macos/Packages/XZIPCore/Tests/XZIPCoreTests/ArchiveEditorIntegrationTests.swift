import Foundation
import XCTest
@testable import XZIPCore

/// Integration tests for in-archive editing via the real `7zz` binary.
final class ArchiveEditorIntegrationTests: XCTestCase {

    private var engine: SevenZipEngine!
    private var editor: SevenZipArchiveEditor!
    private var workDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(TestSupport.hasSevenZip,
                          "7zz not found — run scripts/fetch_binaries.sh")
        let runner = FoundationProcessRunner()
        engine = SevenZipEngine(runner: runner, locator: TestSupport.locator)
        editor = SevenZipArchiveEditor(runner: runner, locator: TestSupport.locator)
        workDir = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeArchive() async throws -> URL {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "one".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("edit.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip)))
        return archive
    }

    func testAddDeleteRename() async throws {
        let archive = try await makeArchive()

        // Add a new file.
        let newFile = workDir.appendingPathComponent("b.txt")
        try "two".write(to: newFile, atomically: true, encoding: .utf8)
        try await editor.add(files: [newFile], to: archive, password: nil)
        var entries = try await engine.list(archive: archive, password: nil)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("b.txt") })

        // Rename it.
        try await editor.rename(entry: "b.txt", to: "renamed.txt", in: archive, password: nil)
        entries = try await engine.list(archive: archive, password: nil)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("renamed.txt") })
        XCTAssertFalse(entries.contains { $0.path == "b.txt" })

        // Delete it.
        try await editor.delete(entries: ["renamed.txt"], from: archive, password: nil)
        entries = try await engine.list(archive: archive, password: nil)
        XCTAssertFalse(entries.contains { $0.path.hasSuffix("renamed.txt") })
    }

    /// Editing an ENCRYPTED archive: the password reaches 7zz via stdin (never
    /// argv). Each edit rewrites the archive and re-encrypts its content, so 7zz
    /// prompts Enter+Verify — the password is fed as two stdin lines.
    func testEditEncryptedArchive() async throws {
        let src = workDir.appendingPathComponent("esrc")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "one".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("enc-edit.7z")
        let password = "correct horse battery staple"
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip, password: password)))

        // Add a file to the encrypted archive (write path: Enter+Verify prompts).
        let newFile = workDir.appendingPathComponent("b.txt")
        try "two".write(to: newFile, atomically: true, encoding: .utf8)
        try await editor.add(files: [newFile], to: archive, password: password)
        var entries = try await engine.list(archive: archive, password: password)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("b.txt") })

        // Rename it (rewrites + re-encrypts the archive).
        try await editor.rename(entry: "b.txt", to: "renamed.txt", in: archive, password: password)
        entries = try await engine.list(archive: archive, password: password)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("renamed.txt") })

        // Delete it (rewrites + re-encrypts the archive).
        try await editor.delete(entries: ["renamed.txt"], from: archive, password: password)
        entries = try await engine.list(archive: archive, password: password)
        XCTAssertFalse(entries.contains { $0.path.hasSuffix("renamed.txt") })

        // Content is still protected: a wrong password fails the integrity test.
        do {
            _ = try await engine.test(archive: archive, password: "wrong")
            XCTFail("wrong password must fail integrity test on encrypted content")
        } catch {}
    }

    /// Delete/rename must work on archives whose entry names are NFC (e.g.
    /// Vietnamese zips from Windows/web). Entry names must not travel on argv:
    /// NSTask NFD-normalizes argv while 7zz matches byte-exactly.
    func testDeleteAndRenameNFCNamedEntries() async throws {
        let entryName = "ti\u{1EBF}ng vi\u{1EC7}t.txt"  // NFC

        // Rename, then verify the new NFC name is stored byte-exactly.
        let renameArchive = workDir.appendingPathComponent("nfc-rename.zip")
        try TestSupport.writeStoredZip(
            entryName: entryName, content: "xin chào", to: renameArchive)
        let newName = "m\u{1EDB}i.txt"  // "mới.txt", NFC
        try await editor.rename(entry: entryName, to: newName, in: renameArchive, password: nil)
        var entries = try await engine.list(archive: renameArchive, password: nil)
        XCTAssertEqual(entries.map { Array($0.path.utf8) }, [Array(newName.utf8)],
                       "renamed entry should carry the new NFC name byte-exactly")

        // Delete.
        let deleteArchive = workDir.appendingPathComponent("nfc-delete.zip")
        try TestSupport.writeStoredZip(
            entryName: entryName, content: "xin chào", to: deleteArchive)
        try await editor.delete(entries: [entryName], from: deleteArchive, password: nil)
        entries = try await engine.list(archive: deleteArchive, password: nil)
        XCTAssertTrue(entries.isEmpty, "NFC-named entry should have been deleted")
    }

    /// Adding an on-disk NFC-named file must store its NFC bytes, not an
    /// argv-mangled NFD variant.
    func testAddStoresOnDiskNameNormalization() async throws {
        let archive = try await makeArchive()
        let name = "th\u{00EA}m m\u{1EDB}i.txt"  // "thêm mới.txt", NFC
        let file = try TestSupport.createFileRawName(name, in: workDir, content: "ba")

        try await editor.add(files: [file], to: archive, password: nil)
        let entries = try await engine.list(archive: archive, password: nil)
        let stored = entries.map { Array($0.path.utf8) }
        XCTAssertTrue(stored.contains(Array(name.utf8)),
                      "added entry should keep the on-disk NFC bytes")
    }

    /// Repack (decompress → add → recompress) round-trip on a .tar.gz.
    func testAddViaRepackRoundtrip() async throws {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "one".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("pack.tar.gz")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .gzip)))

        let newFile = workDir.appendingPathComponent("extra.txt")
        try "two".write(to: newFile, atomically: true, encoding: .utf8)
        try await editor.addViaRepack(files: [newFile], to: archive) { _ in }

        // Verify the inner tar now contains the added file (system tar lists it).
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-tzf", archive.path]
        let out = Pipe()
        tar.standardOutput = out
        try tar.run()
        let listing = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        XCTAssertTrue(listing.contains("extra.txt"), "repacked tar should contain the added file")
        XCTAssertTrue(listing.contains("a.txt"), "repacked tar should keep the original file")
    }

    func testRenameArgumentBuilding() {
        let args = SevenZipArchiveEditor.renameArguments(
            archive: URL(fileURLWithPath: "/tmp/a.7z"),
            listFile: URL(fileURLWithPath: "/tmp/pairs.txt"), password: "pw")
        XCTAssertEqual(args.first, "rn")
        // The password is bare `-p` (fed via stdin), never inlined into argv.
        XCTAssertTrue(args.contains("-p"))
        XCTAssertFalse(args.contains { $0.hasPrefix("-p") && $0 != "-p" })
        XCTAssertFalse(args.contains { $0.contains("pw") })
        // Old/new names must not appear on argv; they travel via the listfile.
        XCTAssertEqual(Array(args.suffix(2)), ["/tmp/a.7z", "@/tmp/pairs.txt"])
    }
}
