import Foundation
import XCTest
@testable import XZIPDomain

final class ArchiveFailureTests: XCTestCase {
    func testArchiveFailureOwnsSessionAndClosureCasesBeforeDownstreamPlans() {
        let sessionID = ArchiveSessionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        )
        let operationID = OperationID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        )

        XCTAssertEqual(
            ArchiveFailure.authenticationRequired(
                sessionID: sessionID,
                operationID: operationID
            ),
            .authenticationRequired(sessionID: sessionID, operationID: operationID)
        )
        XCTAssertEqual(
            ArchiveFailure.stalePasswordRequest(operationID: operationID),
            .stalePasswordRequest(operationID: operationID)
        )
        XCTAssertEqual(ArchiveFailure.unsupportedFormat, .unsupportedFormat)
    }
}
