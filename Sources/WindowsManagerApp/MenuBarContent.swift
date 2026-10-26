import SwiftUI

/// Placeholder menu shown from the menu bar item. Real profile rows arrive in P2.9.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Windows Manager")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            Divider().padding(.vertical, 2)

            accessibilityRow

            Divider().padding(.vertical, 2)

            MenuRow(title: "Profiles will appear here") {}
                .disabled(true)

            Divider().padding(.vertical, 2)

            MenuRow(title: "Setup…") {
                OnboardingWindowController.shared.show()
            }
            MenuRow(title: "Settings…") {
                NSApp.activate()
                openSettings()
            }
            MenuRow(title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 280)
        .onAppear { appState.refreshPermissions() }
    }

    private var accessibilityRow: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(appState.isAccessibilityTrusted ? Color.green : Color.orange)
            Text(appState.isAccessibilityTrusted ? "Accessibility: allowed" : "Accessibility: not allowed")
            Spacer(minLength: 8)
            Button("Grant…") { appState.requestAccessibility() }
                .disabled(appState.isAccessibilityTrusted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// A full-width menu style row (the .window style does not draw native menu items).
/// The highlight follows the press, not the hover: `@State` is a macro in the macOS 27 SDK and its
/// plugin (SwiftUIMacros) ships only with Xcode, so this target avoids it to build with the Command Line Tools.
private struct MenuRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed && isEnabled ? Color.accentColor.opacity(0.3) : Color.clear)
            )
    }
}
