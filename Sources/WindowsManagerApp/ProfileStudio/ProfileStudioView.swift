import SwiftUI

/// Profile Studio shell: profile list on the left, map placeholder and toolbar on the right.
struct ProfileStudioView: View {
    @ObservedObject var model: ProfileStudioModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                messageView(icon: "exclamationmark.triangle", text: message, action: ("Try Again", { model.reload() }))
            case .empty:
                messageView(icon: "rectangle.3.group", text: "No profiles yet: capture your workspace from the menu bar",
                            action: ("Capture…", { model.beginCapture() }))
            case .loaded:
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                } detail: {
                    detail
                }
                .sheet(isPresented: $model.isStartSheetPresented) {
                    StudioStartSheet(profiles: model.rows, onChoose: { model.chooseStart($0) }, onCancel: { model.cancelStart() })
                }
                .sheet(isPresented: $model.isSaveSheetPresented) {
                    if let builder = model.builder {
                        StudioSaveSheet(builder: builder, onSaved: { model.didSave($0) }, onCancel: { model.cancelSave() })
                    }
                }
                .confirmationDialog("You have unsaved changes", isPresented: $model.isLeaveConfirmPresented, titleVisibility: .visible) {
                    Button("Save…") { model.saveThen { model.leaveEdit() } }
                    Button("Discard Changes", role: .destructive) { model.leaveEdit() }
                    Button("Keep Editing", role: .cancel) {}
                } message: {
                    Text("Leaving Edit mode throws away what you changed since the last save.")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.reload() }
    }

    private func messageView(icon: String, text: String, action: (String, () -> Void)) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action.0, action: action.1)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var sidebar: some View {
        let selection = Binding<UUID?>(get: { model.selectedID }, set: { model.selectedID = $0 })
        return VStack(spacing: 0) {
            List(model.rows, selection: selection) { row in
                ProfileStudioRowView(row: row).tag(row.id)
            }
            .accessibilityLabel("Profiles")
            .disabled(model.mode == .edit)
            if !model.skipped.isEmpty {
                Text("Could not read: \(model.skipped.joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.mode == .edit, let builder = model.builder {
            StudioEditDetail(model: model, builder: builder)
                .id(ObjectIdentifier(builder))
        } else if let row = model.selectedRow {
            VStack(spacing: 0) {
                header(row)
                Divider()
                controlBar(row)
                Divider()
                StudioMapHost(row: row, model: model)
            }
            .sheet(isPresented: $model.isPreviewPresented) {
                RestorePreviewSheet(profileID: row.id, profileName: row.name) { model.isPreviewPresented = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                // The Studio window coming back to the front: refresh the comparison (never polls).
                if (note.object as? NSWindow)?.isKeyWindow == true, !model.isPreviewPresented { model.refreshCompare() }
            }
        } else {
            Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ row: ProfileStudioRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.title2.bold())
                Text(ProfileStudioRowView.subtitle(row))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StudioModePicker(model: model)
            Button { model.beginNewProfile() } label: { Label("New profile", systemImage: "plus") }
                .help("Start a new profile from a blank layout, the current workspace or a copy")
            Button { model.startEditing(row.id) } label: { Label("Edit this profile", systemImage: "pencil") }
                .help("Open this profile in the Builder")
            Button { NSApp.activate(); openSettings() } label: { Label("Reveal in Settings", systemImage: "gearshape") }
                .accessibilityHint("Opens Settings, Profiles tab")
        }
        .padding(16)
    }

    /// Compare toggle, Preview restore and Run, with the compare / run status next to them.
    private func controlBar(_ row: ProfileStudioRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.isCompareOn }, set: { model.setCompare($0) })) {
                    Label("Show what is missing now", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .keyboardShortcut("l", modifiers: .command)
                .help("Compare this profile with your Mac (Cmd+L). Only scans: nothing is moved.")
                if model.isComparing {
                    ProgressView().controlSize(.small)
                    Text("Comparing with your Mac…").font(.callout).foregroundStyle(.secondary)
                } else if model.isCompareOn, model.compareError == nil {
                    Button { model.refreshCompare() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Compare again (Cmd+R)")
                }
                Spacer()
                Button { model.isPreviewPresented = true } label: { Label("Preview restore", systemImage: "list.bullet.rectangle") }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help("See what a restore would do, step by step (Cmd+Shift+P)")
                if let app = AppState.current {
                    RunProfileButton(app: app, profileID: row.id, profileName: row.name)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if let error = model.compareError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Compare problem: \(error)")
            }
            if let app = AppState.current { RunStatusLine(app: app) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// The map of one profile with the inspector on its right. Like `ProfileMapHost`, but it owns the
/// `ProfileMapModel` here so the inspector can follow the map's selection.
struct StudioMapHost: View {
    let row: ProfileStudioRow
    @ObservedObject var model: ProfileStudioModel
    @StateObject private var map = ProfileMapModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ProfileMapCanvas(model: map)
                Divider()
                MapLegendView(showsStatus: map.status != nil)
            }
            .frame(minWidth: 420)
            MapInspectorView(map: map, plan: model.comparePlan, isCompareOn: model.isCompareOn)
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 420)
        }
        .task(id: row) { map.load(try? AppState.current?.store.load(row.id)) }
        .onChange(of: model.liveStatus) { _, newValue in map.status = newValue }
        .onAppear { map.status = model.liveStatus }
    }
}

