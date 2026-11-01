import SwiftUI
import WMCore

/// The Options page of the Details inspector: one plain-language switch per profile option, each with a caption
/// that says what the restore does. In Edit mode every change goes through `builder.setOptions`, so it is undoable;
/// in View mode (`builder` nil) the same switches show the saved options and cannot be changed.
/// Plain content: the inspector container supplies the scrolling.
struct ProfileOptionsPanel: View {
    let profile: Profile
    let builder: ProfileBuilderModel?

    private var options: ProfileOptions { profile.options }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            desktopsSection
            appsSection
            otherAppsSection
            stageManagerSection
            if let error = builder?.lastError { InspectorNote(text: error) }
        }
        .disabled(builder == nil)
        .accessibilityLabel("Profile options")
    }

    // MARK: Sections

    private var desktopsSection: some View {
        InspectorSection(title: "Desktops") {
            toggleRow("Add missing Desktops", isOn: \.addMissingDesktops,
                      caption: "Create Desktops this profile uses that a monitor lacks (up to 8 per run).")
            toggleRow("Restore Desktop assignment", isOn: \.restoreSpaces,
                      caption: "Move each window to its saved Desktop instead of the one showing.")
            VStack(alignment: .leading, spacing: Spacing.xs) {
                toggleRow("Restore Desktop order", isOn: \.restoreSpaceOrder,
                          caption: "Put full-screen Desktops back in their saved order.")
                    .disabled(!options.restoreSpaces)
                InspectorNote(text: "This may move Desktops around, so you are asked to confirm first.")
            }
            toggleRow("Restore full-screen apps", isOn: \.restoreFullScreen,
                      caption: "Send apps that were full screen back to their own Desktop.")
            ForEach(Array(relatedDraftIssues.enumerated()), id: \.offset) { _, text in
                InspectorNote(text: text)
            }
        }
    }

    private var appsSection: some View {
        InspectorSection(title: "Apps") {
            toggleRow("Launch apps that are closed", isOn: \.launchMissingApps,
                      caption: "Off: only apps that are already open are placed.")
            if !options.launchMissingApps, profile.launchPlan?.items.contains(where: \.enabled) == true {
                InspectorNote(text: "The launch order is kept but not used while this is off.", tone: .info)
            }
            if let builder, !builder.launchIssues.isEmpty {
                let n = builder.launchIssues.count
                InspectorNote(text: "\(n) problem\(n == 1 ? "" : "s") in the launch order. Open the Launch page to fix \(n == 1 ? "it" : "them").")
            }
        }
    }

    private var otherAppsSection: some View {
        InspectorSection(title: "When restoring") {
            Picker("Other apps", selection: Binding(
                get: { options.otherApps },
                set: { value in builder?.setOptions { $0.otherApps = value } })) {
                Text("Leave alone").tag(OtherAppsPolicy.leave)
                Text("Hide").tag(OtherAppsPolicy.hide)
                Text("Quit (ask first)").tag(OtherAppsPolicy.quit)
            }
            .help("Choose what a restore does with apps outside this profile: leave them alone, hide them, or quit them after you confirm")
            Text(otherAppsCaption(options.otherApps))
                .font(.wmCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stageManagerSection: some View {
        InspectorSection(title: "Stage Manager") {
            LabeledContent("When captured", value: stageManagerText(profile.stageManagerOn))
            Text("Windows Manager never turns Stage Manager on or off. Restoring works best with it off.")
                .font(.wmCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func toggleRow(_ title: String, isOn keyPath: WritableKeyPath<ProfileOptions, Bool>, caption: String) -> some View {
        InspectorToggleRow(title: title, caption: caption, isOn: Binding(
            get: { options[keyPath: keyPath] },
            set: { value in builder?.setOptions { $0[keyPath: keyPath] = value } }))
    }

    private func otherAppsCaption(_ policy: OtherAppsPolicy) -> String {
        switch policy {
        case .leave: return "Apps outside this profile stay as they are."
        case .hide: return "Apps outside this profile are hidden. Nothing is closed."
        case .quit: return "Apps outside this profile are quit after you confirm the list."
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
    private var relatedDraftIssues: [String] {
        (builder?.draftIssues ?? [])
            .filter { $0.code == .tooManyDesktops || ($0.code == .windowOnMissingDesktop && !options.addMissingDesktops) }
            .map(\.message)
    }
}
