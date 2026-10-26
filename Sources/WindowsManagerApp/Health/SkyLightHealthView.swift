import SwiftUI
import WMCore

/// Holds the latest SkyLight health check. The probe runs on a background task, never on the main thread.
@MainActor
final class SkyLightHealthModel: ObservableObject {
    @Published private(set) var health: SkyLightHealth?
    @Published private(set) var isChecking = false

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { SkyLightHealth.current() }.value
            self.health = result
            self.isChecking = false
        }
    }
}

/// A Form section showing the SkyLight status, one line per capability, the fallback text and a Refresh button.
/// Place it inside a `Form`, for example `Form { SkyLightHealthView() }`.
struct SkyLightHealthView: View {
    @StateObject private var model = SkyLightHealthModel()

    var body: some View {
        Section("SkyLight") {
            if let health = model.health {
                LabeledContent("Status") {
                    Text(Self.statusText(health.overall))
                        .foregroundStyle(Self.statusColor(health.overall))
                        .fontWeight(.medium)
                }
                LabeledContent("Desktop list") { Text(Self.flagText(health.canReadSpaces)) }
                LabeledContent("Move windows between Desktops") { Text(Self.flagText(health.canMoveWindowsToSpace)) }
                LabeledContent("Window Desktop lookup") { Text(Self.flagText(health.canReadWindowSpaces)) }
                if health.overall != .ok {
                    ForEach(health.fallbacks, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Not checked yet.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(model.isChecking ? "Checking..." : "Refresh") {
                    model.refresh()
                }
                .disabled(model.isChecking)
            }
        }
        .onAppear {
            if model.health == nil { model.refresh() }
        }
    }

    private static func statusText(_ overall: SkyLightHealth.Overall) -> String {
        switch overall {
        case .ok: return "OK"
        case .degraded: return "Degraded"
        case .unavailable: return "Unavailable"
        }
    }

    private static func statusColor(_ overall: SkyLightHealth.Overall) -> Color {
        switch overall {
        case .ok: return .green
        case .degraded: return .orange
        case .unavailable: return .red
        }
    }

    private static func flagText(_ available: Bool) -> String {
        available ? "Available" : "Missing"
    }
}
