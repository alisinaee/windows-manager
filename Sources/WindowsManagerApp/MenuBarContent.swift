import SwiftUI
import KeyboardShortcuts
import WMCore

/// Menu shown from the menu bar item: profiles with Run, Capture, status.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var workspaces = WorkspaceController.shared
    @ObservedObject private var updates = UpdateController.shared
    @StateObject private var nav = MenuNav()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs / 2) {
            Text("Windows Manager")
                .font(.headline)
                .padding(.horizontal, Spacing.s + 2)
                .padding(.top, Spacing.xs + 2)
                .padding(.bottom, Spacing.xs)

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
            if updates.isConfigured {
                MenuRow(title: "Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
            MenuRow(title: "Settings…") {
                Self.closePopup()
                NSApp.activate()
                openSettings()
            }
            MenuRow(title: "Report a Bug…") {
                Self.closePopup(); BugReportWindowController.shared.show()
            }
            MenuRow(title: "Debug", checked: appState.debugMode) {
                Self.closePopup(); appState.debugMode.toggle()
            }
            .help("Shows the live test panel for the window-restore scenarios")
            MenuRow(title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(Spacing.xs + 2)
        .frame(width: 280)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { nav.move(1, count: appState.savedProfiles.count); return .handled }
        .onKeyPress(.upArrow) { nav.move(-1, count: appState.savedProfiles.count); return .handled }
        .onKeyPress(.return) {
            let profiles = appState.savedProfiles
            guard let i = nav.index, profiles.indices.contains(i) else { return .ignored }
            runProfile(profiles[i]); return .handled
        }
        .onKeyPress(.escape) { Self.closePopup(); return .handled }
        .onAppear { appState.refreshPermissions(); nav.index = nil }
    }

    /// Hides the menu bar popup (a MenuBarExtra window-style panel) before another window opens.
    private static func closePopup() {
        for window in NSApp.windows where window is NSPanel && window.className.contains("MenuBarExtra") {
            window.orderOut(nil)
        }
    }

    private func runProfile(_ profile: ProfileSummary, scope: RestoreScope = .whole) {
        guard appState.canAct else { return }
        nav.lastRunID = profile.id
        appState.run(profile, scope: scope)
    }

    private func shortcutText(_ profile: ProfileSummary) -> String? {
        KeyboardShortcuts.getShortcut(for: .profile(profile.id))?.description
    }

    @ViewBuilder private var profilesSection: some View {
        if appState.savedProfiles.isEmpty {
            Text("No saved profiles yet")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        } else {
            profileRows
        }
    }

    @ViewBuilder private var profileRows: some View {
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(appState.savedProfiles.enumerated()), id: \.element.id) { offset, profile in
                let hl = nav.index == offset
                let isLast = nav.lastRunID == profile.id
                let choices = appState.scopeChoices[profile.id] ?? []
                if choices.count > 1 {
                    HStack(spacing: 0) {
                        MenuRow(title: "Run \(profile.name)", checked: isLast, trailing: shortcutText(profile), highlighted: hl) { runProfile(profile) }
                        Menu {
                            ForEach(choices) { choice in
                                Button(choice.title) { runProfile(profile, scope: choice.scope) }
                            }
                        } label: { Text("Scope") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Run the whole profile, one Desktop or one monitor")
                        .accessibilityLabel("Run \(profile.name) scope")
                    }
                    .disabled(!appState.canAct)
                } else {
                    MenuRow(title: "Run \(profile.name)", checked: isLast, trailing: shortcutText(profile), highlighted: hl) { runProfile(profile) }
                        .disabled(!appState.canAct)
                }
            }
        }
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
        }
        .frame(maxHeight: 300)
    }

    @ViewBuilder private var workspacesSection: some View {
        if workspaces.isEnabled {
            Divider().padding(.vertical, 2)
            Text("Workspaces")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(workspaces.workspaces) { ws in
                MenuRow(title: ws.name, checked: ws.id == workspaces.activeID) {
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
            MenuRow(title: "New workspace", symbol: "plus") { workspaces.createWorkspace() }
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

    @ViewBuilder private var statusRow: some View {
        switch appState.status {
        case .idle: EmptyView()
        case .failure(let text):
            Banner(tone: .danger, title: "Something went wrong", message: text,
                   actionLabel: failureActionLabel(text), action: failureAction(text))
                .padding(.vertical, Spacing.xs)
        default: statusContent
        }
    }

    private func failureActionLabel(_ text: String) -> String? {
        text.localizedCaseInsensitiveContains("accessibility") ? "Grant access" : nil
    }

    private func failureAction(_ text: String) -> (() -> Void)? {
        text.localizedCaseInsensitiveContains("accessibility") ? { appState.requestAccessibility() } : nil
    }

    private var statusContent: some View {
        HStack(alignment: .top, spacing: 6) {
            switch appState.status {
            case .idle:
                EmptyView()
            case .running(let text):
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            case .success(let text):
                Text(text).foregroundStyle(.secondary)
            case .failure:
                EmptyView()
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
            if !appState.isAccessibilityTrusted {
                Button("Grant…") { appState.requestAccessibility() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// A full-width menu style row (the .window style does not draw native menu items).
/// `@State` is a macro in the macOS 27 SDK and its plugin (SwiftUIMacros) ships only with Xcode,
/// so this target avoids it to build with the Command Line Tools; hover lives in an ObservableObject.
private struct MenuRow: View {
    let title: String
    var checked: Bool? = nil
    var symbol: String? = nil
    var trailing: String? = nil
    var highlighted = false
    let action: () -> Void

    init(title: String, checked: Bool? = nil, symbol: String? = nil, trailing: String? = nil,
         highlighted: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.checked = checked; self.symbol = symbol
        self.trailing = trailing; self.highlighted = highlighted; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if checked != nil || symbol != nil {
                    Image(systemName: symbol ?? "checkmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 14)
                        .opacity(symbol != nil || checked == true ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(title).font(.wmBody)
                if let trailing {
                    Spacer(minLength: Spacing.s)
                    Text(trailing).font(.wmMonoCaption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.s + 2)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle(highlighted: highlighted))
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }
}

private final class HoverState: ObservableObject {
    @Published var hovering = false
}

private final class MenuNav: ObservableObject {
    @Published var index: Int?
    @Published var lastRunID: UUID?
    func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        guard let i = index else { index = delta > 0 ? 0 : count - 1; return }
        index = min(max(i + delta, 0), count - 1)
    }
}

private struct MenuRowBackground<Content: View>: View {
    @StateObject private var hover = HoverState()
    let highlighted: Bool
    let isPressed: Bool
    let isEnabled: Bool
    let content: Content

    var body: some View {
        content
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: Radius.small + 1)
                    .fill(isEnabled && isPressed ? Color.accentColor.opacity(0.3)
                          : isEnabled && (hover.hovering || highlighted) ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .onHover { hover.hovering = $0 }
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        MenuRowBackground(highlighted: highlighted, isPressed: configuration.isPressed, isEnabled: isEnabled, content: configuration.label)
    }
}
