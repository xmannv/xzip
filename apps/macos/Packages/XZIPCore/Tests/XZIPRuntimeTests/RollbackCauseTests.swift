import XCTest
import XZIPCore
import XZIPDomain
@testable import XZIPRuntime

/// R4: recovering the `errno` is what makes the disk-full wording possible. If
/// this returned nil the message would silently fall back to the generic form and
/// nothing else would fail, so it is asserted directly.
final class RollbackCauseTests: XCTestCase {
    func testErrnoIsRecoveredFromFileSystemOperationError() {
        let cause = RollbackCause(
            original: nil,
            rollback: FileSystemOperationError.posix(function: "renameatx_np", code: 28)
        )
        XCTAssertEqual(cause.posixCode, 28)
        XCTAssertTrue(cause.isOutOfSpace)
        XCTAssertTrue(
            cause.rollbackDescription.contains("renameatx_np"),
            "the failing syscall should be named: \(cause.rollbackDescription)"
        )
    }

    /// The other shape this codebase throws: raw syscall paths wrap errno in an
    /// NSError rather than FileSystemOperationError.
    func testErrnoIsRecoveredFromPOSIXNSError() {
        let cause = RollbackCause(
            original: nil,
            rollback: NSError(domain: NSPOSIXErrorDomain, code: 28)
        )
        XCTAssertEqual(cause.posixCode, 28)
        XCTAssertTrue(cause.isOutOfSpace)
    }

    func testNonPOSIXErrorsReportNoErrno() {
        let cause = RollbackCause(
            original: nil,
            rollback: TransactionJournalError.unsafeRecoveryState("staging inventory remains")
        )
        XCTAssertNil(cause.posixCode)
        XCTAssertFalse(cause.isOutOfSpace)
        XCTAssertFalse(cause.rollbackDescription.isEmpty)
    }

    /// Enum errors without LocalizedError would render as "error 3" via
    /// localizedDescription, so the description falls back to reflection, which
    /// keeps the payload readable.
    func testEnumErrorDescriptionKeepsItsPayload() {
        let cause = RollbackCause(
            original: nil,
            rollback: TransactionJournalError.unsafeRecoveryState("staging inventory remains")
        )
        XCTAssertTrue(
            cause.rollbackDescription.contains("staging inventory remains"),
            "lost the payload: \(cause.rollbackDescription)"
        )
    }

    func testOriginalErrorIsCarriedAlongside() {
        let cause = RollbackCause(
            original: ArchiveFailure.archiveChanged,
            rollback: FileSystemOperationError.posix(function: "unlinkat", code: 13)
        )
        XCTAssertEqual(cause.posixCode, 13)
        XCTAssertFalse(cause.isOutOfSpace)
        XCTAssertNotNil(cause.originalDescription)
        XCTAssertTrue(
            cause.originalDescription?.contains("changed on disk") == true,
            "expected the original failure's own wording, got: "
                + String(describing: cause.originalDescription)
        )
    }
}
