import AppKit
import SwiftUI

/// App-wide colour scheme choice. `system` follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// nil means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Persists the chosen appearance (UserDefaults key "appearance") and applies it to every window through NSApp.
@MainActor
final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()
    private static let key = "appearance"

    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        appearance = UserDefaults.standard.string(forKey: Self.key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    func apply() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }
}

/// Toolbar / settings control: an icon button showing the current symbol, with System / Light / Dark inside.
struct AppearanceMenu: View {
    @ObservedObject private var manager = AppearanceManager.shared

    var body: some View {
        Menu {
            Picker("Appearance", selection: $manager.appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: { Label("Appearance", systemImage: manager.appearance.symbol) }
        .menuIndicator(.hidden)
        .help("Appearance")
        .accessibilityLabel("Appearance")
        .accessibilityValue(manager.appearance.label)
    }
}
