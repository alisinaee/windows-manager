import KeyboardShortcuts
import SwiftUI
import WMCore

/// Run button (Cmd+Return, so Return on the canvas never runs a profile) with the shortcut chip at its right.
/// The chip opens the recorder popover; it re-reads the stored shortcut when the popover closes.
struct StudioRunControl: View {
    @ObservedObject var app: AppState
    let profileID: UUID
    let profileName: String
    var iconOnly: Bool

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @Binding var showEditor: Bool

    private var isSaved: Bool { app.savedProfiles.contains { $0.id == profileID } }

    var body: some View {
        if let progress = app.runProgress {
            runningBody(progress)
        } else {
            runMenu
        }
    }

    /// Spinner or bar with the current step, and Stop; replaces the Run button while a run is in flight.
    private func runningBody(_ progress: RunProgress) -> some View {
        HStack(spacing: Spacing.s) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 64)
            } else {
                ProgressView().controlSize(.small)
            }
            if !iconOnly {
                Text(progress.label).font(.wmCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
            }
            Button { app.cancelRun() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly) }
                .buttonStyle(.glass)
                .help("Stop restoring \(progress.profileName)")
                .accessibilityLabel("Stop running \(progress.profileName)")
        }
        .help(progress.label)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Running \(progress.profileName): \(progress.label)")
        .animation(Motion.quick, value: progress.done)
    }

    private var runMenu: some View {
        Menu {
            Button(shortcut.map { "Change Shortcut \($0.description)" } ?? "Set Shortcut…") {
                DebugLog.log("studio", "shortcut opened: \(profileName)")
                showEditor = true
            }
            .disabled(!isSaved)
        } label: { Label("Run", systemImage: "play.fill") }
        primaryAction: {
            DebugLog.log("studio", "run clicked: \(profileName)")
            app.run(id: profileID)
        }
        .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
        .menuStyle(.button)
        .buttonStyle(.glassProminent).tint(Palette.accentStrong)
        .tint(Palette.accentStrong)
        .foregroundStyle(.white)
        .disabled(!app.canAct)
        .help((studioRunBlockReason(app) ?? "Restore \(profileName) now") + " (Cmd+Return). Menu: run shortcut.")
        .accessibilityLabel("Run profile \(profileName)")
        .popover(isPresented: $showEditor, arrowEdge: .bottom) {
            ProfileShortcutView(profileID: profileID, profileName: profileName).padding(12).frame(width: 280)
        }
        .onAppear(perform: reload)
        .onChange(of: profileID) { _, _ in reload() }
        .onChange(of: showEditor) { _, _ in reload() }
    }

    private func reload() { shortcut = KeyboardShortcuts.getShortcut(for: .profile(profileID)) }
}
