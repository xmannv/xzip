import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain

/// Wave 9A: pure tests for deriving an `ExtractionNodeKind` from `7zz l -slt`
/// fields. No binary required — exercises the classifier against captured
/// field shapes so symlink/directory/regular detection is deterministic.
final class SevenZipInventoryParserTests: XCTestCase {

    func testClassifyDirectoryFromFolderFlag() {
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "+", attributes: ""),
            .directory
        )
    }

    func testClassifyDirectoryFromUnixMode() {
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "D_ drwxr-xr-x"),
            .directory
        )
    }

    func testClassifyRegularFileFromUnixMode() {
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "_ -rw-r--r--"),
            .regularFile
        )
    }

    func testClassifySymbolicLinkFromUnixMode() {
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "_ lrwxrwxrwx"),
            .symbolicLink
        )
    }

    func testClassifyDefaultsToRegularFile() {
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: ""),
            .regularFile
        )
    }

    func testClassifyIgnoresNonModeTokenStartingWithTypeChar() {
        // An exactly-10-char attribute token that starts with 'l'/'d'/'-' but
        // whose 9-char tail is NOT a POSIX permission string must not be
        // misclassified — this exercises the permission-tail validation, not
        // just the length guard.
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "l123456789"),
            .regularFile
        )
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "dABCDEFGHI"),
            .regularFile
        )
        // A genuine symlink mode string is still classified correctly.
        XCTAssertEqual(
            SevenZipInventoryParser.classifyKind(folder: "", attributes: "_ lrwxrwxrwx"),
            .symbolicLink
        )
    }

    func testParseBuildsInventoryEntriesFromSltBlocks() {
        let output = """
        7-Zip fixture

        ----------
        Path = top/inner.txt
        Size = 11
        Attributes = _ -rw-r--r--

        Path = top
        Size = 0
        Folder = +
        Attributes = D_ drwxr-xr-x

        Path = top/link
        Size = 0
        Attributes = _ lrwxrwxrwx
        """
        let entries = SevenZipInventoryParser.parse(output)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        XCTAssertEqual(byPath["top/inner.txt"]?.kind, .regularFile)
        XCTAssertEqual(byPath["top/inner.txt"]?.size, 11)
        XCTAssertEqual(byPath["top"]?.kind, .directory)
        XCTAssertEqual(byPath["top"]?.isExplicitDirectory, true)
        XCTAssertEqual(byPath["top/link"]?.kind, .symbolicLink)
        // Wave 9B-5: the mode travels with the entry so publication can restore
        // the archive's directory permissions instead of the transaction's 0700.
        XCTAssertEqual(byPath["top"]?.posixMode, 0o755)
        XCTAssertEqual(byPath["top/inner.txt"]?.posixMode, 0o644)
        XCTAssertEqual(byPath["top/link"]?.posixMode, 0o777)
    }

    func testParsePOSIXModeReadsPermissionBits() {
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "D_ drwxr-xr-x"),
            0o755
        )
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "_ -rw-------"),
            0o600
        )
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "_ ----------"),
            0o000
        )
    }

    func testParsePOSIXModeReturnsNilWithoutModeToken() {
        // Archives written without POSIX modes (many Windows zips) carry only
        // DOS attribute flags. Publication falls back to a default rather than
        // inventing permissions.
        XCTAssertNil(SevenZipInventoryParser.parsePOSIXMode(attributes: "A"))
        XCTAssertNil(SevenZipInventoryParser.parsePOSIXMode(attributes: ""))
        XCTAssertNil(SevenZipInventoryParser.parsePOSIXMode(attributes: "l123456789"))
    }

    func testParsePOSIXModeDropsPrivilegedBitsButKeepsExecute() {
        // In a mode string, `s`/`t` mean the execute bit is set as well as the
        // special bit, while `S`/`T` mean it is not. The special bits themselves
        // are deliberately never decoded: an archive must not be able to request
        // setuid, setgid or sticky on extraction.
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "_ -rwsr-xr-x"),
            0o755,
            "setuid must not appear in the result, but its execute bit must"
        )
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "_ -rwSr--r--"),
            0o644,
            "capital S means execute is not set"
        )
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "D_ drwxrwxrwt"),
            0o777,
            "sticky must not appear in the result, but its execute bit must"
        )
        XCTAssertEqual(
            SevenZipInventoryParser.parsePOSIXMode(attributes: "D_ drwxrwxrwT"),
            0o776,
            "capital T means execute is not set"
        )
    }
}

private struct StagingLimitBinaryLocator: BinaryLocating {
    func path(for binary: BundledBinary) -> String? {
        "/fixture/7zz"
    }
}

