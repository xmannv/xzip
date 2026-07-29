import Foundation
import XCTest
@testable import XZIPCore

final class ArchiveEngineFactoryTests: XCTestCase {
    func testUnknownArchiveFormatThrowsExplicitTypedFailureWithoutEngineFallback() throws {
        let folder = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("unknown.bin")
        try Data([0x00, 0x11, 0x22, 0x33]).write(to: archive)
        let runner = RecordingProcessRunner()
        let factory = ArchiveEngineFactory(engines: [
            SevenZipEngine(runner: runner, locator: TestSupport.locator)
        ])

        XCTAssertThrowsError(try factory.engine(forArchive: archive)) { error in
            guard case let ArchiveEngineError.unsupportedArchive(filename) = error else {
                return XCTFail("Expected unsupportedArchive, got \(error)")
            }
            XCTAssertEqual(filename, "unknown.bin")
        }
        XCTAssertEqual(runner.invocationCount, 0)
    }
}
