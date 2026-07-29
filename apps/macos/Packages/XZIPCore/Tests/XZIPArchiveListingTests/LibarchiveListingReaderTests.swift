import Darwin
import XCTest
import XZIPCore
@testable import XZIPArchiveListing

final class LibarchiveListingReaderTests: XCTestCase {
    func testAListingDoesNotChangeProcessLocale() async throws {
        let originalLocale = String(
            cString: try XCTUnwrap(setlocale(LC_CTYPE, nil))
        )
        defer { setlocale(LC_CTYPE, originalLocale) }
        XCTAssertNotNil(setlocale(LC_CTYPE, "C"))

        let result = try await LibarchiveListingReader().list(
            archive: fixture("sample", extension: "zip"),
            limit: 10
        )

        XCTAssertEqual(String(cString: try XCTUnwrap(setlocale(LC_CTYPE, nil))), "C")
        XCTAssertTrue(result.entries.contains { $0.path == "folder/資料.txt" })
    }

    func testPublicErrorCasesRemainStable() {
        let cases: [QuickLookArchiveListingError] = [
            .unsupportedFormat,
            .encrypted,
            .invalidEntryPath,
            .resourceLimitExceeded,
            .unreadableArchive
        ]
        XCTAssertEqual(cases.count, 5)
    }

    func testListsZip7zTarRar4AndRar5() async throws {
        let cases = [
            ("sample", "zip"),
            ("sample", "7z"),
            ("sample", "tar"),
            ("sample-rar4", "rar"),
            ("sample-rar5", "rar")
        ]
        let reader = LibarchiveListingReader()

        for (name, ext) in cases {
            let result = try await reader.list(
                archive: fixture(name, extension: ext),
                limit: 100
            )
            XCTAssertFalse(result.entries.isEmpty, "Expected entries in \(name).\(ext)")
            XCTAssertFalse(result.truncated)
        }
    }

    func testPAXArchiveWithOversizedUIDAndGIDListsWithoutCrashing() async throws {
        let result = try await LibarchiveListingReader().list(
            archive: fixture("oversized-pax-ids", extension: "tar"),
            limit: 10
        )

        XCTAssertEqual(result.entries.map(\.path), ["oversized-ids.txt"])
        XCTAssertEqual(result.entries.map(\.uncompressedSize), [8])
        XCTAssertFalse(result.truncated)
    }

    func testListsChecksumValidLegacyV7TarWithoutUstar() async throws {
        let result = try await LibarchiveListingReader().list(
            archive: fixture("legacy-v7", extension: "tar"),
            limit: 10
        )

        XCTAssertEqual(result.entries.map(\.path), ["v7-file.txt"])
        XCTAssertEqual(result.entries.map(\.uncompressedSize), [6])
        XCTAssertFalse(result.truncated)
    }

    func testLzipHeaderWithUstarCollisionFailsClosed() async throws {
        await XCTAssertThrowsErrorAsync(
            try await LibarchiveListingReader().list(
                archive: fixture("lzip-ustar-collision", extension: "tar"),
                limit: 10
            )
        ) {
            XCTAssertEqual(
                $0 as? QuickLookArchiveListingError,
                .unsupportedFormat,
                "Received \($0)"
            )
        }
    }

    func testEmptyArchiveReturnsEmptyListing() async throws {
        let result = try await LibarchiveListingReader().list(
            archive: fixture("empty", extension: "7z"),
            limit: 10
        )
        XCTAssertEqual(result, ArchiveListingResult(entries: [], truncated: false))
    }

    func testLimitUsesOneEntryLookahead() async throws {
        let result = try await LibarchiveListingReader().list(
            archive: fixture("sample", extension: "zip"),
            limit: 1
        )
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.truncated, "Entries: \(result.entries.map(\.path))")
    }

    func testUnsupportedFormatFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await XCTAssertThrowsErrorAsync(
            try await LibarchiveListingReader().list(archive: url, limit: 10)
        ) {
            XCTAssertEqual(
                $0 as? QuickLookArchiveListingError,
                .unsupportedFormat,
                "Received \($0)"
            )
        }
    }

    func testDisguisedUnsupportedArchiveFailsClosed() async throws {
        await XCTAssertThrowsErrorAsync(
            try await LibarchiveListingReader().list(
                archive: fixture("disguised-ar", extension: "zip"),
                limit: 10
            )
        ) {
            XCTAssertEqual(
                $0 as? QuickLookArchiveListingError,
                .unsupportedFormat,
                "Received \($0)"
            )
        }
    }

    func testCorruptArchiveMapsToUnreadableArchive() async throws {
        await XCTAssertThrowsErrorAsync(
            try await LibarchiveListingReader().list(
                archive: fixture("corrupt", extension: "zip"),
                limit: 10
            )
        ) {
            XCTAssertEqual(
                $0 as? QuickLookArchiveListingError,
                .unreadableArchive,
                "Received \($0)"
            )
        }
    }

    func testHeaderEncryptedArchiveMapsOnlyPassphraseFailureToEncrypted() async throws {
        await XCTAssertThrowsErrorAsync(
            try await LibarchiveListingReader().list(
                archive: fixture("header-encrypted", extension: "7z"),
                limit: 10
            )
        ) {
            XCTAssertEqual(
                $0 as? QuickLookArchiveListingError,
                .encrypted,
                "Received \($0)"
            )
        }
    }

    func testHeaderEncryptionSignalIsExact() {
        XCTAssertTrue(LibarchiveListingReader.isHeaderEncryptionError(
            code: -1,
            message: "the archive header is encrypted, but currently not supported"
        ))
        XCTAssertFalse(LibarchiveListingReader.isHeaderEncryptionError(
            code: 79,
            message: "truncated zip file header"
        ))
        XCTAssertFalse(LibarchiveListingReader.isHeaderEncryptionError(
            code: -1,
            message: "encrypted archive"
        ))
    }

    func testCancellationRemainsCancellationError() async throws {
        let started = AsyncTestSignal()
        let reader = LibarchiveListingReader(beforeReading: {
            await started.signal()
            try await Task.sleep(for: .seconds(60))
        })
        let archive = try fixture("sample", extension: "zip")
        let task = Task {
            try await reader.list(archive: archive, limit: 100)
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func fixture(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Fixtures"
            )
        )
    }
}

private actor AsyncTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
