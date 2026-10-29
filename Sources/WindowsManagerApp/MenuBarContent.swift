import SwiftUI
import WMCore

/// Menu shown from the menu bar item: profiles with Run, Capture, status.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var workspaces = WorkspaceController.shared
    @ObservedObject private var updates = UpdateController.shared

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

            profilesSection

            Divider().padding(.vertical, 2)

            captureSection

            statusRow

            workspacesSection

            Divider().padding(.vertical, 2)

            MenuRow(title: "Setup…") {
                Self.closePopup(); OnboardingWindowController.shared.show()
            }
            MenuRow(title: "Profiles…") {
                Self.closePopup(); ProfileStudioWindowController.shared.show()
            }
            MenuRow(title: "Check for Updates…") {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            if !updates.isConfigured {
                Text(UpdateController.notConfiguredText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            MenuRow(title: "Settings…") {
                Self.closePopup()
                NSApp.activate()
                openSettings()
            }
            MenuRow(title: "Report a Bug…") {
                Self.closePopup(); BugReportWindowController.shared.show()
            }
            MenuRow(title: (appState.debugMode ? "\u{2713} " : "    ") + "Debug") {
                Self.closePopup(); appState.debugMode.toggle()
            }
            .help("Shows the live test panel for the window-restore scenarios")
            MenuRow(title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 280)
        .onAppear { appState.refreshPermissions() }
    }

    /// Hides the menu bar popup (a MenuBarExtra window-style panel) before another window opens.
    private static func closePopup() {
        for window in NSApp.windows where window is NSPanel && window.className.contains("MenuBarExtra") {
            window.orderOut(nil)
        }
    }

    @ViewBuilder private var profilesSection: some View {
        if appState.savedProfiles.isEmpty {
            Text("No saved profiles yet")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        } else {
            ForEach(appState.savedProfiles) { profile in
                let choices = appState.scopeChoices[profile.id] ?? []
                if choices.count > 1 {
                    HStack(spacing: 0) {
                        MenuRow(title: "Run \(profile.name)") { appState.run(profile) }
                        Menu {
                            ForEach(choices) { choice in
                                Button(choice.title) { appState.run(profile, scope: choice.scope) }
                            }
                        } label: { Text("Scope") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Run the whole profile, one Desktop or one monitor")
                        .accessibilityLabel("Run \(profile.name) scope")
                    }
                    .disabled(!appState.canAct)
                } else {
                    MenuRow(title: "Run \(profile.name)") { appState.run(profile) }
                        .disabled(!appState.canAct)
                }
            }
        }
    }

    @ViewBuilder private var workspacesSection: some View {
        if workspaces.isEnabled {
            Divider().padding(.vertical, 2)
            Text("Workspaces")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(workspaces.workspaces) { ws in
                MenuRow(title: (ws.id == workspaces.activeID ? "\u{2713} " : "    ") + ws.name) {
                    workspaces.switchTo(ws.id)
                }
            }
            if workspaces.isSwitching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Switching…").foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            MenuRow(title: "+ New workspace") { workspaces.createWorkspace() }
            MenuRow(title: "Add front app to current") { workspaces.addFrontmostAppToActive() }
                .disabled(workspaces.activeID == nil)
            if let text = workspaces.statusText {
                Text(text).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder private var captureSection: some View {
        if let pending = appState.pendingCapture {
            captureChoiceView(pending)
        } else if appState.isNamingCapture {
            HStack(spacing: 6) {
                TextField("Profile name", text: $appState.captureName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appState.commitCapture() }
                Button("Save") { appState.commitCapture() }
                    .disabled(appState.captureName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { appState.cancelCapture() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else {
            MenuRow(title: "Capture current workspace…") { appState.beginCapture() }
                .disabled(!appState.canAct)
                .help("Name a new profile and save the current workspace to it")
                .accessibilityLabel("Capture current workspace")
            MenuRow(title: "Choose what to save…") { appState.beginSelectiveCapture() }
                .disabled(!appState.canAct)
                .help("Capture now, then tick the monitors, Desktops and windows to keep")
            MenuRow(title: "Capture now (3 s)") {
                // Close the popup first so it is not in the capture; the countdown gives the stage time to settle.
                Self.closePopup(); appState.captureNow()
            }
            .disabled(!appState.canAct)
            .help("Closes this menu, waits 3 seconds, then saves the current workspace as a new profile")
            .accessibilityLabel("Capture now in 3 seconds")
        }
    }

    private func captureChoiceView(_ pending: PendingCapture) -> some View {
        let binding = Binding<PendingCapture>(get: { appState.pendingCapture ?? pending }, set: { appState.pendingCapture = $0 })
        let selection = binding.wrappedValue.selection
        return VStack(alignment: .leading, spacing: 2) {
            Text("Choose what to save (\(selection.selectedWindows) of \(selection.totalWindows) windows)")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(selection.tree.monitors) { monitor in
                Toggle(monitor.display?.name ?? "Monitor", isOn: Binding(
                    get: { binding.wrappedValue.selection.state(of: monitor) != .off },
                    set: { _ in binding.wrappedValue.selection.toggle(monitor: monitor) }))
                    .font(.callout.bold())
                ForEach(monitor.groups) { group in
                    Toggle(Self.groupTitle(group), isOn: Binding(
                        get: { binding.wrappedValue.selection.state(of: group) != .off },
                        set: { _ in binding.wrappedValue.selection.toggle(group: group) }))
                        .padding(.leading, 14)
                }
            }
            TextField("Profile name", text: Binding(get: { binding.wrappedValue.name }, set: { binding.wrappedValue.name = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") { appState.saveSelectiveCapture() }
                    .disabled(!selection.hasSelection || binding.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { appState.cancelSelectiveCapture() }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private static func groupTitle(_ group: CaptureSelectionTree.Group) -> String {
        let count = "\(group.windowIDs.count) window(s)"
        switch group.kind {
        case .desktop: return "Desktop \(group.desktopNumber ?? 0), \(count)"
        case .fullScreen: return "Full-screen Space, \(count)"
        default: return "Other windows, \(count)"
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            switch appState.status {
            case .idle:
                Text("Idle").foregroundStyle(.secondary)
            case .running(let text):
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            case .success(let text):
                Text(text).foregroundStyle(.secondary)
            case .failure(let text):
                Text(text).foregroundStyle(Color.red)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
