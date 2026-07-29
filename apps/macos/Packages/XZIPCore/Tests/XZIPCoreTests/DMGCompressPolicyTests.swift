import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

/// Tests for how `DMGEngine.compress` treats an existing file at the
/// destination.
///
/// E1: `usesAtomicPublication` was `options.existingFilePolicy == .fail`, so
/// every other policy pointed `hdiutil create -ov` straight at the destination.
/// `-ov` means overwrite, so `.skip` ("leave the existing file alone") and
/// `.keepBoth` ("keep the existing file, write mine beside it") both destroyed
/// the user's existing image — the precise outcome each policy exists to prevent.
///
/// `hdiutil` is faked: the real tool needs minutes and a mountable image, and the
/// behaviour under test is entirely in the engine's publication decision, not in
/// image creation. The fake writes a recognisable file at whatever path it is
/// given, which is what makes "who ended up at the destination" observable.
final class DMGCompressPolicyTests: XCTestCase {

    private static let existingBytes = Data("PRE-EXISTING IMAGE".utf8)

    /// Builds a destination directory holding an existing `out.dmg`.
    private func makeFixture() throws -> (root: URL, destination: URL, identity: FileSystemIdentity) {
        let root = try TestSupport.makeTempDir()
        let destination = root.appendingPathComponent("out.dmg")
        try Self.existingBytes.write(to: destination)
        let identity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        return (root, destination, identity)
    }

    private func compress(
        engine: DMGEngine,
        sources: [URL],
        destination: URL,
        policy: ExistingFilePolicy,
        parentIdentity: FileSystemIdentity
    ) async throws {
        var options = CompressionOptions(format: .dmg)
        options.existingFilePolicy = policy
        options.destinationParentIdentity = parentIdentity
        for try await _ in engine.compress(
            sources: sources,
            destination: destination,
            options: options
        ) {}
    }

    // MARK: - Publication-time conflict (the race the early check cannot cover)

    /// A pre-flight `fileExists` check can always be beaten: the file may appear
    /// while the image is still being built. These two tests drive that path by
    /// starting with a free destination (so the `.skip` fast path does not fire)
    /// and having the fake create the destination mid-build.
    ///
    /// Worth stating why this matters: the mutation check for E1 showed the
    /// simpler `.skip` test passing against the *pre-fix* code, because the early
    /// return alone satisfied it. Only this test actually exercises the exclusive
    /// rename that makes the decision safe. See `FakeHDIUtilCreateRunner.execute`
    /// for why the interloper has to be written before the image.
    func testSkipYieldsToAFileThatAppearsDuringCreation() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.dmg")
        let identity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let interloperBytes = Data("WON THE RACE".utf8)
        let runner = FakeHDIUtilCreateRunner(
            interloper: (destination, interloperBytes)
        )
        try await compress(
            engine: DMGEngine(runner: runner),
            sources: [source],
            destination: destination,
            policy: .skip,
            parentIdentity: identity
        )

