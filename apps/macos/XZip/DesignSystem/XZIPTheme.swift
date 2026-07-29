import SwiftUI

/// Semantic design tokens from the "macOS Compression App Design" spec (§3).
///
/// Design: prefer system semantic colors so dark mode + accent tint follow the
/// OS automatically; the fixed hex values here match the mockup exactly for the
/// few accent roles that must stay constant across appearances.
enum XZIPColor {
    // Accent follows the user's system accent color (System Settings →
    // Appearance → Accent), so the app matches macOS instead of forcing blue.
    // Status colors stay fixed per the spec table.
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.227)    // #FF453A

    // Surfaces — map to system semantic colors (auto dark mode).
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let contentBackground = Color(nsColor: .textBackgroundColor)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
}

/// Spacing scale (4/8/12/16) + radii from spec §3.
enum XZIPSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let rowVertical: CGFloat = 6
    static let rowHorizontal: CGFloat = 16
    static let sheetPadding: CGFloat = 22
}

enum XZIPRadius {
    static let capsule: CGFloat = 999
    static let card: CGFloat = 10
    static let sheet: CGFloat = 14
    static let popover: CGFloat = 12
}
