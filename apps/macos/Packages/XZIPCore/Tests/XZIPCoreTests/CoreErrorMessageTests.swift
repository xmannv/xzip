import XCTest
import XZIPCore
import XZIPDomain

/// Both of these enums surface in the app through `error.localizedDescription`,
/// so their wording is user-facing.
final class CoreErrorMessageTests: XCTestCase {
    /// Foundation renders an `Error` without `LocalizedError` as "The operation
    /// couldn't be completed. (Module.Type error N.)". That is what these read as
    /// before the conformance, so it is asserted for every case rather than a
    /// sample.
    private func assertNotPlaceholder(_ error: Error, _ label: String) {
        let message = (error as Error).localizedDescription
        XCTAssertFalse(
            message.contains("couldn’t be completed")
                || message.contains("couldn't be completed"),
            "\(label) still renders as the Foundation placeholder: \(message)"
        )
        XCTAssertFalse(message.isEmpty, "\(label) has an empty message")
    }

    func testNoFilesystemErrorRendersAsThePlaceholder() {
        let errors: [FileSystemOperationError] = [
            .closedDirectoryHandle,
            .invalidComponent("a/b"),
            .invalidAbsoluteDirectoryURL(URL(fileURLWithPath: "/tmp")),
            .symlinkEncountered("link"),
            .notDirectory("file.txt"),
            .unsupportedNode(.symbolicLink),
            .alreadyExists("item.txt"),
            .identityMismatch(
                expected: FileNodeIdentity(
                    device: 1,
                    inode: 2,
                    generation: nil,
                    kind: .regularFile
                ),
                actual: nil
            ),
            .restoreFailed(name: "item.txt"),
            .unsupportedExclusiveRename,
            .posix(function: "renameatx_np", code: 28),
        ]
        for error in errors {
            assertNotPlaceholder(error, String(describing: error))
        }
    }

    /// errno is translated because "No space left on device" tells the user what
    /// to do and "code 28" does not. The syscall name stays for bug reports.
    func testPosixErrorTranslatesErrnoAndKeepsTheSyscall() {
        let message = (FileSystemOperationError.posix(
            function: "renameatx_np",
            code: 28
        ) as Error).localizedDescription
        XCTAssertTrue(
            message.lowercased().contains("no space left"),
            "expected strerror wording, got: \(message)"
        )
        XCTAssertTrue(
            message.contains("renameatx_np"),
            "expected the syscall name, got: \(message)"
        )
        XCTAssertFalse(
            message.contains("28"),
            "the raw errno should not be what the user reads: \(message)"
        )
    }

    func testNoInventoryErrorRendersAsThePlaceholder() {
        let errors: [ExtractionInventoryError] = [
            .invalidPath("../escape"),
            .unsupportedNode(path: "dev", kind: .symbolicLink),
            .symlinkParent("link/child"),
            .nonDirectoryParent("file.txt/child"),
            .destinationCollision(first: "A.txt", second: "a.txt"),
            .entryCountExceeded(limit: 10),
            .pathDepthExceeded(path: "a/b/c", limit: 2),
            .pathByteCountExceeded(path: "long", limit: 3),
            .totalPathByteCountExceeded(limit: 100),
            .advertisedOutputByteCountOverflow,
            .advertisedOutputByteCountExceeded(limit: 1),
            .advertisedDictionaryByteCountExceeded(limit: 1),
        ]
        for error in errors {
            assertNotPlaceholder(error, String(describing: error))
        }
    }

    /// These refusals happen before anything is written, so naming the offending
    /// entry is what lets the user judge the archive.
    func testInventoryMessagesNameTheOffendingEntry() {
        XCTAssertTrue(
            (ExtractionInventoryError.invalidPath("../escape") as Error)
                .localizedDescription.contains("../escape")
        )
        XCTAssertTrue(
            (ExtractionInventoryError.symlinkParent("link/child") as Error)
                .localizedDescription.contains("link/child")
        )
        let collision = (ExtractionInventoryError.destinationCollision(
            first: "A.txt",
            second: "a.txt"
        ) as Error).localizedDescription
        XCTAssertTrue(collision.contains("A.txt") && collision.contains("a.txt"))
    }
}
