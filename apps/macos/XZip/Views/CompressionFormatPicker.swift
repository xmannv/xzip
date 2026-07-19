import SwiftUI

/// Compact archive-format picker that progressively reveals less-common TAR codecs.
struct CompressionFormatPicker: View {
    @Binding var selection: CompressionFormat
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = XZIPSpace.xs

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(Self.visibleChoices(isExpanded: isExpanded, selection: selection)) { format in
                Button(format.rawValue) { selection = format }
                    .buttonStyle(.bordered)
                    .tint(selection == format ? XZIPColor.accent : nil)
                    .accessibilityAddTraits(selection == format ? .isSelected : [])
            }

            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                    .frame(minWidth: 16)
            }
            .buttonStyle(.bordered)
            .help(isExpanded ? "Show fewer formats" : "Show more formats")
            .accessibilityLabel(isExpanded ? "Show fewer formats" : "Show more formats")
        }
    }

    static func visibleChoices(
        isExpanded: Bool,
        selection: CompressionFormat
    ) -> [CompressionFormat] {
        if isExpanded { return CompressionFormat.compressChoices }
        if CompressionFormat.advancedChoices.contains(selection) {
            return CompressionFormat.primaryChoices + [selection]
        }
        return CompressionFormat.primaryChoices
    }
}

/// A small dependency-free flow layout for resizable macOS sheets.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for item in result.items {
            item.subview.place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Result {
        let maximumWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var items: [Item] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(Item(subview: subview, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }

        return Result(
            size: CGSize(width: min(usedWidth, maximumWidth), height: y + rowHeight),
            items: items
        )
    }

    private struct Item {
        let subview: LayoutSubview
        let origin: CGPoint
        let size: CGSize
    }

    private struct Result {
        let size: CGSize
        let items: [Item]
    }
}
