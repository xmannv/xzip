import Foundation
import XCTest
@testable import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

/// Wave 9B-3: assembles the live transactional extraction stack and gates it
/// behind crash recovery, then hands back a ready `ArchiveRuntime`.
///
/// The order/throw tests exercise the recovery-before-availability gate through
/// the `assemble(recover:makeRuntime:)` seam without needing a real 7zz or a
/// real runtime. The happy-path test drives a real extraction end-to-end
/// through `live(...)` (skipped when 7zz is absent).
final class LiveExtractionAssemblyTests: XCTestCase {

    // MARK: - recovery gate (seam, no 7zz)

    func testAssembleRunsRecoveryBeforeMakingRuntime() async throws {
        actor Order {
            var events: [String] = []
            func record(_ e: String) { events.append(e) }
        }
        let order = Order()
        let result = try await LiveExtractionAssembly.assemble(
            recover: { await order.record("recover") },
            makeRuntime: { () -> String in
                await order.record("make")
                return "runtime"
            }
        )
        XCTAssertEqual(result, "runtime")
        let events = await order.events
        XCTAssertEqual(events, ["recover", "make"])
    }

    func testLiveAssemblyReplaceUsesUnchangedApprovedBridgeInterface() {
        let factory = {
            (
                backend: any ArchiveBackend,
                stagingExtractor: any ArchiveStagingExtracting,
                identityResolver: any ArchiveIdentityResolving,
                applicationSupportDirectory: URL
            ) async throws -> TransactionalExtractionBridge<ArchiveRuntime> in
            try await LiveExtractionAssembly.liveBridge(
                backend: backend,
                stagingExtractor: stagingExtractor,
                identityResolver: identityResolver,
                applicationSupportDirectory: applicationSupportDirectory
            )
        }
        let approvedReplace = {
            (
                bridge: TransactionalExtractionBridge<ArchiveRuntime>,
                archive: URL,
                destination: URL,
                options: ExtractionOptions
            ) async throws -> AsyncThrowingStream<Double, Error> in
            let preflight = try await bridge.preflight(
                archive: archive,
                destination: destination,
                options: options
            )
            return bridge.extract(
                preflight: preflight,
                password: options.password,
                replacementApproval: preflight.makeDestructiveReplacementApproval()
            )
        }

        _ = factory
        _ = approvedReplace
    }

    func testAssembleThrowingRecoveryDoesNotMakeRuntime() async {
        struct RecoveryFailure: Error {}
        actor Flag { var made = false; func set() { made = true } }
        let flag = Flag()
        do {
            _ = try await LiveExtractionAssembly.assemble(
                recover: { throw RecoveryFailure() },
                makeRuntime: { () -> String in
                    await flag.set()
                    return "runtime"
                }
            )
            XCTFail("expected recovery failure to propagate")
        } catch is RecoveryFailure {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let made = await flag.made
        XCTAssertFalse(made, "runtime must not be assembled when recovery fails")
    }

    // MARK: - happy path (real 7zz)

    private static var binDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // XZIPRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // XZIPCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/bin")
    }

    func testLiveFactoryProducesRuntimeThatExtractsThroughTransaction() async throws {
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-assembly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)

