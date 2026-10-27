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
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
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
        .frame(minWidth: ProfileStudioWindowController.minSize.width, minHeight: ProfileStudioWindowController.minSize.height)
        .clipped()
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
            Button { model.beginNewProfile() } label: {
                Label("New profile", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(model.mode == .edit)
            .help("Start a new profile from a blank layout, the current workspace or a copy")
            .padding(.horizontal, 6).padding(.top, 8)
            List(model.rows, selection: selection) { row in
                ProfileStudioRowView(row: row).tag(row.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }
            .listStyle(.sidebar)
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

    /// Name and actions. Falls back to icon-only buttons, then a single-line subtitle, so it never grows past the pane.
    private func header(_ row: ProfileStudioRow) -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(row, iconOnly: false, truncating: false)
            headerRow(row, iconOnly: true, truncating: false)
            headerRow(row, iconOnly: true, truncating: true)
        }
        .padding(16)
    }

    private func headerRow(_ row: ProfileStudioRow, iconOnly: Bool, truncating: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.title2.bold()).lineLimit(1).truncationMode(.tail)
                Text(ProfileStudioRowView.subtitle(row))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(truncating ? 1 : nil).truncationMode(.tail)
            }
            .frame(maxWidth: truncating ? .infinity : nil, alignment: .leading)
            Spacer(minLength: 8)
            StudioModePicker(model: model)
            Group {
                Button { model.beginNewProfile() } label: { Label("New profile", systemImage: "plus") }
                    .help("Start a new profile from a blank layout, the current workspace or a copy")
                Button { model.startEditing(row.id) } label: { Label("Edit this profile", systemImage: "pencil") }
                    .help("Open this profile in the Builder")
                Button { NSApp.activate(); openSettings() } label: { Label("Reveal in Settings", systemImage: "gearshape") }
                    .help("Reveal in Settings (Profiles tab)")
                    .accessibilityHint("Opens Settings, Profiles tab")
            }
            .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
        }
    }

    /// Compare toggle, Preview restore and Run, with the compare / run status below them.
    private func controlBar(_ row: ProfileStudioRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                controlRow(row, iconOnly: false)
                controlRow(row, iconOnly: true)
            }
            if let error = model.compareError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Compare problem: \(error)")
            }
            if let app = AppState.current { RunStatusLine(app: app).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func controlRow(_ row: ProfileStudioRow, iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.isCompareOn }, set: { model.setCompare($0) })) {
                Label(iconOnly ? "Compare" : "Show what is missing now", systemImage: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .keyboardShortcut("l", modifiers: .command)
            .help("Compare this profile with your Mac (Cmd+L). Only scans: nothing is moved.")
            if model.isComparing {
                ProgressView().controlSize(.small)
                if !iconOnly { Text("Comparing with your Mac…").font(.callout).foregroundStyle(.secondary) }
            } else if model.isCompareOn, model.compareError == nil {
                Button { model.refreshCompare() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Compare again (Cmd+R)")
            }
            Spacer(minLength: 8)
            Button { DebugLog.log("studio", "preview restore opened: \(row.name)"); model.isPreviewPresented = true } label: { Label("Preview restore", systemImage: "list.bullet.rectangle") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("See what a restore would do, step by step (Cmd+Shift+P)")
            if let app = AppState.current {
                RunProfileButton(app: app, profileID: row.id, profileName: row.name)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Title and icon, or the icon alone when the row is short of room (the button keeps its help text).
struct StudioActionLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}

/// The map of one profile with the inspector on its right. Like `ProfileMapHost`, but it owns the
/// `ProfileMapModel` here so the inspector can follow the map's selection.
struct StudioMapHost: View {
    let row: ProfileStudioRow
    @ObservedObject var model: ProfileStudioModel
    @StateObject private var map = ProfileMapModel()

    /// Map 360 + inspector 220 + dividers and padding: below this the inspector moves under the map.
    private static let sideBySideWidth: CGFloat = 1000

    private var mapPane: some View {
        VStack(spacing: 0) {
            ProfileMapCanvas(model: map)
            Divider()
            studioBottomBar { MapLegendView(showsStatus: map.status != nil) }
        }
    }

    private var inspectorPane: MapInspectorView {
        MapInspectorView(map: map, plan: model.comparePlan, isCompareOn: model.isCompareOn)
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.sideBySideWidth {
                HSplitView {
                    mapPane.frame(minWidth: 360)
                    inspectorPane.frame(minWidth: 220, idealWidth: 270, maxWidth: 420)
                }
            } else {
                VSplitView {
                    mapPane.frame(minHeight: 260)
                    inspectorPane.frame(minHeight: 120, idealHeight: 220, maxHeight: 400)
                }
            }
        }
        .task(id: row) { map.load(try? AppState.current?.store.load(row.id)) }
        .onChange(of: model.liveStatus) { _, newValue in map.status = newValue }
        .onAppear { map.status = model.liveStatus }
    }
}

/// Legend on the left, the Debug log switch at the right end.
@MainActor @ViewBuilder
func studioBottomBar<Legend: View>(@ViewBuilder _ legend: () -> Legend) -> some View {
    HStack(spacing: 12) {
        legend()
        Spacer(minLength: 8)
        DebugLogToggle().padding(.trailing, 12)
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
                GeometryReader { geo in
                    if geo.size.width >= Self.sideBySideWidth {
                        HSplitView {
                            libraryAndMap
                            inspector.frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                        }
                    } else {
                        VSplitView {
                            libraryAndMap.frame(minHeight: 260)
                            inspector.frame(minHeight: 140, idealHeight: 240, maxHeight: 420)
                        }
                    }
                }
            }
        }
    }

    /// Library 160 + map 320 + inspector 260 + dividers: below this the inspector moves under the map.
    private static let sideBySideWidth: CGFloat = 1100

    private var libraryAndMap: some View {
        HSplitView {
            AppLibraryView(builder: builder)
                .onAppear { builder.mapModel = map }
                .frame(minWidth: 160, idealWidth: 210, maxWidth: 300)
            VStack(spacing: 0) {
                BuilderMapCanvas(map: map, builder: builder)
                Divider()
                studioBottomBar { MapLegendView(showsStatus: false) }
            }
            .frame(minWidth: 320)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.nameText.isEmpty ? "Untitled profile" : builder.nameText).font(.title2.bold())
                    .lineLimit(1).truncationMode(.tail)
                Text(builder.isNewProfile ? "New profile (not saved yet)" : "Editing a saved profile")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
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
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.icon).frame(width: 22).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1).truncationMode(.tail)
                Text(Self.subtitle(row)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(Self.subtitle(row))")
    }
}
