import AppKit
import KeyboardShortcuts
import SwiftUI
import WMCore

/// Global hotkeys: workspace switching, snap to zone, window size, move to display, ignored apps and one per saved profile.
struct HotkeysSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.undoManager) private var undoManager
    @State private var removedApp: String?
    @State private var dismissTask: Task<Void, Never>?
    @ObservedObject private var workspaces = WorkspaceController.shared
    @State private var ignoreList = HotkeyIgnoreList.load()
    /// The last app other than this one that became frontmost. Settings is frontmost while the user clicks Add.
    @State private var lastOtherApp: (bundleID: String, name: String)?

    var body: some View {
        Form {
            if let removedApp {
                Section {
                    Banner(tone: .info, title: "Deleted \(removedApp)", actionLabel: "Undo",
                           action: { undoRemove() }, onDismiss: { clearRemoved() })
                }
            }
            Section("Workspaces") {
                KeyboardShortcuts.Recorder("Next workspace", name: .nextWorkspace)
                KeyboardShortcuts.Recorder("Previous workspace", name: .previousWorkspace)
                if !workspaces.isEnabled {
                    Text("These only work while Virtual workspaces is turned on in the Workspaces tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Snap to zone") {
                ForEach(0..<9, id: \.self) { i in
                    KeyboardShortcuts.Recorder("Zone \(i + 1)", name: KeyboardShortcuts.Name.snapZones[i])
                }
                Text("Moves the frontmost window into that zone of the layout for its display.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Window size") {
                ForEach(WindowSizeDirection.allCases, id: \.self) { direction in
                    KeyboardShortcuts.Recorder(Self.title(for: direction), name: .windowSize(direction))
                }
                Text("Press again to cycle half, two-thirds and one-third. Center keeps the window centred.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Move to display") {
                KeyboardShortcuts.Recorder("Next display", name: .moveToNextDisplay)
                KeyboardShortcuts.Recorder("Previous display", name: .moveToPreviousDisplay)
                Text("Keeps the window's position and size where possible, and moves it onto the other display.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Ignored apps") {
                if ignoreList.bundleIDs.isEmpty {
                    ContentUnavailableView("No ignored apps", systemImage: "app.dashed",
                                           description: Text("Shortcuts work everywhere."))
                }
                ForEach(ignoreList.bundleIDs, id: \.self) { bundleID in
                    HStack {
                        IgnoredAppRow(bundleID: bundleID)
                        Spacer()
                        Button("Remove", role: .destructive) { remove(bundleID) }
                    }
                }
                Button(addTitle) { addLastOtherApp() }
                    .disabled(lastOtherApp == nil || ignoreList.contains(lastOtherApp?.bundleID))
                Text("Shortcuts do nothing while a listed app is frontmost. Switch to the app, then come back here and press Add.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Profiles") {
                if state.savedProfiles.isEmpty {
                    ContentUnavailableView("No saved profiles yet", systemImage: "rectangle.3.group")
                }
                ForEach(state.savedProfiles) { profile in
                    KeyboardShortcuts.Recorder(profile.name, name: .profile(profile.id))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            HotkeyController.shared.syncProfiles()
            noteFrontmost(NSWorkspace.shared.frontmostApplication)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { note in
            noteFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private var addTitle: String {
        "Add \(lastOtherApp?.name ?? "frontmost app")"
    }

    private func noteFrontmost(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        lastOtherApp = (bundleID, app.localizedName ?? bundleID)
    }

    private func addLastOtherApp() {
        guard let bundleID = lastOtherApp?.bundleID else { return }
        ignoreList.add(bundleID)
        ignoreList.save()
    }

    private func remove(_ bundleID: String) {
        ignoreList.remove(bundleID)
        ignoreList.save()
        removedApp = bundleID
        undoManager?.registerUndo(withTarget: HotkeyUndoTarget.shared) { _ in MainActor.assumeIsolated { undoRemove() } }
        undoManager?.setActionName("Remove Ignored App")
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { clearRemoved() }
        }
    }

    private func clearRemoved() {
        dismissTask?.cancel()
        removedApp = nil
    }

    private func undoRemove() {
        if let id = removedApp {
            ignoreList.add(id)
            ignoreList.save()
        }
        clearRemoved()
    }

    private static func title(for direction: WindowSizeDirection) -> String {
        switch direction {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .center: return "Center"
        }
    }
}

/// One ignored app: its icon and name, or the bundle id when the app is not installed.
private struct IgnoredAppRow: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(Self.name(for: url)).lineLimit(1)
            }
            .help(bundleID)
        } else {
            Text(bundleID).textSelection(.enabled)
        }
    }

    private static func name(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// Target object for undo registrations (the actual undo is the banner action).
private final class HotkeyUndoTarget: NSObject { static let shared = HotkeyUndoTarget() }
