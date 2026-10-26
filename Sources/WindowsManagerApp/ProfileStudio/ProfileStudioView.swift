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
            if !model.skipped.isEmpty {
                Text("Could not read: \(model.skipped.joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = model.selectedRow {
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
            Button { model.mode = .edit } label: { Label("Edit", systemImage: "pencil") }
                .disabled(true)
                .help("Editing arrives with the Builder")
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
