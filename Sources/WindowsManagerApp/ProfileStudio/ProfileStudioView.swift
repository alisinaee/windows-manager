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
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    VStack(spacing: 6) {
                        Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("Map canvas arrives with UI2").font(.headline).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Map canvas placeholder. The map arrives with UI2.")
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
            Button { model.runSelected() } label: { Label("Run", systemImage: "play.fill") }
                .keyboardShortcut(.defaultAction)
                .disabled(!(AppState.current?.canAct ?? false))
                .accessibilityLabel("Run profile \(row.name)")
        }
        .padding(16)
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
