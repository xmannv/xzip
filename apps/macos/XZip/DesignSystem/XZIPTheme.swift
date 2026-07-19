import SwiftUI

enum XZIPMetrics {
    static let sidebarMin: CGFloat = 210
    static let sidebarIdeal: CGFloat = 236
    static let inspectorMin: CGFloat = 290
    static let inspectorIdeal: CGFloat = 320
    static let windowMinWidth: CGFloat = 1040
    static let windowMinHeight: CGFloat = 680
    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 18
    static let heroRadius: CGFloat = 24
}

enum XZIPBrand {
    static let cyan = Color(red: 0.063, green: 0.718, blue: 1.0)
    static let blue = Color(red: 0.086, green: 0.467, blue: 0.949)
    static let indigo = Color(red: 0.255, green: 0.220, blue: 0.784)
    static let violet = Color(red: 0.431, green: 0.333, blue: 0.961)
    static let gradient = LinearGradient(
        colors: [cyan, blue, indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

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

struct XZIPCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: XZIPMetrics.cardRadius, style: .continuous)
                    .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: XZIPMetrics.cardRadius, style: .continuous)
                            .stroke(.separator.opacity(0.55), lineWidth: 1)
                    }
            }
    }
}

struct BrandSymbolView: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(XZIPBrand.gradient)
            Image(systemName: "archivebox.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundStyle(XZIPBrand.blue)
                .padding(size * 0.08)
                .background(.white, in: Circle())
                .offset(y: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct EmptyHero: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var isTargeted: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(XZIPBrand.gradient)
                    .frame(width: 104, height: 104)
                    .shadow(color: XZIPBrand.blue.opacity(0.22), radius: 20, y: 10)
                Image(systemName: symbol)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isTargeted ? 1.04 : 1)

            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isTargeted)
    }
}
