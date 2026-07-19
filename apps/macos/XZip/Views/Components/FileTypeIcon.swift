import SwiftUI

/// The signature file-type badge from the design spec: a rounded square filled
/// with a type-specific color and a white uppercase extension label.
///
/// Design: a single reusable component so every list row, queue row, and sheet
/// renders identical badges. Color + label are derived from the file extension
/// via `FileTypeStyle`, matching the spec's palette exactly (§3).
struct FileTypeIcon: View {
    let ext: String
    /// Folders render a native folder glyph instead of a "DIR" badge — clearer
    /// at a glance and matches Finder's mental model.
    var isFolder: Bool = false
    var size: CGFloat = 20

    private var style: FileTypeStyle { FileTypeStyle.forExtension(ext) }

    // Radius + label scale with size per spec: 20→5, 26→7, 44→11.
    private var cornerRadius: CGFloat { size * 0.25 }
    private var labelSize: CGFloat { max(6.5, size * 0.32) }

    var body: some View {
        if isFolder {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.82))
                .foregroundStyle(XZIPColor.accent)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style.color)
                .frame(width: size, height: size)
                .overlay {
                    Text(style.label)
                        .font(.system(size: labelSize, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 1)
                }
                .accessibilityHidden(true)
        }
    }
}

/// Maps a file extension to its badge color + short label, per spec palette.
struct FileTypeStyle {
    let color: Color
    let label: String

    static func forExtension(_ rawExt: String) -> FileTypeStyle {
        let ext = rawExt.lowercased()
        switch ext {
        case "", "dir", "folder":
            return .init(color: XZIPColor.accent, label: "DIR")
        case "zip":
            return .init(color: XZIPColor.accent, label: "ZIP")
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp":
            return .init(color: XZIPColor.success, label: shortLabel(ext))
        case "pdf":
            return .init(color: XZIPColor.danger, label: "PDF")
        case "7z", "sketch", "sk":
            return .init(color: XZIPColor.warning, label: ext == "7z" ? "7Z" : "SK")
        case "rar", "mp4", "mov", "m4v", "avi", "mkv":
            return .init(color: Color(red: 0.686, green: 0.322, blue: 0.871), label: shortLabel(ext)) // #AF52DE
        case "ttf", "otf", "woff", "woff2":
            return .init(color: Color(red: 0.369, green: 0.361, blue: 0.902), label: "TTF") // #5E5CE6
        case "txt", "md", "rtf", "log":
            return .init(color: Color(red: 0.557, green: 0.557, blue: 0.576), label: shortLabel(ext)) // #8E8E93
        default:
            return .init(color: Color(red: 0.557, green: 0.557, blue: 0.576), label: shortLabel(ext))
        }
    }

    /// Uppercased extension, capped to 3 chars for the badge.
    private static func shortLabel(_ ext: String) -> String {
        ext.isEmpty ? "FILE" : String(ext.prefix(3)).uppercased()
    }
}

#Preview {
    HStack(spacing: 12) {
        FileTypeIcon(ext: "zip", size: 44)
        FileTypeIcon(ext: "pdf", size: 26)
        FileTypeIcon(ext: "png")
        FileTypeIcon(ext: "7z")
        FileTypeIcon(ext: "rar")
        FileTypeIcon(ext: "ttf")
        FileTypeIcon(ext: "", size: 26)
    }
    .padding()
}
