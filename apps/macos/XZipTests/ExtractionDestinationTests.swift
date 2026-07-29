import Foundation
import XCTest
import XZIPCore
import XZIPDomain
import XZIPRuntime
@testable import XZip

/// Extracting to a named folder must not scatter the archive's contents into it.
///
/// The destination arithmetic was inlined at six call sites and had drifted:
/// Finder and "Extract All" wrapped the contents in a folder named after the
/// archive, while extracting to a Place, to a Downloads/Desktop chip, or to a
/// folder picked from the panel unpacked straight into the target.
final class ExtractionDestinationTests: XCTestCase {

    // MARK: - The path arithmetic

    func testWrapsContentsInAFolderNamedAfterTheArchive() {
        let archive = URL(fileURLWithPath: "/tmp/photos.zip")
        XCTAssertEqual(
            ExtractionDestination.folder(for: archive, in: URL(fileURLWithPath: "/Users/me/Desktop")),
            URL(fileURLWithPath: "/Users/me/Desktop/photos", isDirectory: true)
        )
    }

    func testFolderBesideArchiveSitsNextToIt() {
        XCTAssertEqual(
            ExtractionDestination.folderBesideArchive(URL(fileURLWithPath: "/tmp/docs/report.7z")),
            URL(fileURLWithPath: "/tmp/docs/report", isDirectory: true)
        )
    }

    /// Only the last extension comes off, so `foo.tar.gz` stays recognisable as
    /// `foo.tar` instead of collapsing to `foo`.
    func testMultiPartExtensionLosesOnlyTheLastComponent() {
        XCTAssertEqual(
            ExtractionDestination.baseName(of: URL(fileURLWithPath: "/tmp/backup.tar.gz")),
            "backup.tar"
        )
    }

    /// The case that would silently reintroduce the bug: a name that is nothing
    /// but an extension strips to "", and `appendingPathComponent("")` returns the
    /// parent unchanged — extracting loose into it after all.
    func testExtensionOnlyNameDoesNotCollapseOntoTheParent() {
        let parent = URL(fileURLWithPath: "/Users/me/Desktop")
        let destination = ExtractionDestination.folder(
            for: URL(fileURLWithPath: "/tmp/.zip"),
            in: parent
        )
        XCTAssertEqual(destination, parent.appendingPathComponent(".zip", isDirectory: true))
        XCTAssertNotEqual(
            destination.standardizedFileURL, parent.standardizedFileURL,
            "the destination must never resolve to the parent itself"
        )
    }

    func testDotfileKeepsItsLeadingDot() {
        XCTAssertEqual(
            ExtractionDestination.baseName(of: URL(fileURLWithPath: "/tmp/.hidden.zip")),
            ".hidden"
        )
    }

    // MARK: - The call site

    /// Proves `extractToPlace` actually uses the helper. The arithmetic tests above
    /// would all still pass if the call site went on passing `place.url` straight
    /// through, which was the bug.
    @MainActor
    func testExtractingToAPlaceTargetsAFolderNamedAfterTheArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-dest-\(UUID().uuidString)", isDirectory: true)
        let place = root.appendingPathComponent("Desktop", isDirectory: true)
        let archive = root.appendingPathComponent("photos.zip")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
        defer { try? FileManager.default.removeItem(at: root) }

        // `.replace` keeps the conflict pre-scan out of the way.
        UserDefaults.standard.set(
            ConflictPolicy.replace.rawValue,
            forKey: XZIPDefaults.conflictPolicy
        )
        defer { UserDefaults.standard.removeObject(forKey: XZIPDefaults.conflictPolicy) }

        let engine = DestinationRecordingEngine()
        let bridge = DestinationRecordingBridge()
        let stagingVolume = try place.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier
        let router = ExtractionRouter(
            makeBridge: { bridge },
            resolveStagingVolume: { stagingVolume }
        )
        await router.prepare()
        let model = AppModel(
            service: ArchiveService(
                engineFactory: RecordingEngineFactory(engine: engine),
                editor: SilentEditor(),
                passwordStore: SilentPasswordStore(),
                presetStore: PresetStore(fileURL: root.appendingPathComponent("presets.json")),
                commentService: ArchiveCommentService(),
                splitJoiner: SplitArchiveJoiner()
            ),
            extractionRouter: router
        )

        model.openArchive(archive)
        async let recordedDestination = bridge.recordedDestination()
        model.extractToPlace(Place(name: "Desktop", url: place))

