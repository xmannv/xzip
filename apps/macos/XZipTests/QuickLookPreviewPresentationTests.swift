import XCTest
import XZIPArchiveListing
import XZIPCore
@testable import XZip

final class QuickLookPreviewPresentationTests: XCTestCase {
    func testEncryptedHTMLOmitsDuplicateArchiveTitle() {
        let html = QuickLookPreviewPresentation.encryptedHTML(
            title: "private<&>.7z"
        )
        XCTAssertTrue(html.contains("Encrypted archive — contents require a password"))
        XCTAssertFalse(html.contains("private&lt;&amp;&gt;.7z"))
        XCTAssertFalse(html.contains("private<&>.7z"))
    }

    func testListingHTMLEscapesEntryNames() {
        let entry = ArchiveEntry(
            path: "unsafe<&>.txt",
            uncompressedSize: 1,
            compressedSize: 0,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )
        let html = QuickLookPreviewPresentation.listingHTML(
            tree: ArchiveTreeBuilder.build(from: [entry]),
            title: "archive.zip",
            countText: "1",
            truncated: false,
            maxDepth: 40
        )
        XCTAssertTrue(html.contains("unsafe&lt;&amp;&gt;.txt"))
        XCTAssertFalse(html.contains("unsafe<&>.txt"))
    }

    func testListingHTMLUsesBottomStatusBarWithoutDuplicateArchiveTitle() {
        let entry = ArchiveEntry(
            path: "document.txt",
            uncompressedSize: 1,
            compressedSize: 0,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )
        let html = QuickLookPreviewPresentation.listingHTML(
            tree: ArchiveTreeBuilder.build(from: [entry]),
            title: "archive.zip",
            countText: "1",
            truncated: false,
            maxDepth: 40
        )

        XCTAssertFalse(html.contains("<h1>archive.zip</h1>"))
        XCTAssertFalse(html.contains("class=\"meta\""))
        XCTAssertTrue(html.contains("<footer class=\"status\">1 item</footer>"))
        XCTAssertTrue(html.contains("position: fixed"))
        XCTAssertGreaterThan(
            html.range(of: "<footer class=\"status\">")!.lowerBound,
            html.range(of: "document.txt")!.lowerBound
        )
    }

    func testListingHTMLUsesNativeIconsInsteadOfEmoji() {
        let entries = [
            ArchiveEntry(
                path: "folder/",
                uncompressedSize: 0,
                compressedSize: 0,
                modificationDate: nil,
                isDirectory: true,
                isEncrypted: false
            ),
            ArchiveEntry(
                path: "document.txt",
                uncompressedSize: 1,
                compressedSize: 0,
                modificationDate: nil,
                isDirectory: false,
                isEncrypted: false
            )
        ]
        let html = QuickLookPreviewPresentation.listingHTML(
            tree: ArchiveTreeBuilder.build(from: entries),
            title: "archive.zip",
            countText: "2",
            truncated: false,
            maxDepth: 40
        )

        XCTAssertTrue(html.contains("background-image: url(\"data:image/png;base64,"))
        XCTAssertTrue(html.contains("class=\"icon icon-"))
        XCTAssertFalse(html.contains("📁"))
        XCTAssertFalse(html.contains("📄"))
    }

    func testListingHTMLCapsEmbeddedIconVariants() {
        let entries = (0..<65).map { index in
            ArchiveEntry(
                path: "file.variation\(index)",
                uncompressedSize: 1,
                compressedSize: 0,
                modificationDate: nil,
                isDirectory: false,
                isEncrypted: false
            )
        }
        let html = QuickLookPreviewPresentation.listingHTML(
            tree: ArchiveTreeBuilder.build(from: entries),
            title: "archive.zip",
            countText: "65",
            truncated: false,
            maxDepth: 40
        )

        XCTAssertEqual(
            html.components(separatedBy: "background-image: url(").count - 1,
            64
        )
    }

    func testListingHTMLStopsAtDepthCap() {
        let entry = ArchiveEntry(
            path: "one/two/three.txt",
            uncompressedSize: 1,
            compressedSize: 0,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )
        let html = QuickLookPreviewPresentation.listingHTML(
            tree: ArchiveTreeBuilder.build(from: [entry]),
            title: "archive.zip",
            countText: "1",
            truncated: false,
            maxDepth: 2
        )
        XCTAssertFalse(html.contains("three.txt"))
    }

    func testTruncatedCountUsesPlusSuffix() {
        XCTAssertEqual(
            QuickLookPreviewPresentation.itemCountText(count: 5_000, truncated: true),
            "5,000+"
        )
    }

    func testCompleteCountIsExact() {
        XCTAssertEqual(
            QuickLookPreviewPresentation.itemCountText(count: 42, truncated: false),
            "42"
        )
    }

    func testByteCountTextClampsUInt64Max() {
        XCTAssertEqual(
            QuickLookPreviewPresentation.byteCountText(UInt64.max),
            ByteCountFormatter.string(fromByteCount: Int64.max, countStyle: .file)
        )
    }

    func testProviderUsesInjectedReaderAndRendersTruncatedCount() async throws {
        let entries = [ArchiveEntry(
            path: "inside.txt",
            uncompressedSize: 7,
            compressedSize: 0,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false
        )]
        let reader = StubArchiveListingReader(
            result: .success(.init(entries: entries, truncated: true))
        )
        let provider = PreviewProvider(reader: reader)

        let html = try await provider.html(
            for: URL(fileURLWithPath: "/tmp/archive.zip")
        )

        let receivedLimit = await reader.receivedLimit
        XCTAssertEqual(receivedLimit, 5_000)
        XCTAssertTrue(html.contains("inside.txt"))
        XCTAssertTrue(html.contains("1+ items · preview truncated"))
    }

    func testProviderRendersLockedStateForEncryptedError() async throws {
        let provider = PreviewProvider(reader: StubArchiveListingReader(
            result: .failure(QuickLookArchiveListingError.encrypted)
        ))

        let html = try await provider.html(
            for: URL(fileURLWithPath: "/tmp/private.7z")
        )

        XCTAssertTrue(html.contains("Encrypted archive — contents require a password"))
    }

    func testProviderPropagatesUnreadableArchive() async {
        let provider = PreviewProvider(reader: StubArchiveListingReader(
            result: .failure(QuickLookArchiveListingError.unreadableArchive)
        ))

        do {
            _ = try await provider.html(
                for: URL(fileURLWithPath: "/tmp/bad.zip")
            )
            XCTFail("Expected unreadable archive error")
        } catch {
            XCTAssertEqual(
                error as? QuickLookArchiveListingError,
                .unreadableArchive
            )
        }
    }
}

private actor StubArchiveListingReader: ArchiveListingReading {
    let result: Result<ArchiveListingResult, QuickLookArchiveListingError>
    private(set) var receivedLimit: Int?

    init(result: Result<ArchiveListingResult, QuickLookArchiveListingError>) {
        self.result = result
    }

    func list(archive: URL, limit: Int) async throws -> ArchiveListingResult {
        receivedLimit = limit
        return try result.get()
    }
}
