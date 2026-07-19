import SwiftUI
import AppKit

/// One segment of a breadcrumb trail.
struct BreadcrumbItem: Identifiable {
    /// Position in the trail (0 = root). Also drives the leading chevron.
    let id: Int
    let label: String
    let isCurrent: Bool
    /// String copied by the "Copy Path" context menu, or `nil` for no menu
    /// (e.g. the archive-file crumb, which has no meaningful path here).
    let copyValue: String?
    /// Navigate to this crumb. Ignored for the current crumb.
    let navigate: () -> Void
}

/// A shared, clickable breadcrumb trail rendered as `A › B › C`.
///
/// Both the in-archive path bar (`PathBarView`) and the on-disk Places browser
/// (`FolderBrowserView`) render their trail through this component so the look
/// and behaviour — click-to-navigate, current-crumb styling, and the Copy Path
/// context menu — stay identical. The two callers differ only in how they map
/// their own data (virtual archive paths vs. filesystem URLs) into
/// `[BreadcrumbItem]`; the display data and interactions are the same, which is
/// why they share one view instead of duplicating the trail logic.
struct BreadcrumbTrail: View {
    let items: [BreadcrumbItem]
    /// Callers size the text to their container (the path bar uses `.callout`,
    /// the folder browser's toolbar uses `.headline`).
    var font: Font = .callout

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: XZIPSpace.xs) {
                ForEach(items) { item in
                    if item.id > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    crumbButton(item)
                }
            }
        }
    }

    private func crumbButton(_ item: BreadcrumbItem) -> some View {
        Button {
            // Guard instead of `.disabled` so the current crumb still shows its
            // context menu (disabled controls swallow right-clicks).
            guard !item.isCurrent else { return }
            item.navigate()
        } label: {
            Text(item.label)
                .font(font)
                .fontWeight(item.isCurrent ? .semibold : .regular)
                .foregroundStyle(item.isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(item.isCurrent ? "Current folder" : "Go to \(item.label)")
        .modifier(CrumbContextMenu(copyValue: item.copyValue))
    }
}

/// Attaches the "Copy Path" menu only to crumbs that carry a path. Crumbs
/// without a `copyValue` (e.g. the archive-file root) get no context menu.
private struct CrumbContextMenu: ViewModifier {
    let copyValue: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value = copyValue {
            content.contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
        } else {
            content
        }
    }
}
