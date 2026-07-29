import AppKit
import Foundation
import UniformTypeIdentifiers
import XZIPCore

enum QuickLookPreviewPresentation {
    static func itemCountText(count: Int, truncated: Bool) -> String {
        let formatted = count.formatted(
            .number.locale(Locale(identifier: "en_US"))
        )
        return truncated ? "\(formatted)+" : formatted
    }

    static func byteCountText(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .file
        )
    }

    static func listingHTML(
        tree: [ArchiveNode], title _: String, countText: String, truncated: Bool, maxDepth: Int
    ) -> String {
        let maxIconVariants = 64
        var iconClasses: [String: String] = [:]
        var iconRules: [String] = []

        func registerIcon(for key: String) -> String {
            if let existing = iconClasses[key] { return existing }

            let className = "icon-\(iconClasses.count)"
            iconClasses[key] = className
            if let dataURL = nativeIconDataURL(
                filenameExtension: key == "folder" ? "" : String(key.dropFirst(5)),
                isDirectory: key == "folder"
            ) {
                iconRules.append(".\(className) { background-image: url(\"\(dataURL)\"); }")
            }
            return className
        }

        let folderIconClass = registerIcon(for: "folder")
        let genericFileIconClass = registerIcon(for: "file:")

        func iconClass(for node: ArchiveNode) -> String {
            if node.isDirectory { return folderIconClass }

            let requestedKey = "file:\((node.name as NSString).pathExtension.lowercased())"
            if let existing = iconClasses[requestedKey] { return existing }
            guard iconClasses.count < maxIconVariants else { return genericFileIconClass }
            return registerIcon(for: requestedKey)
        }

        func rows(_ nodes: [ArchiveNode], depth: Int) -> String {
            // Stop descending past the depth cap so a deeply-nested archive can't
            // overflow the extension's small stack via this recursion.
            guard depth < maxDepth else { return "" }
            return nodes.map { node in
                let indent = depth * 18
                let size = node.isDirectory ? "" : byteCountText(
                    node.entry?.uncompressedSize ?? 0
                )
                let row = """
                <div class="row" style="padding-left:\(indent)px">
                  <span class="name"><span class="icon \(iconClass(for: node))" aria-hidden="true"></span>\(node.name.htmlEscaped)</span>
                  <span class="size">\(size)</span>
                </div>
                """
                return row + (node.isDirectory ? rows(node.children, depth: depth + 1) : "")
            }.joined()
        }

        let renderedRows = rows(tree, depth: 0)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, sans-serif; margin: 0; padding: 12px 12px 42px;
               color: #222; background: #fff; }
        @media (prefers-color-scheme: dark) {
          body { color: #eee; background: #1e1e1e; }
          .status { background: rgba(30,30,30,0.88); }
        }
        .row { display: flex; justify-content: space-between; align-items: center; padding: 2px 0;
               border-bottom: 1px solid rgba(128,128,128,0.12); }
        .name { display: flex; align-items: center; min-width: 0; }
        .icon { width: 20px; height: 20px; margin-right: 6px; flex: 0 0 auto;
                background-position: center; background-repeat: no-repeat; background-size: contain; }
        .size { color: #888; font-variant-numeric: tabular-nums; }
        .status { position: fixed; left: 0; right: 0; bottom: 0; box-sizing: border-box;
                  padding: 7px 12px; color: #888; font-size: 11px;
                  background: rgba(255,255,255,0.88); border-top: 1px solid rgba(128,128,128,0.2);
                  backdrop-filter: blur(12px); }
        \(iconRules.joined(separator: "\n"))
        </style></head><body>
        \(renderedRows)
        <footer class="status">\(countText) item\(countText == "1" ? "" : "s")\(truncated ? " · preview truncated" : "")</footer>
        </body></html>
        """
    }

    private static func nativeIconDataURL(
        filenameExtension: String,
        isDirectory: Bool
    ) -> String? {
        let image: NSImage
        if isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let type = UTType(filenameExtension: filenameExtension) ?? .data
            image = NSWorkspace.shared.icon(for: type)
        }

        var proposedRect = NSRect(x: 0, y: 0, width: 32, height: 32)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    static func encryptedHTML(title _: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, sans-serif; margin: 0; padding: 24px;
               color: #222; background: #fff; }
        @media (prefers-color-scheme: dark) { body { color: #eee; background: #1e1e1e; } }
        .locked { color: #888; }
        </style></head><body>
        <div class="locked">Encrypted archive — contents require a password</div>
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