        XCTAssertEqual(runner.createCount, 1, "the destination was free, so the image is built")
        XCTAssertEqual(
            try Data(contentsOf: destination), interloperBytes,
            ".skip must yield to a file that appeared after the initial check"
        )
    }

    func testKeepBothWorksAroundAFileThatAppearsDuringCreation() async throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.dmg")
        let identity = try XCTUnwrap(
            DarwinFileSystemIdentityReader().stableIdentity(for: root)
        )
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let interloperBytes = Data("WON THE RACE".utf8)
        let runner = FakeHDIUtilCreateRunner(
            interloper: (destination, interloperBytes)
        )
        try await compress(
            engine: DMGEngine(runner: runner),
            sources: [source],
            destination: destination,
            policy: .keepBoth,
            parentIdentity: identity
        )

        XCTAssertEqual(
            try Data(contentsOf: destination), interloperBytes,
            ".keepBoth must not clobber a file that appeared mid-build"
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("out_1.dmg")),
            FakeHDIUtilCreateRunner.createdBytes,
            "the new image must land beside it"
        )
    }

    // MARK: - The E1 regression

    func testSkipLeavesExistingImageIntact() async throws {
        let (root, destination, identity) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let runner = FakeHDIUtilCreateRunner()
        try await compress(
            engine: DMGEngine(runner: runner),
            sources: [source],
            destination: destination,
            policy: .skip,
            parentIdentity: identity
        )

        XCTAssertEqual(
            try Data(contentsOf: destination), Self.existingBytes,
            ".skip must not overwrite the existing image"
        )
        // Nothing was built, so hdiutil should never have run. Creating a
        // multi-gigabyte image only to discard it would be the wrong shape even
        // though the end state matches.
        XCTAssertEqual(runner.createCount, 0, ".skip should not invoke hdiutil at all")
    }

    func testKeepBothPreservesExistingImageAndWritesBeside() async throws {
        let (root, destination, identity) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let runner = FakeHDIUtilCreateRunner()
        try await compress(
            engine: DMGEngine(runner: runner),
            sources: [source],
            destination: destination,
            policy: .keepBoth,
            parentIdentity: identity
        )

        XCTAssertEqual(
            try Data(contentsOf: destination), Self.existingBytes,
            ".keepBoth must not overwrite the existing image"
        )
        let sibling = root.appendingPathComponent("out_1.dmg")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sibling.path),
            ".keepBoth must publish the new image under a free name"
        )
        XCTAssertEqual(
            try Data(contentsOf: sibling), FakeHDIUtilCreateRunner.createdBytes,
            "the sibling must be the newly created image, not a copy of the old one"
        )
    }

    func testFailReportsConflictAndLeavesExistingImageIntact() async throws {
        let (root, destination, identity) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let runner = FakeHDIUtilCreateRunner()
        do {
            try await compress(
                engine: DMGEngine(runner: runner),
                sources: [source],
                destination: destination,
                policy: .fail,
                parentIdentity: identity
            )
            XCTFail("Expected destinationConflict")
        } catch ArchiveFailure.destinationConflict {
            // expected
        }

        XCTAssertEqual(
            try Data(contentsOf: destination), Self.existingBytes,
            ".fail must leave the existing image untouched"
        )
    }

    func testReplaceOverwritesExistingImage() async throws {
        // The one policy whose contract *is* destruction. Included so the fix
        // cannot be "never overwrite", which would be just as wrong.
        let (root, destination, identity) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let runner = FakeHDIUtilCreateRunner()
        try await compress(
            engine: DMGEngine(runner: runner),
            sources: [source],
            destination: destination,
            policy: .replace,
            parentIdentity: identity
        )

        XCTAssertEqual(
            try Data(contentsOf: destination), FakeHDIUtilCreateRunner.createdBytes,
            ".replace must overwrite the existing image"
        )
    }

    func testNoExistingFileWritesToRequestedPathForEveryPolicy() async throws {
        // The common case must be unaffected by the conflict handling: with a
        // free destination every policy publishes at exactly the requested path.
        for policy in [
            ExistingFilePolicy.skip,
            .keepBoth,
            .fail,
            .replace
        ] {
            let root = try TestSupport.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("fresh.dmg")
            let identity = try XCTUnwrap(
                DarwinFileSystemIdentityReader().stableIdentity(for: root)
            )
            let source = root.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

            try await compress(
                engine: DMGEngine(runner: FakeHDIUtilCreateRunner()),
                sources: [source],
                destination: destination,
                policy: policy,
                parentIdentity: identity
            )

            XCTAssertEqual(
                try Data(contentsOf: destination),
                FakeHDIUtilCreateRunner.createdBytes,
                "\(policy) must publish at the requested path when it is free"
            )
        }
    }
}

/// Stands in for `hdiutil create`, writing a marker file at the output path it is
/// given so tests can tell the new image from a pre-existing one.
private final class FakeHDIUtilCreateRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    static let createdBytes = Data("NEWLY CREATED IMAGE".utf8)

    private let lock = NSLock()
    private var _createCount = 0
    private var _createPaths: [String] = []

    /// Content to drop at a path while "creating" the image, standing in for
    /// another process taking the destination name mid-build.
    private let interloper: (url: URL, bytes: Data)?

    init(interloper: (url: URL, bytes: Data)? = nil) {
        self.interloper = interloper
    }

    var createCount: Int { lock.withLock { _createCount } }
    var createPaths: [String] { lock.withLock { _createPaths } }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            do {
                continuation.yield(.terminated(try execute(arguments: request.arguments)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        })
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeHDIUtilError.unexpectedInvocation) }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeHDIUtilError.unexpectedInvocation) }
    }

    private func execute(arguments: [String]) throws -> ProcessResult {
        guard arguments.first == "create", let output = arguments.last else {
            throw FakeHDIUtilError.unexpectedInvocation
        }
        lock.withLock {
            _createCount += 1
            _createPaths.append(output)
        }
        // Order matters, and getting it wrong made these tests pass for the wrong
        // reason. The interloper must appear BEFORE the image is written: with the
        // fix the image goes to a workspace path, so the two writes touch
        // different files, but with the bug the image goes to the destination — the
        // same path the interloper took. Writing the interloper last would let it
        // overwrite the image and hide exactly the clobbering under test.
        if let interloper {
            try interloper.bytes.write(to: interloper.url)
        }
        // `hdiutil create -ov` truncates whatever is at the path, which is why
        // aiming it at the destination was destructive.
        try Self.createdBytes.write(to: URL(fileURLWithPath: output))
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

private enum FakeHDIUtilError: Error {
    case unexpectedInvocation
}
