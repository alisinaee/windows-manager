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

/// Semantic meaning of a message or status, mapped to system colors and symbols.
enum Tone {
    case info, success, warning, danger, neutral

    var color: Color {
        switch self {
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .danger: .red
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
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}
