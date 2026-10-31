import SwiftUI

// Shared design tokens: spacing, radii, semantic tones, text roles and a few
// small reusable components. Stateless on purpose (no @State).

/// Spacing scale in points.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Corner radius scale in points.
enum Radius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    /// Radius used by `wmCard()`.
    static let card: CGFloat = large
}

/// Indigo + teal palette. Each colour adapts to light and dark appearance; use these instead of literals.
enum Palette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }

    static let accent = dynamic(light: 0x5B6CFF, dark: 0x8290FF)
    static let teal = dynamic(light: 0x1FBFA3, dark: 0x3DDCBF)
    static let warn = dynamic(light: 0xF5A524, dark: 0xF5A524)
    static let danger = dynamic(light: 0xF2557A, dark: 0xFF7A99)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x161821)
    static let canvas = dynamic(light: 0xF3F4F9, dark: 0x0D0E14)
    /// Soft accent wash for selected rows and toggled-on tools.
    static var accentWash: Color { accent.opacity(0.16) }
}

/// Shared springs. Short and slightly bouncy; `Animation.wm(_:)` still returns nil for Reduce Motion.
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let smooth = Animation.smooth(duration: 0.3)
    static let quick = Animation.snappy(duration: 0.2)
}

/// Semantic meaning of a message or status, mapped to system colors and symbols.
enum Tone {
    case info, success, warning, danger, neutral

    var color: Color {
        switch self {
        case .info: Palette.accent
        case .success: Palette.teal
        case .warning: Palette.warn
        case .danger: Palette.danger
        case .neutral: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .neutral: "circle.fill"
        }
    }

    /// Soft background tint for banners and badges.
    var fill: Color { color.opacity(0.12) }
}

/// Text roles built on system text styles so they scale with Dynamic Type.
extension Font {
    static let wmTitle = Font.title3.weight(.semibold)
    static let wmSection = Font.headline
    static let wmBody = Font.body
    static let wmCaption = Font.caption
    static let wmMonoCaption = Font.caption.monospaced()
}

/// Inline message with a tone, optional detail, optional action and dismiss.
struct Banner: View {
    let tone: Tone
    let title: String
    var message: String?
    var actionLabel: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: tone.symbol)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(.wmSection)
                    if let message {
                        Text(message).font(.wmCaption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(Spacing.m)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: Radius.medium))
    }
}

/// Small capsule label showing a status.
struct StatusBadge: View {
    let tone: Tone
    let text: String

    var body: some View {
        Text(text)
            .font(.wmCaption.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(tone.fill, in: Capsule())
    }
}

extension View {
    /// Padded rounded secondary-background container.
    func wmCard() -> some View {
        padding(Spacing.m)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

extension Animation {
    /// Returns `nil` (no animation) when Reduce Motion is on.
    /// Pass `@Environment(\.accessibilityReduceMotion)`.
    static func wm(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Motion.smooth
    }
}
