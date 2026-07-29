import Foundation
import XCTest
@testable import XZIPDomain

final class ArchiveIdentityTests: XCTestCase {
    func testLocatorURLDoesNotParticipateInArchiveIdentity() {
        let id = ArchiveID(identity: .stable(
            volumeIdentifier: 1,
            fileIdentifier: 2,
            generation: 3
        ))
        var locator = ArchiveLocator(archiveID: id, url: URL(fileURLWithPath: "/a.zip"))
        locator.updateURL(URL(fileURLWithPath: "/renamed.zip"))
        XCTAssertEqual(locator.archiveID, id)
    }

    func testGenerationDistinguishesReusedFileIdentifier() {
        XCTAssertNotEqual(
            ArchiveID(identity: .stable(volumeIdentifier: 1, fileIdentifier: 2, generation: 3)),
            ArchiveID(identity: .stable(volumeIdentifier: 1, fileIdentifier: 2, generation: 4))
        )
    }
}
