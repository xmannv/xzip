import Foundation

enum QuickLookPreviewPresentation {
    static func itemCountText(count: Int, truncated: Bool) -> String {
        let formatted = count.formatted(
            .number.locale(Locale(identifier: "en_US"))
        )
        return truncated ? "\(formatted)+" : formatted
    }
}