private final class OversizedStagingProcessController:
    ProcessControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let cancelledExpectation: XCTestExpectation
    private var extractionContinuation:
        AsyncThrowingStream<ProcessEvent, Error>.Continuation?
    private var isCancelled = false

    init(cancelled: XCTestExpectation) {
        self.cancelledExpectation = cancelled
    }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        switch request.arguments.first {
        case "l":
            let listing = """
            7-Zip fixture

            ----------
            Path = oversized.bin
            Size = 2
            Attributes = _ -rw-r--r--
            """
            return ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
                continuation.yield(.stdout(Data(listing.utf8)))
                continuation.yield(.terminated(ProcessResult(
                    exitCode: 0,
                    standardOutput: listing,
                    standardError: ""
                )))
                continuation.finish()
            })

        case "x":
            do {
                let output = try XCTUnwrap(
                    request.arguments.first(where: { $0.hasPrefix("-o") })
                )
                let destination = URL(
                    fileURLWithPath: String(output.dropFirst(2)),
                    isDirectory: true
                )
                try Data([0, 1]).write(
                    to: destination.appendingPathComponent("oversized.bin")
                )
            } catch {
                return ProcessOutputStream(adapting: AsyncThrowingStream {
                    $0.finish(throwing: error)
                })
            }

            let stream = AsyncThrowingStream<ProcessEvent, Error> { continuation in
                lock.withLock {
                    extractionContinuation = continuation
                }
            }
            return ProcessOutputStream(
                adapting: stream,
                onCancel: { [weak self] in self?.cancelExtraction() }
            )

        default:
            return ProcessOutputStream(adapting: AsyncThrowingStream {
                $0.finish(throwing: ProcessRunnerError.launchFailed(
                    "Unexpected command"
                ))
            })
        }
    }

    private func cancelExtraction() {
        let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation? = lock.withLock {
            guard !isCancelled else { return nil }
            isCancelled = true
            let continuation = extractionContinuation
            extractionContinuation = nil
            return continuation
        }
        guard let continuation else { return }
        continuation.finish(throwing: ProcessRunnerError.cancelled)
        cancelledExpectation.fulfill()
    }
}

/// Wave 9A: integration tests for the `ArchiveStagingExtracting` conformance on
/// `SevenZipEngine`, exercising the real bundled `7zz`. Skipped when the binary
/// is absent.
final class SevenZipStagingExtractionTests: XCTestCase {

    private var engine: SevenZipEngine!
    private var workDir: URL!

    override func setUpWithError() throws {
        engine = SevenZipEngine(
            runner: FoundationProcessRunner(),
            locator: TestSupport.locator
        )
        workDir = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testStagingByteCapCancelsSevenZipBackendDuringMaterialization() async throws {
        let cancelled = expectation(description: "staging backend cancelled")
        let controller = OversizedStagingProcessController(cancelled: cancelled)
        let engine = SevenZipEngine(
            runner: controller,
            locator: StagingLimitBinaryLocator()
        )
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.7z")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try Data("archive".utf8).write(to: archive)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        let authority = try StagingWriteAuthority.fromAuthorizedEntries([
            .init(relativePath: "oversized.bin", kind: .regularFile)
        ])
        let policy = ArchiveResourcePolicy.production.replacingForTests(
            stagingByteCap: 1
        )

