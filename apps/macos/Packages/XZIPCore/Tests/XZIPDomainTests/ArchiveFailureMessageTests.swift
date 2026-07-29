import XCTest
import XZIPDomain

/// R4: these errors reach the user through `error.localizedDescription`, so the
/// wording is the product, not an implementation detail.
final class ArchiveFailureMessageTests: XCTestCase {
    private let recoveryURL = URL(fileURLWithPath: "/tmp/xzip-recovery")

    /// The regression that motivated the conformance. Without `LocalizedError`,
    /// Foundation renders any `Error` as "The operation couldn't be completed.
    /// (Module.Type error N.)", which is what the app displayed for every one of
    /// these failures.
    func testNoFailureRendersAsTheFoundationPlaceholder() {
        let failures: [ArchiveFailure] = [
            .archiveChanged,
            .unsupportedFormat,
            .untrustedCommand,
            .replayedCommand,
            .brokerUnavailable,
            .unsupportedProtocolVersion,
            .unresolvedConflictPolicy,
            .unsafePath(entry: "../escape"),
            .unsupportedNode(entry: "dev", type: "block device"),
            .unsupportedEntryName(entry: "a\nb", reason: "line break"),
            .filesystemNameCollision(entries: ["A.txt", "a.txt"]),
            .destinationConflict(path: "out/item.txt"),
            .resourceLimitExceeded(kind: .journalBytes, limit: 1, observed: 2),
            .rollbackFailed(recoveryURL: recoveryURL, cause: nil),
        ]
        for failure in failures {
            let message = (failure as Error).localizedDescription
            XCTAssertFalse(
                message.contains("couldn’t be completed")
                    || message.contains("couldn't be completed"),
                "\(failure) still renders as the Foundation placeholder: \(message)"
            )
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// A full disk is the likely cause of a rollback failing part-way, and the
    /// one the user can act on, so it is named rather than left as an errno.
    func testOutOfSpaceIsNamedInTheMessage() {
        let failure = ArchiveFailure.rollbackFailed(
            recoveryURL: recoveryURL,
            cause: RollbackCause(
                originalDescription: nil,
                rollbackDescription: "No space left on device",
                posixCode: 28
            )
        )
        let message = (failure as Error).localizedDescription
        XCTAssertTrue(
            message.lowercased().contains("out of space"),
            "expected the disk-full wording, got: \(message)"
        )
        XCTAssertTrue(message.contains(recoveryURL.path))
    }

    /// The point of R4: when a rollback fails, the user needs the failure that
    /// started it as well as the one that blocked the cleanup. Reporting only the
    /// second hides what they were actually trying to do.
    func testBothFailuresAppearWhenAnOriginalErrorExists() {
        let failure = ArchiveFailure.rollbackFailed(
            recoveryURL: recoveryURL,
            cause: RollbackCause(
                originalDescription: "This archive needs a password.",
                rollbackDescription: "Permission denied",
                posixCode: 13
            )
        )
        let message = (failure as Error).localizedDescription
        XCTAssertTrue(
            message.contains("Permission denied"),
            "rollback failure missing from: \(message)"
        )
        XCTAssertTrue(
            message.contains("This archive needs a password."),
            "original failure missing from: \(message)"
        )
    }

    /// Absent a cause the message must still say where the leftovers are, since
    /// that is the only thing the user can act on.
    func testMessageWithoutACauseStillLocatesTheLeftovers() {
        let failure = ArchiveFailure.rollbackFailed(
            recoveryURL: recoveryURL,
            cause: nil
        )
        XCTAssertTrue(
            (failure as Error).localizedDescription.contains(recoveryURL.path)
        )
    }

    func testOutOfSpaceIsRecognisedOnlyForENOSPC() {
        func cause(_ code: Int32?) -> RollbackCause {
            RollbackCause(
                originalDescription: nil,
                rollbackDescription: "x",
                posixCode: code
            )
        }
        XCTAssertTrue(cause(28).isOutOfSpace)
        XCTAssertFalse(cause(13).isOutOfSpace)
        XCTAssertFalse(cause(30).isOutOfSpace)
        XCTAssertFalse(cause(nil).isOutOfSpace)
    }
}