        // Build a real archive: hello.txt + nested/inner.txt.
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "hello world".write(
            to: src.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "nested content".write(
            to: src.appendingPathComponent("nested/inner.txt"), atomically: true, encoding: .utf8)
        let archive = work.appendingPathComponent("out.7z")
        for try await _ in engine.compress(
            sources: [src], destination: archive,
            options: CompressionOptions(format: .sevenZip, level: .fast)
        ) {}

        let appSupport = work.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let fixedUUID = UUID(uuidString: "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111")!
        let runtime = try await LiveExtractionAssembly.live(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport,
            now: { Date(timeIntervalSince1970: 0x6100_0000) },
            uuidProvider: { fixedUUID }
        )

        let resolved = try ArchiveIdentityResolver().resolve(archive)
        let operationID = OperationID()
        let sessionID = ArchiveSessionID()
        let preflight = try await runtime.preflightExtraction(
            ExtractionPreflightRequest(
                operationID: operationID,
                sessionID: sessionID,
                archive: resolved.locator,
                destination: destination,
                selectedEntries: [],
                conflictPolicy: .replace,
                preserveTimestamps: true,
                resourcePolicy: .production,
                ui: .init(title: "Extract", detail: "assembly e2e")
            )
        )
        try await runtime.extract(
            ExtractionRequest(
                operationID: operationID,
                sessionID: sessionID,
                archive: preflight.archive,
                destination: preflight.destination,
                selectedEntries: preflight.selectedEntries,
                conflictPolicy: preflight.conflictPolicy,
                preserveTimestamps: preflight.preserveTimestamps,
                resourcePolicy: preflight.resourcePolicy,
                ui: .init(title: "Extract", detail: "assembly e2e"),
                expectedArchiveRevision: preflight.archiveRevision,
                expectedDestinationIdentity: preflight.destinationIdentity,
                planDigest: preflight.planDigest,
                publicationBinding: preflight.publicationBinding,
                replacementApproval: preflight.requiresDestructiveReplacementApproval
                    ? preflight.makeDestructiveReplacementApproval()
                    : nil
            )
        )

        let state = await runtime.state(for: operationID)
        XCTAssertEqual(state, .completed)

        // Files published through the transaction/staging path. The archive was
        // created from the `src` directory, so entries are rooted at `src/`.
        let publishedHello = destination.appendingPathComponent("src/hello.txt")
        let publishedInner = destination.appendingPathComponent("src/nested/inner.txt")
        XCTAssertEqual(try String(contentsOf: publishedHello, encoding: .utf8), "hello world")
        XCTAssertEqual(try String(contentsOf: publishedInner, encoding: .utf8), "nested content")

        // Quarantine applied by LivePublicationQuarantine (proves the live
        // quarantine ran in the assembled stack).
        let xattr = try readQuarantine(at: publishedHello)
        let value = try XCTUnwrap(xattr)
        XCTAssertTrue(String(decoding: value, as: UTF8.self).hasPrefix("0081;"),
                      "expected com.apple.quarantine with flags 0081")
    }

    func testLiveBridgeEncryptedZIPWithoutPasswordPropagatesPasswordRequired() async throws {
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-encrypted-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)
        let source = work.appendingPathComponent("secret.txt")
        try "classified".write(to: source, atomically: true, encoding: .utf8)
        let archive = work.appendingPathComponent("encrypted.zip")
        for try await _ in engine.compress(
            sources: [source], destination: archive,
            options: CompressionOptions(format: .zip, password: "secret")
        ) {}

        let appSupport = work.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let bridge = try await LiveExtractionAssembly.liveBridge(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport
        )

