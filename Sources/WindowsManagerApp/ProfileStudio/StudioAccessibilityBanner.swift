import SwiftUI

/// Full-width warning at the top of the detail column while Accessibility access is missing. Dismissible per session.
struct StudioAccessibilityBanner: View {
    @ObservedObject var app: AppState
    @Binding var isDismissed: Bool

    var body: some View {
        if !app.isAccessibilityTrusted, !isDismissed {
            Banner(tone: .warning, title: "Accessibility access is needed",
                   message: "Without it Windows Manager cannot capture, compare or restore windows.",
                   actionLabel: "Open System Settings", action: { app.requestAccessibility() },
                   onDismiss: { isDismissed = true })
                .padding(Spacing.s)
        }
    }
}
