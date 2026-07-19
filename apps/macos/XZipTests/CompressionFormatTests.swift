@testable import XZip
import XCTest
import XZIPCore

private final class SizeScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func scan(_ sources: [URL]) -> Int64 {
        lock.lock()
        count += 1
        lock.unlock()
        return 10
    }
}

private enum OperationLifecycleError: Error {
    case failed
}

final class CompressionFormatTests: XCTestCase {
    func testPrimaryAndAdvancedFormatChoices() {
        XCTAssertEqual(CompressionFormat.primaryChoices, [.zip, .sevenZip, .tar, .dmg])
        XCTAssertEqual(
            CompressionFormat.advancedChoices,
            [.tarGzip, .tarBzip2, .tarXz, .tarZstd]
        )
        XCTAssertEqual(
            CompressionFormat.compressChoices,
            [.zip, .sevenZip, .tar, .dmg, .tarGzip, .tarBzip2, .tarXz, .tarZstd]
        )
    }

    func testArchiveFileExtensions() {
        let expected: [CompressionFormat: String] = [
            .zip: "zip", .sevenZip: "7z", .tar: "tar", .dmg: "dmg",
            .tarGzip: "tar.gz", .tarBzip2: "tar.bz2",
            .tarXz: "tar.xz", .tarZstd: "tar.zst"
        ]
        for (format, fileExtension) in expected {
            XCTAssertEqual(format.fileExtension, fileExtension)
        }
    }

    func testEveryCompressionFormatMapsToCoreAndBack() {
        let pairs: [(CompressionFormat, XZIPCore.ArchiveFormat)] = [
            (.zip, .zip), (.sevenZip, .sevenZip), (.tar, .tar), (.dmg, .dmg),
            (.tarGzip, .gzip), (.tarBzip2, .bzip2),
            (.tarXz, .xz), (.tarZstd, .zstd)
        ]
        for (ui, core) in pairs {
            XCTAssertEqual(ModelMapping.coreFormat(from: ui), core)
            XCTAssertEqual(ModelMapping.uiFormat(from: core), ui)
        }
    }

    func testPresetRoundTripPreservesEveryFormat() {
        for format in CompressionFormat.compressChoices {
            let original = ArchivePreset(
                name: format.rawValue,
                summary: "Test",
                format: format,
                level: .balanced
            )
            let restored = ModelMapping.uiPreset(from: ModelMapping.corePreset(from: original))
            XCTAssertEqual(restored.format, format)
        }
    }

    func testVisibleChoicesCollapsedAndExpanded() {
        XCTAssertEqual(
            CompressionFormatPicker.visibleChoices(isExpanded: false, selection: .zip),
            CompressionFormat.primaryChoices
        )
        XCTAssertEqual(
            CompressionFormatPicker.visibleChoices(isExpanded: true, selection: .zip),
            CompressionFormat.compressChoices
        )
    }

    func testCollapsedPickerKeepsSelectedAdvancedFormatVisible() {
        XCTAssertEqual(
            CompressionFormatPicker.visibleChoices(isExpanded: false, selection: .tarZstd),
            CompressionFormat.primaryChoices + [.tarZstd]
        )
    }

    func testEveryPersistableDefaultFormatIsCompressible() {
        XCTAssertEqual(Set(CompressionFormat.allCases), Set(CompressionFormat.compressChoices))
    }

    func testUnsupportedFormatsDropPasswordAndSplitOptions() {
        for format in [CompressionFormat.tar, .dmg, .tarGzip, .tarBzip2, .tarXz, .tarZstd] {
            let options = ModelMapping.compressionOptions(
                format: format,
                level: .balanced,
                password: "secret",
                splitSizeMB: 100,
                excludeMacNoise: false
            )
            XCTAssertNil(options.password)
            XCTAssertNil(options.volumeSize)
            XCTAssertFalse(options.encryptFileNames)
        }
    }

    func testUnsupportedPresetDropsEncryptionAndSplitState() {
        let preset = ArchivePreset(
            name: "TAR Zstandard",
            summary: "Test",
            format: .tarZstd,
            level: .balanced,
            encryptionEnabled: true,
            splitSizeMB: 100
        )
        let core = ModelMapping.corePreset(from: preset)
        XCTAssertNil(core.options.password)
        XCTAssertNil(core.options.volumeSize)

        let restored = ModelMapping.uiPreset(from: core)
        XCTAssertFalse(restored.encryptionEnabled)
        XCTAssertNil(restored.splitSizeMB)
    }

    func testDMGDropsUnsupportedExclusionPatterns() {
        let options = ModelMapping.compressionOptions(
            format: .dmg, level: .balanced, password: nil,
            splitSizeMB: nil, excludeMacNoise: true)
        XCTAssertTrue(options.exclusionPatterns.isEmpty)
    }

    func testUIEntryClampsUInt64Sizes() {
        let coreEntry = XZIPCore.ArchiveEntry(
            path: "huge.bin",
            uncompressedSize: .max,
            compressedSize: .max,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )

        let entry = ModelMapping.uiEntry(from: coreEntry)

        XCTAssertEqual(entry.originalSize, Int64.max)
        XCTAssertEqual(entry.compressedSize, Int64.max)
    }

    func testTotalInputBytesRecursivelyCountsRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-input-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 11).write(to: nested.appendingPathComponent("b.bin"))
        XCTAssertEqual(AppModel.totalInputBytes(of: [root]), 18)
    }


    func testByteCountMathUsesSaturatingNonnegativeSum() {
        XCTAssertEqual(ByteCountMath.sum([5, -1, 7]), 12)
        XCTAssertEqual(ByteCountMath.sum([Int64.max, 1]), Int64.max)
        XCTAssertEqual(
            ByteCountMath.adding(Int64.max, to: Int64.max),
            Int64.max
        )
    }

    func testTotalInputBytesIncludesPackageDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-input-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let packageContents = root
            .appendingPathComponent("Fixture.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageContents,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 7)
            .write(to: root.appendingPathComponent("outside.bin"))
        try Data(repeating: 2, count: 13)
            .write(to: packageContents.appendingPathComponent("inside.bin"))

        XCTAssertEqual(AppModel.totalInputBytes(of: [root]), 20)
    }


    func testCompressionShareInfoSkipsScanForQuietCompression() async {
        let probe = SizeScanProbe()
        let info = await AppModel.makeCompressionShareInfo(
            outputURL: URL(fileURLWithPath: "/tmp/unused"),
            sources: [],
            quiet: true,
            wasEncrypted: false,
            sizeScanner: probe.scan
        )

        XCTAssertNil(info)
        XCTAssertEqual(probe.callCount, 0)
    }

    func testCompressionShareInfoSkipsScanWithoutSuccessfulOutput() async {
        let probe = SizeScanProbe()
        let info = await AppModel.makeCompressionShareInfo(
            outputURL: nil,
            sources: [],
            quiet: false,
            wasEncrypted: false,
            sizeScanner: probe.scan
        )

        XCTAssertNil(info)
        XCTAssertEqual(probe.callCount, 0)
    }

    func testCompressionShareInfoScansAfterSuccessfulNonQuietCompression() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzip-share-info-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try Data([0, 1, 2, 3]).write(to: outputURL)
        let probe = SizeScanProbe()

        let info = await AppModel.makeCompressionShareInfo(
            outputURL: outputURL,
            sources: [],
            quiet: false,
            wasEncrypted: true,
            sizeScanner: probe.scan
        )

        XCTAssertEqual(info?.sizeBytes, 4)
        XCTAssertEqual(info?.savedPercent, 60)
        XCTAssertEqual(info?.isEncrypted, true)
        XCTAssertEqual(probe.callCount, 1)
    }

    @MainActor
    func testFailedOperationDoesNotInvokeAsyncCompletion() async {
        let completion = expectation(description: "Async completion is not invoked")
        completion.isInverted = true
        let operation = ArchiveOperation(
            title: "Failure",
            kind: .compress,
            state: .running,
            progress: 0,
            currentItem: "",
            detail: ""
        )
        let model = AppModel()

        model.run(operation, onComplete: { _ in
            await Task.yield()
            completion.fulfill()
        }) {
            AsyncThrowingStream<Double, Error> { continuation in
                continuation.finish(throwing: OperationLifecycleError.failed)
            }
        }

        await fulfillment(of: [completion], timeout: 0.2)
        XCTAssertEqual(
            model.operations.first(where: { $0.id == operation.id })?.state,
            .failed
        )
    }

    @MainActor
    func testCancelledOperationDoesNotInvokeAsyncCompletion() async {
        let started = expectation(description: "Operation stream started")
        let completion = expectation(description: "Async completion is not invoked")
        completion.isInverted = true
        let operation = ArchiveOperation(
            title: "Cancellation",
            kind: .compress,
            state: .running,
            progress: 0,
            currentItem: "",
            detail: ""
        )
        let model = AppModel()

        model.run(operation, onComplete: { _ in
            await Task.yield()
            completion.fulfill()
        }) {
            AsyncThrowingStream<Double, Error> { _ in
                started.fulfill()
            }
        }

        await fulfillment(of: [started], timeout: 1)
        model.cancel(operation.id)
        await fulfillment(of: [completion], timeout: 0.2)
        XCTAssertEqual(
            model.operations.first(where: { $0.id == operation.id })?.state,
            .cancelled
        )
    }


    @MainActor
    func testClearingCompletedOperationDropsAsyncCompletionTaskHandle() async {
        let completionStarted = expectation(description: "Async completion started")
        let completionFinished = expectation(description: "Async completion finished")
        var gateContinuation: AsyncStream<Void>.Continuation?
        let gate = AsyncStream<Void> { gateContinuation = $0 }
        var wasCancelled = false
        let operation = ArchiveOperation(
            title: "Clear completed",
            kind: .compress,
            state: .running,
            progress: 0,
            currentItem: "",
            detail: ""
        )
        let model = AppModel()

        model.run(operation, onComplete: { _ in
            completionStarted.fulfill()
            for await _ in gate { break }
            wasCancelled = Task.isCancelled
            completionFinished.fulfill()
        }) {
            AsyncThrowingStream<Double, Error> { continuation in
                continuation.finish()
            }
        }

        await fulfillment(of: [completionStarted], timeout: 1)
        XCTAssertEqual(
            model.operations.first(where: { $0.id == operation.id })?.state,
            .completed
        )
        model.clearFinishedOperations()
        model.cancel(operation.id)
        gateContinuation?.yield(())
        gateContinuation?.finish()
        await fulfillment(of: [completionFinished], timeout: 1)

        XCTAssertFalse(wasCancelled)
    }
}
