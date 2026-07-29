import Darwin
import XCTest
@testable import XZIPCore

final class AtomicDestinationInstallerTests: XCTestCase {
    func testRenameFlagsRemainCompatibleWithPreMacOS26SDKs() {
        XCTAssertEqual(
            AtomicDestinationInstaller.renameFlags(
                resolveBeneathAvailable: false
            ),
            UInt32(RENAME_EXCL)
        )
        XCTAssertEqual(
            AtomicDestinationInstaller.renameFlags(
                resolveBeneathAvailable: true
            ),
            UInt32(RENAME_EXCL) | 0x20
        )
    }

    func testPublicationNamesRejectTraversalComponents() {
        XCTAssertFalse(AtomicDestinationInstaller.isValidName("."))
        XCTAssertFalse(AtomicDestinationInstaller.isValidName(".."))
        XCTAssertFalse(AtomicDestinationInstaller.isValidName("a/b"))
        XCTAssertTrue(AtomicDestinationInstaller.isValidName("file.txt"))
    }
}
