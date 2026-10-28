import KeyboardShortcuts
import SwiftUI
import WMCore

/// Profile Studio shell: profile list on the left, map placeholder and toolbar on the right.
struct ProfileStudioView: View {
    @ObservedObject var model: ProfileStudioModel
    @Environment(\.openSettings) private var openSettings
    /// Width of the full profile sidebar: dragged between 200 and 340 points and remembered between launches.
    @AppStorage("studioSidebarWidth") private var storedSidebarWidth: Double = 240
    @State private var sidebarDragStart: Double?

    private static let sidebarWidthRange: ClosedRange<Double> = 200...340

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                messageView(icon: "exclamationmark.triangle", text: message, action: ("Try Again", { model.reload() }))
            case .empty:
                emptyState(icon: "rectangle.3.group", title: "No profiles yet",
                           subtitle: "Capture the windows you have open now to make your first profile.") {
                    Button("Capture…") { model.beginCapture() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .help("Capture the windows you have open now as a new profile")
                        .accessibilityLabel("Capture profile from open windows")
                }
            case .loaded:
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        if model.isSidebarShown {
                            sidebar.frame(width: CGFloat(storedSidebarWidth.clamped(to: Self.sidebarWidthRange)))
                            sidebarHandle
                        } else {
                            SidebarRailView(model: model)
                            Divider()
                        }
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .onAppear { model.contentWidthChanged(geo.size.width) }
                    .onChange(of: geo.size.width) { _, width in model.contentWidthChanged(width) }
                }
                .sheet(isPresented: $model.isCopyPickerPresented) {
                    StudioCopyPickerSheet(profiles: model.rows, onCopy: { model.beginCopy(of: $0) },
                                          onCancel: { model.isCopyPickerPresented = false })
                }
                .sheet(isPresented: $model.isSaveSheetPresented) {
                    if let builder = model.builder {
                        StudioSaveSheet(builder: builder, onSaved: { model.didSave($0) }, onCancel: { model.cancelSave() })
                    }
                }
                .confirmationDialog("You have unsaved changes", isPresented: $model.isSwitchConfirmPresented, titleVisibility: .visible) {
                    Button("Save…") { model.confirmSwitch(save: true) }
                    Button("Discard Changes", role: .destructive) { model.confirmSwitch(save: false) }
                    Button("Cancel", role: .cancel) { model.cancelSwitch() }
                } message: {
                    Text("Switching profiles throws away what you changed since the last save.")
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
                .help(action.0)
                .accessibilityLabel(action.0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Centred icon, title and one line of help, with the state's action below them.
    private func emptyState<Actions: View>(icon: String, title: String, subtitle: String,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            actions().padding(.top, 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// 1pt divider centred in a 9pt drag area, like the Details split: drag to resize the sidebar.
    private var sidebarHandle: some View {
        Color.clear
            .frame(width: 9)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = sidebarDragStart ?? storedSidebarWidth
                    sidebarDragStart = start
                    storedSidebarWidth = (start + value.translation.width).clamped(to: Self.sidebarWidthRange)
                }
                .onEnded { _ in sidebarDragStart = nil })
            .help("Drag to resize the sidebar")
            .accessibilityElement()
            .accessibilityLabel("Resize sidebar")
            .accessibilityValue("\(Int(storedSidebarWidth.clamped(to: Self.sidebarWidthRange))) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 10 : -10
                storedSidebarWidth = (storedSidebarWidth + step).clamped(to: Self.sidebarWidthRange)
            }
    }

    private var sidebar: some View {
        let selection = Binding<UUID?>(get: { model.selectedID }, set: { model.requestSelect($0) })
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                SidebarToggleButton(model: model)
                Button { model.beginNewProfile() } label: {
                    Label("New profile", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(model.mode == .edit)
                .help("Start a new profile from the current workspace. The chevron has blank, copy and Review capture.")
                NewProfileMenu(model: model, capture: model.capture)
            }
            .padding(.horizontal, 6).padding(.top, 8)
            List(model.rows, selection: selection) { row in
                ProfileStudioRowView(row: row).tag(row.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Profiles")
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
                toolbar(row)
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
            emptyState(icon: "rectangle.3.group", title: "Select a profile",
                       subtitle: "Choose one on the left, or create a new one") {
                Button { model.beginNewProfile() } label: { Label("New profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.mode == .edit)
                    .help("Start a new profile from the current workspace")
                    .accessibilityLabel("New profile")
            }
        }
    }

    /// One compact row: name, mode, compare, preview and Run with its shortcut chip. Falls back to icon-only
    /// buttons, then a shorter name, so it never grows past the pane. Compare / run problems sit in a banner below.
    private func toolbar(_ row: ProfileStudioRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                toolbarRow(row, iconOnly: false, truncating: false)
                toolbarRow(row, iconOnly: true, truncating: false)
                toolbarRow(row, iconOnly: true, truncating: true)
            }
            if let error = model.compareError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                    .accessibilityLabel("Compare problem: \(error)")
            }
            if let app = AppState.current { RunStatusLine(app: app).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func toolbarRow(_ row: ProfileStudioRow, iconOnly: Bool, truncating: Bool) -> some View {
        HStack(spacing: 10) {
            Text(row.name).font(.title3.bold()).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: truncating ? .infinity : nil, alignment: .leading)
                .help(ProfileStudioRowView.subtitle(row))
                .accessibilityLabel("\(row.name), \(ProfileStudioRowView.subtitle(row))")
            Spacer(minLength: 8)
            StudioModePicker(model: model)
            Divider().frame(height: 18)
            Toggle(isOn: Binding(get: { model.isCompareOn }, set: { model.setCompare($0) })) {
                Label("Compare", systemImage: "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
            .keyboardShortcut("l", modifiers: .command)
            .help("Show what is missing now: compare this profile with your Mac (Cmd+L). Only scans: nothing is moved.")
            .accessibilityLabel("Compare with your Mac")
            if model.isComparing {
                ProgressView().controlSize(.small)
            } else if model.isCompareOn, model.compareError == nil {
                Button { model.refreshCompare() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(StudioActionLabelStyle(iconOnly: true))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Compare again (Cmd+R)")
                    .accessibilityLabel("Refresh comparison")
            }
            Divider().frame(height: 18)
            Button { DebugLog.log("studio", "preview restore opened: \(row.name)"); model.isPreviewPresented = true } label: { Label("Preview restore", systemImage: "list.bullet.rectangle") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Preview restore: see what a restore would do, step by step (Cmd+Shift+P)")
                .accessibilityLabel("Preview restore")
            Divider().frame(height: 18)
            if let app = AppState.current {
                StudioRunControl(app: app, profileID: row.id, profileName: row.name, iconOnly: iconOnly)
            }
        }
    }
}

/// Run button (Cmd+Return, so Return on the canvas never runs a profile) with the shortcut chip at its right.
/// The chip opens the recorder popover; it re-reads the stored shortcut when the popover closes.
struct StudioRunControl: View {
    @ObservedObject var app: AppState
    let profileID: UUID
    let profileName: String
    var iconOnly: Bool

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var showEditor = false

    private var isSaved: Bool { app.savedProfiles.contains { $0.id == profileID } }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                DebugLog.log("studio", "run clicked: \(profileName)")
                app.run(id: profileID)
            } label: { Label("Run", systemImage: "play.fill") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.canAct)
                .help((studioRunBlockReason(app) ?? "Restore \(profileName) now") + " (Cmd+Return)")
                .accessibilityLabel("Run profile \(profileName)")
            Button {
                DebugLog.log("studio", "shortcut chip opened: \(profileName)")
                showEditor = true
            } label: {
                Text(shortcut.map { $0.description } ?? "Set shortcut")
                    .font(.callout.monospaced()).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(shortcut == nil ? .tertiary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!isSaved)
            .help(isSaved ? "Run shortcut: click to set or change it" : "Save the profile to set a run shortcut")
            .accessibilityLabel(shortcut.map { "Run shortcut \($0.description), change" } ?? "Set run shortcut")
            .popover(isPresented: $showEditor, arrowEdge: .bottom) {
                ProfileShortcutView(profileID: profileID, profileName: profileName).padding(12).frame(width: 280)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: profileID) { _, _ in reload() }
        .onChange(of: showEditor) { _, _ in reload() }
    }

    private func reload() { shortcut = KeyboardShortcuts.getShortcut(for: .profile(profileID)) }
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
            ProfileMapCanvas(model: map, onSync: { model.setCompare(true); model.refreshCompare() })
            Divider()
            studioBottomBar { MapLegendView(showsStatus: map.status != nil, showsStageStrip: map.usesStageManager) }
        }
    }

    private var inspectorPane: MapInspectorView {
        return MapInspectorView(map: map, plan: model.comparePlan, isCompareOn: model.isCompareOn)
    }

    var body: some View {
        StudioInspectorSplit(sideBySideWidth: Self.sideBySideWidth, minMainWidth: 360) {
            mapPane
        } inspector: {
            inspectorPane
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
    @Published var tab: StudioInspectorTab = ProfileStudioModel.uxInspectorTab ?? .inspector
}

/// Edit mode: header and edit bar, the builder map and the inspector tabs.
struct StudioEditDetail: View {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var builder: ProfileBuilderModel
    @StateObject private var map = ProfileMapModel()
    @StateObject private var local = StudioEditLocalState()
    @State private var bannerDismissed = false

    var body: some View {
        switch builder.phase {
        case .idle:
            // A new profile reads the workspace before there is a draft to show: progress until the map can open.
            VStack(spacing: 14) {
                ProgressView()
                Text("Reading your windows…").font(.headline)
                Text("This can take a few seconds.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .starting:
            ProgressView("Preparing the draft…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Back to View") { model.leaveEdit() }
                    .help("Leave Edit mode and go back to viewing the profile")
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                editToolbar
                Divider()
                if hasBanner { banner; Divider() }
                StudioInspectorSplit(sideBySideWidth: Self.sideBySideWidth, minMainWidth: 480) {
                    libraryAndMap
                } inspector: {
                    inspector
                }
            }
        }
    }

    /// Map 320 + inspector 260 + dividers: below this the inspector moves under the map.
    private static let sideBySideWidth: CGFloat = 1100

    private var libraryAndMap: some View {
        VStack(spacing: 0) {
            BuilderMapCanvas(map: map, builder: builder)
                .onAppear { builder.mapModel = map }
            Divider()
            studioBottomBar { MapLegendView(showsStatus: false) }
        }
        .frame(minWidth: 320)
    }

    /// One compact row: name, mode, Undo / Redo, draft status, Add App, Cancel and Save.
    private var editToolbar: some View {
        ViewThatFits(in: .horizontal) {
            editRow(iconOnly: false, truncating: false)
            editRow(iconOnly: true, truncating: false)
            editRow(iconOnly: true, truncating: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func editRow(iconOnly: Bool, truncating: Bool) -> some View {
        let title = builder.nameText.isEmpty ? "Untitled profile" : builder.nameText
        return HStack(spacing: 10) {
            ProfileIconPicker(current: (builder.profile?.icon ?? "").isEmpty ? Profile.defaultIcon : builder.profile!.icon) { builder.setIcon($0) }
            TextField("Profile name", text: Binding(get: { builder.nameText }, set: { builder.setName($0) }))
                .textFieldStyle(.plain).font(.title3.bold()).lineLimit(1)
                .frame(minWidth: 120, maxWidth: truncating ? .infinity : 260, alignment: .leading)
                .help(builder.isNewProfile ? "New profile (not saved yet). Edit the name here." : "Editing a saved profile. Edit the name here.")
                .accessibilityLabel("Profile name, \(title)")
            Spacer(minLength: 8)
            StudioModePicker(model: model)
            Divider().frame(height: 18)
            Button { builder.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .labelStyle(StudioActionLabelStyle(iconOnly: true))
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!builder.canUndo)
                .help("Undo the last change (Cmd+Z)")
                .accessibilityLabel("Undo")
            Button { builder.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .labelStyle(StudioActionLabelStyle(iconOnly: true))
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!builder.canRedo)
                .help("Redo (Shift+Cmd+Z)")
                .accessibilityLabel("Redo")
            Toggle(isOn: Binding(get: { builder.isLive }, set: { builder.setLive($0) })) {
                Label("Live", systemImage: builder.isLive ? "circle.fill" : "circle")
            }
            .toggleStyle(.button)
            .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
            .help("Keep the draft in sync with your real windows (updates every 2 s)")
            .accessibilityLabel("Live sync")
            if !iconOnly {
                Text(statusText)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(builder.errorCount > 0 ? Color.red : (builder.warningCount > 0 ? Color.orange : Color.secondary))
                    .accessibilityLabel("Draft check: \(statusText)")
            } else if builder.errorCount > 0 || builder.warningCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(builder.errorCount > 0 ? Color.red : Color.orange)
                    .help(statusText).accessibilityLabel("Draft check: \(statusText)")
            }
            Divider().frame(height: 18)
            Button { model.isAddAppPresented = true } label: { Label("Add App", systemImage: "plus") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Add an app to the profile (Shift+Cmd+A)")
                .accessibilityLabel("Add App")
                .popover(isPresented: $model.isAddAppPresented, arrowEdge: .bottom) {
                    AppLibraryView(builder: builder, onClose: { model.isAddAppPresented = false })
                }
            Button { model.requestLeaveEdit() } label: { Label("Cancel", systemImage: "xmark") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .help("Leave Edit mode, asking first if there are unsaved changes")
                .accessibilityLabel("Cancel editing")
            Button { model.saveThen(nil) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(builder.blocksSaving)
                .help(builder.blocksSaving ? "Fix the problems marked in red first" : "Save the profile (Cmd+S)")
                .accessibilityLabel("Save profile")
        }
    }

    private var hasBanner: Bool {
        guard !bannerDismissed else { return false }
        return builder.lastError != nil || !builder.startNotes.isEmpty
    }

    /// Start notes and the last error on one dismissible line, so the toolbar never grows.
    private var banner: some View {
        let isError = builder.lastError != nil
        let text = builder.lastError ?? builder.startNotes.joined(separator: " ")
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Color.secondary)
            Text(text).font(.callout).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(isError ? Color.orange : Color.secondary)
                .help(text)
            Spacer(minLength: 8)
            Button { bannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isError ? "Problem: \(text)" : "Note: \(text)")
        .onChange(of: text) { _, _ in bannerDismissed = false }
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
            // Equal-width segments that share the panel width and shrink their text instead of
            // overflowing, so the bar never clips at the inspector's minimum width.
            HStack(spacing: 2) {
                ForEach(StudioInspectorTab.allCases) { tab in
                    let selected = local.tab == tab
                    Button { local.tab = tab } label: {
                        Text(tab.rawValue)
                            .font(.callout)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(tab.rawValue)
                }
            }
            .padding(3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .help("Switch between the Inspector, Options and Launch order tabs")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Inspector tab")
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

private extension Double {
    /// Keeps a remembered sidebar width inside its allowed range.
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
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
            Image(systemName: row.icon).frame(width: 22).foregroundStyle(ProfileRowTint.color(for: row.id)).accessibilityHidden(true)
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
