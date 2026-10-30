import KeyboardShortcuts
import SwiftUI
import WMCore

/// Profile Studio shell: unified window toolbar, a NavigationSplitView (profile sidebar | map) and a Details inspector.
struct ProfileStudioView: View {
    @ObservedObject var model: ProfileStudioModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading profiles…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Banner(tone: .danger, title: "Could not load profiles", message: message,
                       actionLabel: "Try Again", action: { model.reload() })
                    .frame(maxWidth: 480)
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty where model.mode == .view:
                noProfiles
            case .loaded, .empty:
                splitView
            }
        }
        .frame(minWidth: ProfileStudioWindowController.minSize.width, minHeight: ProfileStudioWindowController.minSize.height)
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .onAppear { model.reload() }
    }

    private var noProfiles: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: "rectangle.3.group")
        } description: {
            Text("Capture the windows you have open now, or start a new profile and arrange it yourself.")
            if AppState.current?.isAccessibilityTrusted == false {
                Text("Capture needs Accessibility permission: allow it in System Settings > Privacy & Security > Accessibility.")
                    .foregroundStyle(Tone.warning.color)
            }
        } actions: {
            Button { model.beginCapture() } label: { Label("Capture Current Desktop", systemImage: "camera.viewfinder") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help("Capture the windows you have open now as a new profile")
                .accessibilityLabel("Capture current desktop as a profile")
            Button { model.beginNewProfile() } label: { Label("New Profile", systemImage: "plus") }
                .controlSize(.large)
                .help("Start a new profile from the current workspace, as an editable draft")
                .accessibilityLabel("New profile")
        }
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.isSidebarShown ? .all : .detailOnly },
                set: { model.setSidebar(shown: $0 != .detailOnly) })
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } detail: {
            detail
        }
        .toolbar { StudioToolbar(model: model) }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.contentWidthChanged($0) }
        .sheet(isPresented: $model.isCopyPickerPresented) {
            StudioCopyPickerSheet(profiles: model.rows, onCopy: { model.beginCopy(of: $0) },
                                  onCancel: { model.isCopyPickerPresented = false })
        }
        .sheet(isPresented: $model.isReviewCapturePresented) {
            if let builder = model.builder {
                CaptureReviewPanel(capture: model.capture, builder: builder, onDone: { model.isReviewCapturePresented = false })
            }
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
        .confirmationDialog("Delete this profile?", isPresented: Binding(get: { model.deleteTarget != nil },
                                                                           set: { if !$0 { model.deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: model.deleteTarget) { row in
            Button("Delete \u{201C}\(row.name)\u{201D}", role: .destructive) { model.deleteTarget = row; model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleteTarget = nil }
        } message: { _ in
            Text("It moves to the Trash folder. You can undo right after.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { model.renameTarget != nil },
                                                      set: { if !$0 { model.renameTarget = nil } }),
               presenting: model.renameTarget) { row in
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.renameTarget = row; model.commitRename() }
            Button("Cancel", role: .cancel) { model.renameTarget = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let selection = Binding<UUID?>(get: { model.selectedID }, set: { model.requestSelect($0) })
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { model.beginNewProfile() } label: {
                    Label("New profile", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Start a new profile from the current workspace. The chevron has blank, copy and Review capture.")
                NewProfileMenu(model: model, capture: model.capture)
            }
            .padding(.horizontal, Spacing.s).padding(.top, Spacing.xs)
            if let notice = model.newProfileNotice {
                Banner(tone: .warning, title: notice, onDismiss: { model.newProfileNotice = nil })
                    .padding(.horizontal, Spacing.s).padding(.top, Spacing.xs)
                    .accessibilityIdentifier("newProfileNotice")
            }
            List(model.rows, selection: selection) { row in
                ProfileStudioRowView(row: row).tag(row.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .contextMenu { rowMenu(row) }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Profiles")
            .onDeleteCommand { if let row = model.selectedRow { model.requestDelete(row) } }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "rectangle.3.group")
                    } actions: {
                        Button("New Profile") { model.beginNewProfile() }
                    }
                }
            }
            if !model.skipped.isEmpty {
                Text("Could not read: \(model.skipped.joined(separator: ", "))")
                    .font(.wmCaption).foregroundStyle(.secondary)
                    .padding(Spacing.s).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ row: ProfileStudioRow) -> some View {
        Button("Run") { model.run(row: row) }
            .disabled(AppState.current?.canAct != true || model.mode == .edit)
        Divider()
        Button("Rename…") { model.beginRename(row) }.disabled(!model.canChangeRows)
        Button("Duplicate") { model.duplicate(row) }.disabled(!model.canChangeRows)
        Button("Export…") { model.export(row) }
        Divider()
        Button("Delete…", role: .destructive) { model.requestDelete(row) }.disabled(!model.canChangeRows)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let message = model.actionError {
                Banner(tone: .danger, title: "That did not work", message: message, onDismiss: { model.actionError = nil })
                    .padding(Spacing.s)
            }
            if let name = model.deletedName {
                Banner(tone: .info, title: "Deleted \u{201C}\(name)\u{201D}", actionLabel: "Undo",
                       action: { model.undoDelete() }, onDismiss: { model.clearDeleted() })
                    .padding(Spacing.s)
            }
            detailContent
        }
    }

    @ViewBuilder private var detailContent: some View {
        if model.mode == .edit, let builder = model.builder {
            StudioEditDetail(model: model, builder: builder)
                .id(ObjectIdentifier(builder))
        } else if let row = model.selectedRow {
            StudioMapHost(row: row, model: model)
                .sheet(isPresented: $model.isPreviewPresented) {
                    RestorePreviewSheet(profileID: row.id, profileName: row.name, scope: model.previewScope) { model.isPreviewPresented = false }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                    // The Studio window coming back to the front: refresh the comparison (never polls).
                    if (note.object as? NSWindow)?.isKeyWindow == true, !model.isPreviewPresented { model.refreshCompare() }
                }
        } else {
            ContentUnavailableView {
                Label("Select a Profile", systemImage: "rectangle.3.group")
            } description: {
                Text("Choose one on the left, or create a new one.")
            } actions: {
                Button { model.beginNewProfile() } label: { Label("New Profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .help("Start a new profile from the current workspace")
                    .accessibilityLabel("New profile")
            }
        }
    }
}

/// The unified window toolbar. Centre: View / Edit. Trailing: Compare, Preview, Run in View mode;
/// Undo, Redo, Live, Add App, Cancel and Save in Edit mode; the Details toggle in both.
struct StudioToolbar: ToolbarContent {
    @ObservedObject var model: ProfileStudioModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StudioModePicker(model: model)
        }
        if model.mode == .edit, let builder = model.builder {
            StudioEditToolbar(model: model, builder: builder)
        } else if let row = model.selectedRow {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { model.isCompareOn }, set: { model.setCompare($0) })) {
                    Label("Compare", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Compare: check this profile against the windows on your Mac now and mark what is missing or moved (Cmd+L). Only scans: nothing is moved.")
                .accessibilityLabel("Compare with your Mac")
                if model.isComparing {
                    ProgressView().controlSize(.small)
                } else if model.isCompareOn, model.compareError == nil {
                    Button { model.refreshCompare() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Compare again (Cmd+R)")
                        .accessibilityLabel("Refresh comparison")
                }
                Button { DebugLog.log("studio", "preview restore opened: \(row.name)"); model.previewScope = .whole; model.isPreviewPresented = true } label: { Label("Preview", systemImage: "list.bullet.rectangle") }
                    .help("Preview restore: see what a restore would do, step by step (Shift+Cmd+P)")
                    .accessibilityLabel("Preview restore")
            }
            ToolbarItem(placement: .primaryAction) {
                if let app = AppState.current {
                    StudioRunControl(app: app, profileID: row.id, profileName: row.name, iconOnly: false,
                                     showEditor: $model.isShortcutEditorPresented)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.isInspectorShown.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help(model.isInspectorShown ? "Hide the Details inspector" : "Show the Details inspector")
                .accessibilityLabel(model.isInspectorShown ? "Hide details" : "Show details")
        }
    }
}

/// Edit-mode toolbar items. Undo / Redo / Save shortcuts live in the app menu.
struct StudioEditToolbar: ToolbarContent {
    @ObservedObject var model: ProfileStudioModel
    @ObservedObject var builder: ProfileBuilderModel

    private var statusText: String {
        let e = builder.errorCount, w = builder.warningCount
        if e == 0 && w == 0 { return "No problems" }
        var parts: [String] = []
        if e > 0 { parts.append("\(e) problem\(e == 1 ? "" : "s")") }
        if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { builder.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo the last change (Cmd+Z)")
                .accessibilityLabel("Undo")
            Button { builder.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo (Shift+Cmd+Z)")
                .accessibilityLabel("Redo")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { builder.isLive }, set: { builder.setLive($0) })) {
                Label(builder.isLive ? "Live: on" : "Live: off", systemImage: builder.isLive ? "circle.fill" : "circle")
            }
            .help("Live: the draft follows your real windows and updates every 2 s. Off: the draft changes only when you edit it.")
            .accessibilityLabel("Live sync")
        }
        ToolbarItem(placement: .primaryAction) {
            Text(statusText)
                .font(.wmCaption).lineLimit(1)
                .foregroundStyle(builder.errorCount > 0 ? Tone.danger.color : (builder.warningCount > 0 ? Tone.warning.color : Color.secondary))
                .accessibilityLabel("Draft check: \(statusText)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.isAddAppPresented = true } label: { Label("Add App", systemImage: "plus") }
                .help("Add an app to the profile (Shift+Cmd+A)")
                .accessibilityLabel("Add App")
                .popover(isPresented: $model.isAddAppPresented, arrowEdge: .bottom) {
                    AppLibraryView(builder: builder, onClose: { model.isAddAppPresented = false })
                }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Cancel") { model.requestLeaveEdit() }
                .help("Leave Edit mode. With unsaved changes you are asked to save, discard them, or keep editing.")
                .accessibilityLabel("Cancel editing")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Save") { model.saveThen(nil) }
                .buttonStyle(.borderedProminent)
                .disabled(builder.blocksSaving)
                .help(builder.blocksSaving ? "Fix the problems marked in red first" : "Save the profile (Cmd+S)")
                .accessibilityLabel("Save profile")
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
    @Binding var showEditor: Bool

    private var isSaved: Bool { app.savedProfiles.contains { $0.id == profileID } }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                DebugLog.log("studio", "run clicked: \(profileName)")
                app.run(id: profileID)
            } label: { Label("Run", systemImage: "play.fill") }
                .labelStyle(StudioActionLabelStyle(iconOnly: iconOnly))
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!app.canAct)
                .help((studioRunBlockReason(app) ?? "Restore \(profileName) now") + " (Cmd+Return)")
                .accessibilityLabel("Run profile \(profileName)")
            Button {
                DebugLog.log("studio", "shortcut chip opened: \(profileName)")
                showEditor = true
            } label: {
                if let shortcut {
                    Text(shortcut.description).font(.callout.monospaced()).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                } else if isSaved {
                    // Enabled and obviously clickable: accent colour, keyboard icon, outline.
                    Label("Set shortcut", systemImage: "keyboard").font(.callout).lineLimit(1)
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.blue.opacity(0.7), lineWidth: 1))
                } else {
                    // Not saved yet: say why in the label itself instead of only dimming it.
                    Label("Save to set shortcut", systemImage: "keyboard").font(.callout).lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSaved)
            .help(isSaved ? "Run shortcut: click to set or change it" : "A run shortcut belongs to a saved profile. Save this profile first, then set a shortcut here.")
            .accessibilityLabel(shortcut.map { "Run shortcut \($0.description), change" } ?? (isSaved ? "Set run shortcut" : "Run shortcut: save the profile first"))
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

    private var mapPane: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            if let error = model.compareError {
                Banner(tone: .danger, title: "Compare problem", message: error).padding(Spacing.s)
            }
            ProfileMapCanvas(model: map, onSync: { model.setCompare(true); model.refreshCompare() })
            Divider()
            studioBottomBar {
                HStack(spacing: Spacing.m) {
                    MapLegendView(showsStatus: map.status != nil, showsStageStrip: map.usesStageManager)
                    if let app = AppState.current { RunStatusLine(app: app).lineLimit(1) }
                }
            }
        }
    }

    /// The monitor the map focuses, and the Desktop it shows there (nil for a full-screen Space).
    private var focusedScope: (monitor: RestoreScope, desktop: RestoreScope?, monitorName: String)? {
        guard let uuid = map.focusedDisplayUUID, let profile = map.profile else { return nil }
        let name = profile.displays.first { $0.uuid == uuid }?.name ?? uuid
        var desktop: RestoreScope?
        if let space = map.shownSpace(onDisplay: uuid), space.kind == .desktop, let n = space.desktopNumber {
            desktop = RestoreScope(desktops: [SpaceRef(displayUUID: uuid, desktopNumber: n)])
        }
        return (RestoreScope(displays: [uuid]), desktop, name)
    }

    private var scopeBar: some View {
        let focus = focusedScope
        return HStack(spacing: 8) {
            Button {
                if let scope = focus?.desktop { model.previewScope = scope; model.isPreviewPresented = true }
            } label: { Label("Apply this desktop only", systemImage: "rectangle.on.rectangle") }
                .disabled(focus?.desktop == nil)
                .help(focus?.desktop == nil ? "The shown Space is not a Desktop" : "Preview and apply only the Desktop shown on \(focus?.monitorName ?? "this monitor")")
            Button {
                if let scope = focus?.monitor { model.previewScope = scope; model.isPreviewPresented = true }
            } label: { Label("Apply this monitor only", systemImage: "display") }
                .disabled(focus == nil)
                .help("Preview and apply only \(focus?.monitorName ?? "the focused monitor")")
            Spacer()
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    var body: some View {
        mapPane
            .inspector(isPresented: $model.isInspectorShown) {
                MapInspectorView(map: map, plan: model.comparePlan, isCompareOn: model.isCompareOn)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .task(id: row) { map.load(try? AppState.current?.store.load(row.id)) }
            .onChange(of: model.liveStatus) { _, newValue in map.status = newValue }
            .onAppear { map.status = model.liveStatus; model.activeMap = map }
    }
}

/// Legend on the left, the Debug log switch at the right end.
@MainActor @ViewBuilder
func studioBottomBar<Legend: View>(@ViewBuilder _ legend: () -> Legend) -> some View {
    HStack(spacing: 12) {
        legend()
        Spacer(minLength: 8)
        // The debug switch lives in a small debug menu, out of the everyday footer.
        Menu { DebugLogToggle() } label: { Label("Debug", systemImage: "ant").labelStyle(.titleAndIcon).font(.caption) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Debug options")
            .accessibilityLabel("Debug options")
            .padding(.trailing, 12)
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

/// Equal-width segments that share the panel width and shrink their text instead of overflowing.
struct StudioInspectorTabBar: View {
    let tabs: [StudioInspectorTab]
    @Binding var selection: StudioInspectorTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
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
        .help(tabs.count > 1 ? "Switch between the Inspector, Options and Launch order tabs" : "Details of the selected window")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tab")
        .padding(8)
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
            Banner(tone: .danger, title: "Could not open the draft", message: message,
                   actionLabel: "Back to View", action: { model.leaveEdit() })
                .frame(maxWidth: 480)
                .padding(Spacing.l).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                headerRow
                Divider()
                if hasBanner { banner }
                libraryAndMap
            }
            .inspector(isPresented: $model.isInspectorShown) {
                inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .onChange(of: builder.isDirty) { _, _ in model.titleChanged() }
            .onChange(of: builder.nameText) { _, _ in model.titleChanged() }
        }
    }

    private var libraryAndMap: some View {
        VStack(spacing: 0) {
            BuilderMapCanvas(map: map, builder: builder)
                .onAppear { builder.mapModel = map; model.activeMap = map }
            Divider()
            studioBottomBar { MapLegendView(showsStatus: false) }
        }
        .frame(minWidth: 320)
    }

    /// Icon and name stay here: a text field has no toolbar home. Everything else is in the window toolbar.
    private var headerRow: some View {
        let title = builder.nameText.isEmpty ? "Untitled profile" : builder.nameText
        return HStack(spacing: Spacing.s) {
            ProfileIconPicker(current: (builder.profile?.icon ?? "").isEmpty ? Profile.defaultIcon : builder.profile!.icon) { builder.setIcon($0) }
            TextField("Profile name", text: Binding(get: { builder.nameText }, set: { builder.setName($0) }))
                .textFieldStyle(.plain).font(.wmTitle).lineLimit(1)
                .frame(maxWidth: 320, alignment: .leading)
                .help(builder.isNewProfile ? "New profile (not saved yet). Edit the name here." : "Editing a saved profile. Edit the name here.")
                .accessibilityLabel("Profile name, \(title)")
            if builder.isDirty { StatusBadge(tone: .warning, text: "Unsaved") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
    }

    private var hasBanner: Bool {
        guard !bannerDismissed else { return false }
        return builder.lastError != nil || !builder.startNotes.isEmpty
    }

    /// Start notes and the last error, dismissible.
    private var banner: some View {
        let isError = builder.lastError != nil
        let text = builder.lastError ?? builder.startNotes.map { "\u{2022} " + $0 }.joined(separator: "\n")
        return Banner(tone: isError ? .danger : .info, title: isError ? "Problem" : "Note", message: text,
                      onDismiss: { bannerDismissed = true })
            .padding(Spacing.s)
            .onChange(of: text) { _, _ in bannerDismissed = false }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            StudioInspectorTabBar(tabs: StudioInspectorTab.allCases, selection: $local.tab)
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
