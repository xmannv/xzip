import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A file/folder icon drawn from the OS's native icon set (`NSWorkspace`), so
/// entries look exactly like they do in Finder — including app-specific and
/// document icons.
///
/// Resolution order:
///  - `url` present (real on-disk item): use Finder's actual icon for that file.
///  - `isFolder`: the system folder icon.
///  - otherwise: the generic icon for the file's UTType, derived from `ext`
///    (archive entries have no on-disk URL, so this is the best we can do).
struct NativeFileIcon: View {
    var url: URL? = nil
    var ext: String = ""
    var isFolder: Bool = false
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: Self.resolve(url: url, ext: ext, isFolder: isFolder))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func resolve(url: URL?, ext: String, isFolder: Bool) -> NSImage {
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if isFolder {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
