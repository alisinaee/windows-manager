import SwiftUI
import WMCore

/// The Builder's Options step (plan B2 step 4): one plain-language switch per profile option, each with a
/// caption that says what the restore does. Every change goes through `builder.setOptions`, so it is undoable.
///
/// Host: `ProfileOptionsPanel(builder: builder)` (UI7 puts it in the Inspector tab "Options").
struct ProfileOptionsPanel: View {
    @ObservedObject var builder: ProfileBuilderModel

    var body: some View {
        if let profile = builder.profile {
            Form {
                iconSection(profile)
                desktopsSection(profile.options)
                appsSection(profile)
                otherAppsSection(profile.options)
                stageManagerSection(profile)
                if let error = builder.lastError { issueRow(error, symbol: "exclamationmark.triangle") }
            }
            .formStyle(.grouped)
            .scrollIndicators(.visible)
            .accessibilityLabel("Profile options")
        } else {
            Text("No profile is open.").foregroundStyle(.secondary).padding()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func iconSection(_ profile: Profile) -> some View {
        Section("Icon") {
            LabeledContent("Sidebar icon") {
                ProfileIconPicker(current: profile.icon.isEmpty ? Profile.defaultIcon : profile.icon) { builder.setIcon($0) }
            }
            Text("Shown next to the profile name in the Profile Studio sidebar. Saved with the profile when you press Save.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func desktopsSection(_ options: ProfileOptions) -> some View {
        Section("Desktops") {
            optionToggle("Add missing Desktops", isOn: \.addMissingDesktops,
                         caption: "If a monitor has fewer Desktops than this profile uses, create the missing ones first (up to 8 per run).")
            optionToggle("Restore Desktop assignment", isOn: \.restoreSpaces,
                         caption: "Move each window to the Desktop it is on in this profile. Off: windows are placed on whichever Desktop is showing.")
            VStack(alignment: .leading, spacing: 4) {
                optionToggle("Restore Desktop order", isOn: \.restoreSpaceOrder,
                             caption: "Put full-screen Desktops back in their saved order.")
                    .disabled(!options.restoreSpaces)
                Label("This may move Desktops around. Windows Manager asks you to confirm first, and the screen can flicker briefly.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            optionToggle("Restore full-screen apps", isOn: \.restoreFullScreen,
                         caption: "Send apps that were full screen back to their own full-screen Desktop.")
            ForEach(Array(relatedDraftIssues(options).enumerated()), id: \.offset) { _, text in
                issueRow(text, symbol: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private func appsSection(_ profile: Profile) -> some View {
        Section("Apps") {
            optionToggle("Launch apps that are closed", isOn: \.launchMissingApps,
                         caption: "Open apps of this profile that are not running. Off: only apps that are already open are placed.")
            if !profile.options.launchMissingApps, profile.launchPlan?.items.contains(where: \.enabled) == true {
                issueRow("The launch order is kept but not used while this is off.", symbol: "info.circle")
            }
            if !builder.launchIssues.isEmpty {
                let n = builder.launchIssues.count
                issueRow("\(n) problem\(n == 1 ? "" : "s") in the launch order. Open the Launch order tab to fix \(n == 1 ? "it" : "them").",
                         symbol: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private func otherAppsSection(_ options: ProfileOptions) -> some View {
        Section("When restoring") {
            Picker("Other apps", selection: Binding(
                get: { builder.profile?.options.otherApps ?? options.otherApps },
                set: { value in builder.setOptions { $0.otherApps = value } })) {
                Text("Leave alone").tag(OtherAppsPolicy.leave)
                Text("Hide").tag(OtherAppsPolicy.hide)
                Text("Quit (ask first)").tag(OtherAppsPolicy.quit)
            }
            .help("Choose what a restore does with apps outside this profile: leave them alone, hide them, or quit them after you confirm")
            Text(otherAppsCaption(options.otherApps))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func stageManagerSection(_ profile: Profile) -> some View {
        Section("Stage Manager") {
            LabeledContent("When captured", value: stageManagerText(profile.stageManagerOn))
            Text("Windows Manager never turns Stage Manager on or off. This shows the state saved with the profile; restoring works best with it off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func optionToggle(_ title: String, isOn keyPath: WritableKeyPath<ProfileOptions, Bool>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: Binding(
                get: { builder.profile?.options[keyPath: keyPath] ?? false },
                set: { value in builder.setOptions { $0[keyPath: keyPath] = value } }))
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .help("Turn \(title) on or off")
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func issueRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func otherAppsCaption(_ policy: OtherAppsPolicy) -> String {
        switch policy {
        case .leave: return "Apps that are not part of this profile stay as they are."
        case .hide: return "Apps that are not part of this profile are hidden. Nothing is closed."
        case .quit: return "Apps that are not part of this profile are quit, but you are asked to confirm the list first."
        }
    }

    private func stageManagerText(_ on: Bool?) -> String {
        switch on {
        case .some(true): return "On"
        case .some(false): return "Off"
        case .none: return "Not recorded"
        }
    }

    /// Draft problems that an option here can solve.
    private func relatedDraftIssues(_ options: ProfileOptions) -> [String] {
        builder.draftIssues
            .filter { $0.code == .tooManyDesktops || ($0.code == .windowOnMissingDesktop && !options.addMissingDesktops) }
            .map(\.message)
    }
}
