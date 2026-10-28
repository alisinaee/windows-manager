import SwiftUI
import WMCore

/// The curated SF Symbols a profile can use as its sidebar icon. The default icon comes first so it can be picked again.
enum ProfileIconChoices {
    static let symbols: [String] = [
        Profile.defaultIcon,
        "house", "briefcase", "laptopcomputer", "desktopcomputer", "gamecontroller", "music.note", "paintbrush",
        "hammer", "wrench.and.screwdriver", "book", "graduationcap", "film", "camera", "photo", "cart", "cup.and.saucer",
        "fork.knife", "moon", "bolt", "star", "heart", "leaf", "pawprint", "globe", "airplane", "car", "bicycle",
        "figure.run", "sportscourt", "building.2", "envelope", "phone", "message", "calendar", "clock", "folder",
        "terminal", "chart.bar", "doc.text", "tv",
    ]
}

/// Local state of the icon picker popover (`@State` is not used in the app target).
@MainActor
final class ProfileIconPickState: ObservableObject {
    @Published var isOpen = false
}

/// A button showing the profile's current icon; it opens a grid of curated symbols. Picking one calls `onPick`.
struct ProfileIconPicker: View {
    /// The icon the profile uses now (SF Symbol name).
    let current: String
    let onPick: (String) -> Void

    @StateObject private var local = ProfileIconPickState()
    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 6)

    var body: some View {
        Button { local.isOpen = true } label: {
            HStack(spacing: 8) {
                Image(systemName: current).frame(width: 22).accessibilityHidden(true)
                Text("Change").font(.callout)
            }
        }
        .help("Choose the icon shown for this profile in the sidebar")
        .accessibilityLabel("Profile icon: \(current). Change")
        .popover(isPresented: $local.isOpen, arrowEdge: .trailing) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ProfileIconChoices.symbols, id: \.self) { symbol in
                        Button {
                            onPick(symbol)
                            local.isOpen = false
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 44, height: 40)
                                .background(symbol == current ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(12)
            }
            .frame(width: 320, height: 300)
        }
    }
}
