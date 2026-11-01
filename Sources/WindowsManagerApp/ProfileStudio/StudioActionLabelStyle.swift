import SwiftUI

/// Title and icon, or the icon alone when the row is short of room (the button keeps its help text).
struct StudioActionLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: Spacing.xs) { configuration.icon; configuration.title }
        }
    }
}
