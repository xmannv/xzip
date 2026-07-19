import Cocoa
import Quartz
import XZIPCore

/// Quick Look preview provider: renders an archive's file listing so users can
/// peek inside without extracting (BetterZip-style).
///
/// Design: reuses `XZIPCore` (engine listing + `ArchiveTreeBuilder`) so the
/// preview logic is not duplicated. The extension only turns the tree into a
/// simple HTML document for the Quick Look pane.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let archiveURL = request.fileURL

        // Resolve the bundled 7zz relative to this extension's container app.
        let locator = Self.makeLocator()
        let factory = ArchiveEngineFactory.makeDefault(locator: locator)
        let engine = try factory.engine(forArchive: archiveURL)
        let maxEntries = 5_000
        let maxDepth = 40
        let listing = try await engine.list(
            archive: archiveURL,
            password: nil,
            limit: maxEntries
        )
        let entries = listing.entries.filter {
            $0.path.split(separator: "/").count <= maxDepth
        }
        let countText = QuickLookPreviewPresentation.itemCountText(
            count: listing.entries.count,
            truncated: listing.truncated
        )
        let html = Self.renderHTML(
            tree: ArchiveTreeBuilder.build(from: entries),
            title: archiveURL.lastPathComponent,
            countText: countText,
            truncated: listing.truncated,
            maxDepth: maxDepth
        )

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: 480)) { _ in
            Data(html.utf8)
        }
        return reply
    }

    /// Locate `7zz`: extensions live in `Contents/PlugIns`, so the app's
    /// `Resources/bin` is three levels up from the plugin bundle.
    private static func makeLocator() -> BinaryLocator {
        var dirs: [URL] = []
        let plugin = Bundle.main.bundleURL
        let appResources = plugin
            .deletingLastPathComponent()  // PlugIns
            .deletingLastPathComponent()  // Contents
            .appendingPathComponent("Resources/bin")
        dirs.append(appResources)
        if let res = Bundle.main.resourceURL?.appendingPathComponent("bin") {
            dirs.append(res)
        }
        return BinaryLocator(searchDirectories: dirs)
    }

    private static func renderHTML(
        tree: [ArchiveNode], title: String, countText: String, truncated: Bool, maxDepth: Int
    ) -> String {
        func rows(_ nodes: [ArchiveNode], depth: Int) -> String {
            // Stop descending past the depth cap so a deeply-nested archive can't
            // overflow the extension's small stack via this recursion.
            guard depth < maxDepth else { return "" }
            return nodes.map { node in
                let indent = depth * 18
                let icon = node.isDirectory ? "📁" : "📄"
                let size = node.isDirectory ? "" : ByteCountFormatter.string(
                    fromByteCount: Int64(node.entry?.uncompressedSize ?? 0), countStyle: .file)
                let row = """
                <div class="row" style="padding-left:\(indent)px">
                  <span class="name">\(icon) \(node.name.htmlEscaped)</span>
                  <span class="size">\(size)</span>
                </div>
                """
                return row + (node.isDirectory ? rows(node.children, depth: depth + 1) : "")
            }.joined()
        }

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, sans-serif; margin: 0; padding: 12px;
               color: #222; background: #fff; }
        @media (prefers-color-scheme: dark) { body { color: #eee; background: #1e1e1e; } }
        h1 { font-size: 15px; margin: 0 0 4px; }
        .meta { color: #888; font-size: 11px; margin-bottom: 10px; }
        .row { display: flex; justify-content: space-between; padding: 2px 0;
               border-bottom: 1px solid rgba(128,128,128,0.12); }
        .size { color: #888; font-variant-numeric: tabular-nums; }
        </style></head><body>
        <h1>\(title.htmlEscaped)</h1>
        <div class="meta">\(countText) item\(countText == "1" ? "" : "s")\(truncated ? " · preview truncated" : "")</div>
        \(rows(tree, depth: 0))
        </body></html>
        """
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