        let actualDestination = await recordedDestination
        XCTAssertEqual(
            actualDestination.standardizedFileURL,
            place.appendingPathComponent("photos", isDirectory: true).standardizedFileURL,
            "contents must land in a folder named after the archive, not loose in the Place"
        )
    }
}

private actor DestinationCapture {
    private var destination: URL?
    private var waiter: CheckedContinuation<URL, Never>?

    func record(_ destination: URL) {
        self.destination = destination
        waiter?.resume(returning: destination)
        waiter = nil
    }

    func next() async -> URL {
        if let destination { return destination }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class DestinationRecordingBridge: ExtractionBridging, @unchecked Sendable {
    private let capture = DestinationCapture()

    func recordedDestination() async -> URL {
        await capture.next()
    }

    func preflight(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) async throws -> ExtractionPreflight {
        await capture.record(destination)
        let archiveID = ArchiveID(identity: .canonicalPath(
            path: archive.path,
            incarnation: ArchiveIncarnationToken()
        ))
        let locator = ArchiveLocator(archiveID: archiveID, url: archive)
        return ExtractionPreflight(
            archive: locator,
            archiveRevision: ArchiveRevision(
                archiveID: archiveID,
                fileSize: 4,
                contentModificationDate: Date(timeIntervalSince1970: 100),
                boundedContentFingerprint: Data([0xAA])
            ),
            destination: destination,
            destinationIdentity: ExtractionDestinationIdentity(
                parent: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 10,
                    generation: 1
                ),
                root: .stable(
                    volumeIdentifier: 1,
                    fileIdentifier: 11,
                    generation: 1
                )
            ),
            selectedEntries: options.selectedEntries,
            conflictPolicy: .replace,
            preserveTimestamps: true,
            resourcePolicy: .production,
            planDigest: ExtractionPlanDigest(bytes: Data([0xBB])),
            publicationBinding: [],
            conflicts: [],
            destructiveReplacementPaths: []
        )
    }

    func extract(
        preflight: ExtractionPreflight,
        password: String?,
        replacementApproval: DestructiveReplacementApproval?
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1)
            continuation.finish()
        }
    }
}

/// Supplies archive listing to the model; extraction is recorded by the bridge.
private final class DestinationRecordingEngine: ArchiveEngine, @unchecked Sendable {
    let supportedFormats: Set<XZIPCore.ArchiveFormat> = [.zip]

    private let lock = NSLock()
    private var destination: URL?

    var lastDestination: URL? {
        lock.lock(); defer { lock.unlock() }
        return destination
    }

    func compress(
        sources: [URL],
        destination: URL,
        options: CompressionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func extract(
        archive: URL,
        destination: URL,
        options: ExtractionOptions
    ) -> AsyncThrowingStream<ArchiveProgress, Error> {
        lock.lock()
        self.destination = destination
        lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }

    func list(archive: URL, password: String?) async throws -> [XZIPCore.ArchiveEntry] { [] }

    func list(
        archive: URL,
        password: String?,
        limit: Int
    ) async throws -> ArchiveListingResult {
        ArchiveListingResult(entries: [], truncated: false)
    }

    func test(archive: URL, password: String?) async throws -> Bool { true }
}

private struct RecordingEngineFactory: ArchiveEngineProviding {
    let engine: DestinationRecordingEngine

    func engine(for format: XZIPCore.ArchiveFormat) throws -> any ArchiveEngine { engine }
    func engine(forArchive url: URL) throws -> any ArchiveEngine { engine }
}

private final class SilentEditor: ArchiveEditing, @unchecked Sendable {
    func add(files: [URL], to archive: URL, password: String?, workingDirectory: URL?) async throws {}
    func delete(entries: [String], from archive: URL, password: String?) async throws {}
    func rename(
        pairs: [(entry: String, newName: String)],
        in archive: URL,
        password: String?
    ) async throws {}
    func update(
        entry entryPath: String,
        from workingDirectory: URL,
        in archive: URL,
        password: String?
    ) async throws {}
    func addViaRepack(
        files: [URL],
        to archive: URL,
        workspace: URL,
        onStep: @escaping @Sendable (RepackStep) -> Void
    ) async throws {}
}

private struct SilentPasswordStore: PasswordStoring {
    func save(password: String, for key: String) throws {}
    func password(for key: String) throws -> String? { nil }
    func delete(for key: String) throws {}
    func allKeys() throws -> [String] { [] }
}
