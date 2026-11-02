import SwiftUI

/// The Settings window: a System-Settings-style sidebar. Each pane lives in Settings/.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, profiles, shortcuts, spacesMonitors, rules, agents, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .profiles: return "Profiles"
        case .shortcuts: return "Shortcuts"
        case .spacesMonitors: return "Spaces & Monitors"
        case .rules: return "Rules & Workspaces"
        case .agents: return "AI Agents"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .profiles: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        case .spacesMonitors: return "display.2"
        case .rules: return "list.bullet.rectangle"
        case .agents: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settings.selectedPane") private var selectedRaw = SettingsPane.general.rawValue

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: selectedRaw) ?? .general },
            set: { if let pane = $0 { selectedRaw = pane.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .imageScale(.medium)
                        .frame(width: 20, height: 20)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail(SettingsPane(rawValue: selectedRaw) ?? .general)
                .navigationTitle((SettingsPane(rawValue: selectedRaw) ?? .general).title)
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: .infinity, minHeight: 480, idealHeight: 540, maxHeight: .infinity)
        .tint(Palette.accent)
        // A toolbar hosts the sidebar toggle in the title bar row, beside the traffic lights.
        .toolbar { ToolbarItem(placement: .automatic) { Color.clear.frame(width: 0, height: 0) } }
        .background(SettingsWindowConfigurator())
    }

    @ViewBuilder
    private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsTab()
        case .profiles: ProfilesSettingsTab()
        case .shortcuts: HotkeysSettingsTab()
        case .spacesMonitors: SpacesMonitorsPane()
        case .rules: RulesWorkspacesPane()
        case .agents: AgentSettingsTab()
        case .about: AboutSettingsTab()
        }
    }
}

/// Spaces, Automation and Monitors as sub-sections of one pane.
private struct SpacesMonitorsPane: View {
    private enum Section: String, CaseIterable { case spaces = "Spaces", automation = "Automation", monitors = "Monitors" }
    @AppStorage("settings.spacesMonitors.section") private var raw = Section.spaces.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $raw) {
                ForEach(Section.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], Spacing.l)
            switch Section(rawValue: raw) ?? .spaces {
            case .spaces: SpacesSettingsTab()
            case .automation: AutomationSettingsTab()
            case .monitors: MonitorsSettingsTab()
            }
        }
    }
}

/// Window rules and virtual workspaces as sub-sections of one pane.
private struct RulesWorkspacesPane: View {
    private enum Section: String, CaseIterable { case rules = "Window Rules", workspaces = "Workspaces" }
    @AppStorage("settings.rules.section") private var raw = Section.rules.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $raw) {
                ForEach(Section.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], Spacing.l)
            switch Section(rawValue: raw) ?? .rules {
            case .rules: WindowRulesSettingsTab()
            case .workspaces: WorkspacesSettingsTab()
            }
        }
    }
}

/// SwiftUI's Settings scene opens a window with close only; enable minimize and zoom, and use a unified title bar.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    /// Configures the window once the view is in it: `updateNSView` can run before the window exists and not again.
    final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // SwiftUI may set the style after attaching the view, so apply on the next turn of the run loop too.
            Self.configure(window)
            DispatchQueue.main.async { Self.configure(window) }
        }

        static func configure(_ window: NSWindow) {
            window.styleMask.insert([.miniaturizable, .resizable])
            window.toolbarStyle = .unified
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        }
    }

    func makeNSView(context: Context) -> NSView { ConfiguringView() }

    func updateNSView(_ view: NSView, context: Context) {}
}
