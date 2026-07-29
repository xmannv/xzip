import Cocoa
import os
import Quartz
import XZIPArchiveListing
import XZIPCore

/// Quick Look preview provider: renders an archive's file listing so users can
/// peek inside without extracting (BetterZip-style).
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let logger = Logger(subsystem: "com.codetay.xzip.QuickLook", category: "preview")

    private let reader: any ArchiveListingReading

    override init() {
        self.reader = LibarchiveListingReader()
        super.init()
    }

    init(reader: any ArchiveListingReading) {
        self.reader = reader
        super.init()
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        Self.logger.notice("providePreview entered")

        do {
            let html = try await html(for: request.fileURL)
            let reply = QLPreviewReply(
                dataOfContentType: .html,
                contentSize: CGSize(width: 640, height: 480)
            ) { _ in
                Data(html.utf8)
            }
            Self.logger.notice("providePreview produced reply")
            return reply
        } catch {
            Self.logger.error(
                "providePreview failed: \(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    func html(for archiveURL: URL) async throws -> String {
        do {
            let maxEntries = 5_000
            let maxDepth = 40
            let listing = try await reader.list(archive: archiveURL, limit: maxEntries)
            let entries = listing.entries.filter {
                $0.path.split(separator: "/").count <= maxDepth
            }
            let countText = QuickLookPreviewPresentation.itemCountText(
                count: listing.entries.count,
                truncated: listing.truncated
            )
            return QuickLookPreviewPresentation.listingHTML(
                tree: ArchiveTreeBuilder.build(from: entries),
                title: archiveURL.lastPathComponent,
                countText: countText,
                truncated: listing.truncated,
                maxDepth: maxDepth
            )
        } catch QuickLookArchiveListingError.encrypted {
            return QuickLookPreviewPresentation.encryptedHTML(
                title: archiveURL.lastPathComponent
            )
        }
    }
}
