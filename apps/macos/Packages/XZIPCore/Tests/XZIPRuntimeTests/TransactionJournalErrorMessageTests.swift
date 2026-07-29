import XCTest
import XZIPDomain
@testable import XZIPRuntime

/// `unavailableDestinationVolume` is what an extraction to a USB stick or other
/// external volume fails with today, and it reaches the user through the app's
/// `error.localizedDescription`.
final class TransactionJournalErrorMessageTests: XCTestCase {
    func testNoCaseRendersAsTheFoundationPlaceholder() {
        let errors: [TransactionJournalError] = [
            .unavailableDestinationVolume(42),
            .invalidManifest("bad"),
            .capacityExceeded(limit: 4, observed: 5),
            .duplicateTransaction,
            .invalidTransition,
            .malformedIndex,
            .malformedJournal,
            .missingTransaction,
            .unsafeRecoveryState("staging inventory remains"),
            .committedOutcomeUnavailable(operationID: OperationID()),
            .committedOutcomeMismatch,
            .commitStateUncertain(recoveryURL: URL(fileURLWithPath: "/tmp/r")),
        ]
        for error in errors {
            let message = (error as Error).localizedDescription
            XCTAssertFalse(
                message.contains("couldn’t be completed")
                    || message.contains("couldn't be completed"),
                "\(error) still renders as the Foundation placeholder: \(message)"
            )
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// The message a user sees when they extract to an external drive. It has to
    /// say what to do instead, because the operation cannot succeed as asked.
    func testCrossVolumeMessageExplainsTheLimitAndAWayForward() {
        let message = (TransactionJournalError
            .unavailableDestinationVolume(42) as Error).localizedDescription
        XCTAssertTrue(
            message.lowercased().contains("disk"),
            "expected the message to name the problem, got: \(message)"
        )
        XCTAssertFalse(
            message.contains("42"),
            "the device number is a diagnostic, not something to show: \(message)"
        )
    }

    /// A path is the only actionable part of these two, so it must survive.
    func testRecoveryPathsAppearInTheirMessages() {
        let recoveryURL = URL(fileURLWithPath: "/tmp/xzip-recovery")
        XCTAssertTrue(
            (TransactionJournalError.commitStateUncertain(
                recoveryURL: recoveryURL
            ) as Error).localizedDescription.contains(recoveryURL.path)
        )
        XCTAssertTrue(
            (TransactionJournalError.unsafeRecoveryState(
                "staging inventory remains"
            ) as Error).localizedDescription.contains("staging inventory remains")
        )
    }
}