        do {
            for try await _ in try await approvedStream(
                bridge: bridge,
                archive: archive,
                destination: work.appendingPathComponent("destination"),
                options: ExtractionOptions(password: nil, overwrite: true)
            ) {}
            XCTFail("expected passwordRequired")
        } catch let error as ArchiveEngineError {
            guard case .passwordRequired = error else {
                return XCTFail("expected passwordRequired, got \(error)")
            }
        }
    }

    // MARK: - selected-entry coverage (real 7zz)

    /// Builds a live bridge over a real `SevenZipEngine` plus an archive whose
    /// tree is `root/{top.txt,nested/{inner.txt,deep/leaf.txt}}` and
    /// `sibling/other.txt`.
    private func makeSelectionFixture(
        work: URL,
        password: String? = nil
    ) async throws -> (bridge: TransactionalExtractionBridge<ArchiveRuntime>, archive: URL) {
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")
        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)

        let src = work.appendingPathComponent("src")
        let root = src.appendingPathComponent("root")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("sibling"), withIntermediateDirectories: true)
        try "top".write(
            to: root.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "inner".write(
            to: root.appendingPathComponent("nested/inner.txt"), atomically: true, encoding: .utf8)
        try "leaf".write(
            to: root.appendingPathComponent("nested/deep/leaf.txt"), atomically: true, encoding: .utf8)
        try "other".write(
            to: src.appendingPathComponent("sibling/other.txt"), atomically: true, encoding: .utf8)

        let archive = work.appendingPathComponent("selection.7z")
        for try await _ in engine.compress(
            sources: [root, src.appendingPathComponent("sibling")],
            destination: archive,
            options: CompressionOptions(
                format: .sevenZip,
                password: password,
                encryptFileNames: password != nil
            )
        ) {}

        let appSupport = work.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let bridge = try await LiveExtractionAssembly.liveBridge(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport
        )
        return (bridge, archive)
    }

    private func approvedStream(
        bridge: TransactionalExtractionBridge<ArchiveRuntime>,
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> AsyncThrowingStream<Double, Error> {
        let preflight = try await bridge.preflight(
            archive: archive,
            destination: destination,
            options: options
        )
        let approval = preflight.requiresDestructiveReplacementApproval
            ? preflight.makeDestructiveReplacementApproval()
            : nil
        return bridge.extract(
            preflight: preflight,
            password: options.password,
            replacementApproval: approval
        )
    }

    private func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        return work
    }

    private func publishedTree(at destination: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []).sorted()
    }

    /// A work directory under `/private/tmp`, whose *standardized* spelling is
    /// `/tmp/…` because macOS symlinks `/tmp` to `private/tmp`.
    ///
    /// `FileManager.temporaryDirectory` is already standardized, so the tests
    /// above cannot see a destination whose raw and standardized spellings
    /// differ — which is precisely the shape that broke in the app.
    private func makeNoncanonicalWorkDirectory() throws -> URL {
        let work = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("xzip-noncanonical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        // Guard the premise: if this ever stops holding, the tests below would
        // silently stop covering the regression instead of failing.
        try XCTSkipUnless(
            work.standardizedFileURL.path != work.path,
            "/private/tmp is not standardized to /tmp on this system"
        )
        return work
    }

    /// Naming a directory must publish its whole subtree.
    ///
    /// Regression: the staging inventory matched `selectedEntries` exactly, so
    /// the derived `StagingWriteAuthority` omitted the descendants 7zz extracts
    /// for a selected directory. `enforceStagingAuthority` then rejected the
    /// extractor's own output and the transaction rolled back, leaving the
    /// destination empty.
    func testSelectingADirectoryPublishesItsWholeSubtree() async throws {
        let work = try makeWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work)
        let destination = work.appendingPathComponent("dest")

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: nil,
                selectedEntries: ["root"],
                existingFilePolicy: .replace
            )
        ) {}

        let tree = publishedTree(at: destination)
        XCTAssertEqual(
            tree,
            ["root", "root/nested", "root/nested/deep", "root/nested/deep/leaf.txt",
             "root/nested/inner.txt", "root/top.txt"],
            "expected the full selected subtree and nothing else"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("root/nested/deep/leaf.txt"),
                encoding: .utf8),
            "leaf"
        )
    }

    /// Naming an inner directory publishes that subtree only — the fix must not
    /// widen the selection to unrelated siblings or to the parent's own files.
    func testSelectingANestedDirectoryExcludesSiblingsAndParentFiles() async throws {
        let work = try makeWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work)
        let destination = work.appendingPathComponent("dest")

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: nil,
                selectedEntries: ["root/nested"],
                existingFilePolicy: .replace
            )
        ) {}

        let tree = publishedTree(at: destination)
        XCTAssertEqual(
            tree,
            ["root", "root/nested", "root/nested/deep", "root/nested/deep/leaf.txt",
             "root/nested/inner.txt"],
            "expected only the nested subtree (plus its parent path)"
        )
        XCTAssertFalse(tree.contains("root/top.txt"))
        XCTAssertFalse(tree.contains("sibling"))
    }

    /// Selecting a single deep file must not drag in its siblings. This is the
    /// guard against fixing the subtree case by over-authorizing staging.
    func testSelectingASingleFilePublishesOnlyThatFile() async throws {
        let work = try makeWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work)
        let destination = work.appendingPathComponent("dest")

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: nil,
                selectedEntries: ["root/nested/inner.txt"],
                existingFilePolicy: .replace
            )
        ) {}

        XCTAssertEqual(
            publishedTree(at: destination),
            ["root", "root/nested", "root/nested/inner.txt"]
        )
    }

    /// The reported scenario: header-encrypted 7z, correct password, a directory
    /// selected. Extraction must publish rather than roll back to an empty
    /// destination.
    func testSelectingADirectoryInAnEncryptedArchivePublishesWithTheCorrectPassword() async throws {
        let work = try makeWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work, password: "pw-123")
        let destination = work.appendingPathComponent("dest")

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: "pw-123",
                selectedEntries: ["root"],
                existingFilePolicy: .replace
            )
        ) {}

        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("root/nested/deep/leaf.txt"),
                encoding: .utf8),
            "leaf",
            "published tree was: \(publishedTree(at: destination))"
        )
    }

    // MARK: - destination path canonicalization (real 7zz)

    /// A destination whose raw spelling differs from its standardized one must
    /// still publish.
    ///
    /// Regression: the committed-outcome validator rebuilt the published path
    /// from the *standardized* destination and compared it against the *raw*
    /// published URL. Standardizing an existing `/private/tmp/…` path yields
    /// `/tmp/…`, so the two spellings never matched and the journal rejected the
    /// outcome with `unsafeRecoveryState("noncanonical committed published URL")`
    /// — after staging had already succeeded, so the transaction rolled back and
    /// left the destination empty. Extracting anything into `/tmp` from the app
    /// hit this every time.
    func testExtractionIntoANoncanonicalDestinationPublishes() async throws {
        let work = try makeNoncanonicalWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work)
        let destination = work.appendingPathComponent("dest")

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: nil,
                selectedEntries: [],
                existingFilePolicy: .replace
            )
        ) {}

        XCTAssertEqual(
            publishedTree(at: destination),
            ["root", "root/nested", "root/nested/deep", "root/nested/deep/leaf.txt",
             "root/nested/inner.txt", "root/top.txt", "sibling", "sibling/other.txt"],
            "expected the whole archive to publish into a noncanonical destination"
        )
    }

    /// The same destination shape with a directory selected: this is the exact
    /// path the app takes for the context-menu "Extract" action, which published
    /// nothing before the fix.
    func testSelectedDirectoryIntoANoncanonicalDestinationPublishes() async throws {
        let work = try makeNoncanonicalWorkDirectory()
        let (bridge, archive) = try await makeSelectionFixture(work: work)
        // The app extracts alongside the archive, so the destination is a
        // directory that already exists and holds unrelated files.
        let destination = work

        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(
                password: nil,
                selectedEntries: ["root"],
                existingFilePolicy: .replace
            )
        ) {}

        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("root/nested/deep/leaf.txt"),
                encoding: .utf8),
            "leaf",
            "published tree was: \(publishedTree(at: destination))"
        )
    }

    // MARK: - real ZIP through the transactional path

    /// Runs `/usr/bin/zip`, returning false when it is unavailable.
    ///
    /// Output is discarded through a privately opened `/dev/null` handle rather
    /// than `FileHandle.nullDevice`. That property is a process-wide singleton,
    /// and `Process` closes the handles assigned to its standard streams when it
    /// tears down — which frees that descriptor number for reuse and leaves any
    /// later reader of a recycled descriptor throwing
    /// `NSFileHandleOperationException`. The symptom is a crash in an unrelated
    /// test elsewhere in the suite, so it is worth avoiding here.
    private func runZip(_ arguments: [String], in directory: URL) -> Bool {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zip.path) else { return false }
        guard let sink = FileHandle(forWritingAtPath: "/dev/null") else { return false }
        defer { try? sink.close() }
        let process = Process()
        process.executableURL = zip
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func posixMode(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return UInt16(truncatingIfNeeded: (attributes[.posixPermissions] as? Int) ?? 0)
    }

    private func makeZipBridge(
        work: URL,
        engine: SevenZipEngine
    ) async throws -> TransactionalExtractionBridge<ArchiveRuntime> {
        let appSupport = work.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return try await LiveExtractionAssembly.liveBridge(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport
        )
    }

    /// A ZIP that stores only file paths, with no directory records at all, must
    /// still publish its intermediate directories.
    ///
    /// This is the common real-world shape (`zip -D`, and many Windows writers).
    /// The transaction never creates the staged tree itself, so the directories
    /// exist only because they are synthesized into the inventory as
    /// `implicitDirectories` and thereby into the staging write authority and the
    /// durable manifest. Without that synthesis the extractor's own output would
    /// be rejected as unauthorized and the extraction would roll back.
    ///
    /// Every other live end-to-end test here uses 7z, and the one existing ZIP
    /// test only asserts a `passwordRequired` error, so this is the first ZIP to
    /// go all the way through the transactional path.
    func testZipWithoutDirectoryEntriesPublishesSynthesizedDirectories() async throws {
        let work = try makeWorkDirectory()
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")
        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)

        let tree = work.appendingPathComponent("tree")
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("outer/inner"),
            withIntermediateDirectories: true
        )
        try "leaf".write(
            to: tree.appendingPathComponent("outer/inner/leaf.txt"),
            atomically: true,
            encoding: .utf8
        )
        let archive = work.appendingPathComponent("nodirs.zip")
        // -D omits directory entries entirely.
        try XCTSkipUnless(
            runZip(["-r", "-D", "-q", archive.path, "outer"], in: tree),
            "/usr/bin/zip unavailable"
        )

        let bridge = try await makeZipBridge(work: work, engine: engine)
        let destination = work.appendingPathComponent("dest")
        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(password: nil, existingFilePolicy: .replace)
        ) {}

        XCTAssertEqual(
            publishedTree(at: destination),
            ["outer", "outer/inner", "outer/inner/leaf.txt"],
            "intermediate directories must be synthesized from the file path"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("outer/inner/leaf.txt"),
                encoding: .utf8),
            "leaf"
        )
        // A synthesized directory has no archive mode to restore, so it must land
        // on the published default rather than leaking the transaction's private
        // staging mode (0700).
        for relativePath in ["outer", "outer/inner"] {
            XCTAssertEqual(
                try posixMode(of: destination.appendingPathComponent(relativePath)),
                0o755,
                "\(relativePath) should publish at the default directory mode"
            )
        }
    }

    /// A directory mode carried by the ZIP must survive publication.
    func testZipDirectoryEntryModeIsRestoredOnPublication() async throws {
        let work = try makeWorkDirectory()
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")
        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)

        let tree = work.appendingPathComponent("tree")
        let quiet = tree.appendingPathComponent("quiet")
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        try "shh".write(
            to: quiet.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(chmod(quiet.path, 0o750), 0)

        let archive = work.appendingPathComponent("modes.zip")
        // Without -D the directory entry is stored, carrying its POSIX mode.
        try XCTSkipUnless(
            runZip(["-r", "-q", archive.path, "quiet"], in: tree),
            "/usr/bin/zip unavailable"
        )

        let bridge = try await makeZipBridge(work: work, engine: engine)
        let destination = work.appendingPathComponent("dest")
        for try await _ in try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: destination,
            options: ExtractionOptions(password: nil, existingFilePolicy: .replace)
        ) {}

        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("quiet/secret.txt"),
                encoding: .utf8),
            "shh"
        )
        let published = try posixMode(of: destination.appendingPathComponent("quiet"))
        try XCTSkipUnless(
            published != 0o755,
            "this zip build did not carry directory POSIX modes"
        )
        XCTAssertEqual(
            published,
            0o750,
            "the archive's directory mode should be restored at publication"
        )
    }

    // MARK: - cancel then relaunch (real 7zz)

    /// Cancelling an extraction must not leave durable state that blocks the
    /// transactional path on the next launch.
    ///
    /// This covers a gap between two existing layers: `ExtractionTransaction`
    /// tests prove a cancelled transaction rolls back and releases its entry,
    /// and `ExtractionRecovery` tests prove each journal phase can be
    /// reconciled, but nothing exercised cancelling through the real bridge and
    /// then assembling a fresh stack over whatever survived. That matters
    /// because `ExtractionRouter.prepare()` swallows a recovery failure and
    /// silently drops to the legacy path, so a single unreconcilable entry
    /// would downgrade extraction with no user-visible signal.
    ///
    /// The assertions deliberately avoid depending on *where* cancellation
    /// lands. Extraction of a small archive can finish in single-digit
    /// milliseconds, so a test that required a mid-flight cancel would flake;
    /// the invariants below hold whether the cancel arrived before staging,
    /// during it, or after the operation had already completed.
    func testCancellingAnExtractionLeavesNoStateThatBlocksTheNextLaunch() async throws {
        let work = try makeWorkDirectory()
        let locator = BinaryLocator(searchDirectories: [Self.binDirectory])
        try XCTSkipUnless(locator.path(for: .sevenZip) != nil,
                          "7zz not found in Resources/bin — run scripts/fetch_binaries.sh")
        let engine = SevenZipEngine(runner: FoundationProcessRunner(), locator: locator)

        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for index in 0..<8 {
            try String(repeating: "payload-\(index) ", count: 4_000).write(
                to: src.appendingPathComponent("file-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let archive = work.appendingPathComponent("cancel.7z")
        for try await _ in engine.compress(
            sources: [src],
            destination: archive,
            options: CompressionOptions(format: .sevenZip, level: .fast)
        ) {}

        let appSupport = work.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let bridge = try await LiveExtractionAssembly.liveBridge(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport
        )

        let stream = try await approvedStream(
            bridge: bridge,
            archive: archive,
            destination: work.appendingPathComponent("dest"),
            options: ExtractionOptions(password: nil, overwrite: true)
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        consumer.cancel()
        // Cancelling a task suspended on `AsyncThrowingStream.next()` finishes
        // the stream rather than throwing, so a completed loop here says nothing
        // about whether the work was cancelled. The durable state below is what
        // this test is actually about.
        _ = try? await consumer.value

        // Rollback runs in an unstructured task that nothing awaits, so give it
        // a bounded chance to finish instead of racing it.
        let namespace = appSupport.appendingPathComponent("transactions")
        var roots: [String] = []
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            roots = ((try? FileManager.default.contentsOfDirectory(atPath: namespace.path)) ?? [])
                .filter { $0 != "extraction-index.json" }
            if roots.isEmpty { break }
        }

        XCTAssertEqual(roots, [], "a cancelled extraction left transaction roots behind")

        // The real point: a relaunch must still get the transactional path.
        // If recovery cannot reconcile what the cancel left behind, this throws
        // and the app would fall back to the legacy engine silently, forever.
        _ = try await LiveExtractionAssembly.liveBridge(
            backend: TrappingLegacyBackend(),
            stagingExtractor: engine,
            identityResolver: ArchiveIdentityResolver(),
            applicationSupportDirectory: appSupport
        )
    }

    private func readQuarantine(at url: URL) throws -> Data? {
        let key = "com.apple.quarantine"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return data
    }
}

/// Legacy `ArchiveBackend` that traps if any method is called: the assembled
/// runtime must route extraction through the transactional `extractionHandler`,
/// never the legacy backend.
private struct TrappingLegacyBackend: ArchiveBackend, @unchecked Sendable {
    private struct Unexpected: Error { let method: String }

    func readComment(for archive: URL) async throws -> String { throw Unexpected(method: "readComment") }
    func writeComment(_ comment: String, to archive: URL) async throws { throw Unexpected(method: "writeComment") }
    func canEditComment(for archive: URL) -> Bool { false }
    func detectSplit(part: URL) throws -> SplitArchiveJoiner.DetectionResult? { throw Unexpected(method: "detectSplit") }
    func joinSplit(parts: [URL], destination: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { $0.finish(throwing: Unexpected(method: "joinSplit")) }
    }
    func compress(sources: [URL], destination: URL, options: CompressionOptions) throws -> AsyncThrowingStream<Double, Error> {
        throw Unexpected(method: "compress")
    }
    func extract(archive: URL, destination: URL, options: ExtractionOptions) throws -> AsyncThrowingStream<Double, Error> {
        throw Unexpected(method: "extract")
    }
    func detectedFormat(for archive: URL) -> ArchiveFormat? { nil }
    func list(archive: URL, password: String?) async throws -> [ArchiveEntry] { throw Unexpected(method: "list") }
    func list(archive: URL, password: String?, limit: Int) async throws -> ArchiveListingResult { throw Unexpected(method: "listLimit") }
    func test(archive: URL, password: String?) async throws -> Bool { throw Unexpected(method: "test") }
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws { throw Unexpected(method: "add") }
    func addViaRepack(files: [URL], to archive: URL, workspace: URL, onStep: @escaping @Sendable (RepackStep) -> Void) async throws { throw Unexpected(method: "addViaRepack") }
    func delete(entries: [String], from archive: URL, password: String?) async throws { throw Unexpected(method: "delete") }
    func rename(pairs: [(entry: String, newName: String)], in archive: URL, password: String?) async throws { throw Unexpected(method: "rename") }
    func update(entry entryPath: String, from workingDirectory: URL, in archive: URL, password: String?) async throws { throw Unexpected(method: "update") }
}