        do {
            _ = try await TestSupport.drain(
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
            XCTFail("Expected staging limit failure")
            return
        } catch {
            guard case let ArchiveFailure.resourceLimitExceeded(kind, limit, observed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(kind, .stagingBytes)
            XCTAssertEqual(limit, 1)
            XCTAssertGreaterThan(observed, 1)
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    private func makeArchive() async throws -> URL {
        try TestSupport.requireSevenZip()
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "hello world".write(
            to: src.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "nested content".write(
            to: src.appendingPathComponent("nested/inner.txt"), atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("out.7z")
        _ = try await TestSupport.drain(engine.compress(
            sources: [src],
            destination: archive,
            options: CompressionOptions(format: .sevenZip, level: .fast)
        ))
        return archive
    }

    func testFreshExtractionInventoryReportsEntries() async throws {
        let archive = try await makeArchive()
        let inventory = try await engine.freshExtractionInventory(
            archive: archive,
            selectedEntries: [],
            password: nil,
            policy: .production
        )
        let paths = Set(inventory.entries.map(\.path))
        XCTAssertTrue(paths.contains("src/hello.txt"))
        XCTAssertTrue(paths.contains("src/nested/inner.txt"))
        let hello = inventory.entries.first { $0.path == "src/hello.txt" }
        XCTAssertEqual(hello?.kind, .regularFile)
        XCTAssertEqual(hello?.size, UInt64("hello world".utf8.count))
    }

    func testFreshExtractionInventoryRespectsSelectedEntries() async throws {
        let archive = try await makeArchive()
        let inventory = try await engine.freshExtractionInventory(
            archive: archive,
            selectedEntries: ["src/hello.txt"],
            password: nil,
            policy: .production
        )
        let files = inventory.entries.filter { $0.kind != .directory }
        XCTAssertEqual(files.map(\.path), ["src/hello.txt"])
    }

    func testExtractToEmptyStagingDirectoryWritesAuthorizedNodes() async throws {
        let archive = try await makeArchive()
        let inventory = try await engine.freshExtractionInventory(
            archive: archive, selectedEntries: [], password: nil, policy: .production)
        let authority = try StagingWriteAuthority.fromInventory(inventory)

        let staging = workDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let stream = engine.extractToEmptyStagingDirectory(
            archive: archive,
            destination: staging,
            selectedEntries: [],
            authority: authority,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        _ = try await TestSupport.drain(stream)

        let hello = staging.appendingPathComponent("src/hello.txt")
        XCTAssertEqual(try String(contentsOf: hello, encoding: .utf8), "hello world")
        let inner = staging.appendingPathComponent("src/nested/inner.txt")
        XCTAssertEqual(try String(contentsOf: inner, encoding: .utf8), "nested content")
    }

    func testExtractToEmptyStagingDirectoryLeavesArchiveDirectoryModesIntact() async throws {
        // Staging deliberately does NOT touch modes. 7zz recreates archive
        // directories with the archive's own mode (commonly 0755), and the
        // transactional layer repairs that mode when it adopts the tree. Doing
        // it here as well would be redundant and, more importantly, would only
        // hold when extraction succeeds: a failed, cancelled, or killed
        // extraction would still leave archive-mode directories behind. So the
        // invariant belongs to adoption, and staging stays a pure authority
        // check. See `adoptTransactionOwnedDirectoryNoFollow`.
        let archive = try await makeArchive()
        let inventory = try await engine.freshExtractionInventory(
            archive: archive, selectedEntries: [], password: nil, policy: .production)
        let authority = try StagingWriteAuthority.fromInventory(inventory)

        let staging = workDir.appendingPathComponent("staging-mode")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let stream = engine.extractToEmptyStagingDirectory(
            archive: archive,
            destination: staging,
            selectedEntries: [],
            authority: authority,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        _ = try await TestSupport.drain(stream)

        // The fixture creates `src` and `src/nested` as 0755, so a staged tree
        // that still carries a non-0700 directory mode proves staging left the
        // mode alone. If this ever becomes 0700, either the fixture changed or
        // staging started mutating modes again.
        for relative in ["src", "src/nested"] {
            let dir = staging.appendingPathComponent(relative)
            var meta = stat()
            XCTAssertEqual(lstat(dir.path, &meta), 0, "lstat \(relative)")
            XCTAssertEqual(meta.st_mode & S_IFMT, S_IFDIR, "\(relative) should be a directory")
            XCTAssertEqual(
                meta.st_mode & 0o7777, 0o755,
                "staging must preserve the archive's directory mode for \(relative)"
            )
        }

        let hello = staging.appendingPathComponent("src/hello.txt")
        var fileMeta = stat()
        XCTAssertEqual(lstat(hello.path, &fileMeta), 0)
        XCTAssertEqual(fileMeta.st_mode & S_IFMT, S_IFREG)
    }

    func testExtractToEmptyStagingDirectoryRejectsUnauthorizedNode() async throws {
        let archive = try await makeArchive()
        let inventory = try await engine.freshExtractionInventory(
            archive: archive, selectedEntries: [], password: nil, policy: .production)
        // Narrow the authority so a node the archive really produces is NOT
        // authorized: the engine must refuse to leave it staged.
        let narrowed = ExtractionInventory(
            entries: inventory.entries.filter { $0.path != "src/nested/inner.txt" },
            implicitDirectories: inventory.implicitDirectories,
            advertisedOutputByteCount: 0,
            advertisedDictionaryByteCount: 0
        )
        let authority = try StagingWriteAuthority.fromInventory(narrowed)

        let staging = workDir.appendingPathComponent("staging2")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let stream = engine.extractToEmptyStagingDirectory(
            archive: archive,
            destination: staging,
            selectedEntries: [],
            authority: authority,
            preserveTimestamps: false,
            policy: .production,
            password: nil
        )
        // Assert the failure is the authorization refusal specifically, so an
        // unrelated extraction error cannot produce a false-green.
        do {
            _ = try await TestSupport.drain(stream)
            XCTFail("Expected staging authority enforcement to reject the unauthorized node")
        } catch let ArchiveEngineError.engineFailure(message) {
            XCTAssertTrue(
                message.contains("not authorized")
                    && message.contains("src/nested/inner.txt"),
                "Unexpected engine failure message: \(message)"
            )
        }
    }
}