/// View / Edit segmented toggle.
struct StudioModePicker: View {
    @ObservedObject var model: ProfileStudioModel

    var body: some View {
        Picker("Mode", selection: Binding(get: { model.mode }, set: { model.requestMode($0) })) {
            Text("View").tag(ProfileStudioMode.view)
            Text("Edit").tag(ProfileStudioMode.edit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .accessibilityLabel("Mode")
        .help("Switch between viewing and editing the profile")
    }
}

enum StudioInspectorTab: String, CaseIterable, Identifiable {
    case inspector = "Inspector"
    case options = "Options"
    case launchOrder = "Launch order"
    var id: String { rawValue }
}

@MainActor
final class StudioEditLocalState: ObservableObject {
    @Published var tab: StudioInspectorTab = .inspector
}

/// Edit mode: header and edit bar, app library, the builder map and the inspector tabs.
struct StudioEditDetail: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var builder: ProfileBuilderModel
    @StateObject private var map = ProfileMapModel()
    @StateObject private var local = StudioEditLocalState()

    var body: some View {
        switch builder.phase {
        case .idle:
            VStack(spacing: 12) {
                Text("Choose how to start the new profile.").foregroundStyle(.secondary)
                Button("Choose…") { model.isStartSheetPresented = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .starting:
            ProgressView("Preparing the draft…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Back to View") { model.leaveEdit() }
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                header
                Divider()
                editBar
                Divider()
                HSplitView {
                    AppLibraryView(builder: builder)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    VStack(spacing: 0) {
                        BuilderMapCanvas(map: map, builder: builder)
                        Divider()
                        MapLegendView(showsStatus: false)
                    }
                    .frame(minWidth: 380)
                    inspector
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 440)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.nameText.isEmpty ? "Untitled profile" : builder.nameText).font(.title2.bold())
                Text(builder.isNewProfile ? "New profile (not saved yet)" : "Editing a saved profile")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StudioModePicker(model: model)
        }
        .padding(16)
    }

    private var editBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { builder.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!builder.canUndo)
                    .help("Undo the last change (Cmd+Z)")
                Button { builder.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!builder.canRedo)
                    .help("Redo (Shift+Cmd+Z)")
                Spacer()
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(builder.errorCount > 0 ? Color.red : (builder.warningCount > 0 ? Color.orange : Color.secondary))
                    .accessibilityLabel("Draft check: \(statusText)")
                Button { model.saveThen(nil) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(builder.blocksSaving)
                    .help(builder.blocksSaving ? "Fix the problems marked in red first" : "Save the profile (Cmd+S)")
            }
            if let message = builder.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !builder.startNotes.isEmpty {
                Text(builder.startNotes.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var statusText: String {
        let e = builder.errorCount, w = builder.warningCount
        var parts: [String] = []
        if builder.isDirty { parts.append("Unsaved changes") }
        if e == 0 && w == 0 {
            parts.append("No problems")
        } else {
            if e > 0 { parts.append("\(e) problem\(e == 1 ? "" : "s")") }
            if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        }
        return parts.joined(separator: " · ")
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: Binding(get: { local.tab }, set: { local.tab = $0 })) {
                ForEach(StudioInspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(8)
            Divider()
            switch local.tab {
            case .inspector: MapInspectorView(map: map, plan: nil, isCompareOn: false)
            case .options: ProfileOptionsPanel(builder: builder)
            case .launchOrder: LaunchOrderEditor(builder: builder)
            }
        }
    }
}

struct ProfileStudioRowView: View {
    let row: ProfileStudioRow

    static func subtitle(_ row: ProfileStudioRow) -> String {
        let windows = "\(row.windowCount) window\(row.windowCount == 1 ? "" : "s")"
        let monitors = "\(row.monitorCount) monitor\(row.monitorCount == 1 ? "" : "s")"
        return "\(windows) · \(monitors) · Captured \(row.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.icon).frame(width: 22).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(Self.subtitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(Self.subtitle(row))")
    }
}
