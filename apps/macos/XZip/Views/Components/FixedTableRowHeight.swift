import AppKit
import SwiftUI

/// Applies a fixed AppKit row height to the SwiftUI table under this marker.
/// This avoids AppKit's automatic row-height cache re-entering its delegate
/// while SwiftUI inserts a large folder listing.
struct FixedTableRowHeight: NSViewRepresentable {
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> ResolverView {
        ResolverView(rowHeight: rowHeight)
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.rowHeight = rowHeight
        nsView.resolve()
    }

    @MainActor
    static func configure(_ tableView: NSTableView, rowHeight: CGFloat) {
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = rowHeight
    }

    @MainActor
    static func matchingTableView(in contentView: NSView, at pointInWindow: NSPoint) -> NSTableView? {
        contentView.descendantTableViews
            .filter { tableView in
                let host = tableView.enclosingScrollView ?? tableView
                return host.convert(host.bounds, to: nil).contains(pointInWindow)
            }
            .min { lhs, rhs in
                let lhsHost = lhs.enclosingScrollView ?? lhs
                let rhsHost = rhs.enclosingScrollView ?? rhs
                return lhsHost.bounds.width * lhsHost.bounds.height
                    < rhsHost.bounds.width * rhsHost.bounds.height
            }
    }

    @MainActor
    final class ResolverView: NSView {
        var rowHeight: CGFloat
        private weak var configuredTableView: NSTableView?
        private var resolutionScheduled = false

        init(rowHeight: CGFloat) {
            self.rowHeight = rowHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            if let configuredTableView {
                FixedTableRowHeight.configure(configuredTableView, rowHeight: rowHeight)
                return
            }
            guard !resolutionScheduled else { return }
            resolutionScheduled = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.resolutionScheduled = false
                self.configureMatchingTable()
            }
        }

        private func configureMatchingTable() {
            guard let contentView = window?.contentView else { return }
            let markerCenter = NSPoint(x: bounds.midX, y: bounds.midY)
            let centerInWindow = convert(markerCenter, to: nil)
            guard let tableView = FixedTableRowHeight.matchingTableView(
                in: contentView,
                at: centerInWindow
            ) else { return }
            FixedTableRowHeight.configure(tableView, rowHeight: rowHeight)
            configuredTableView = tableView
        }
    }
}

private extension NSView {
    var descendantTableViews: [NSTableView] {
        subviews.flatMap { view in
            (view as? NSTableView).map { [$0] } ?? view.descendantTableViews
        }
    }
}
