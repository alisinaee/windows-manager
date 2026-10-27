import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WMCore

/// What a library row carries while it is dragged onto the map.
struct LibraryDragPayload: Codable, Transferable, Equatable {
    var bundleID: String
    var name: String
    var path: String?

    var appRef: AppRef { AppRef(bundleID: bundleID, name: name, path: path) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Local UI state of the library (the row with the keyboard focus).
@MainActor
final class AppLibraryUIModel: ObservableObject {
    @Published var selection: String?
}

/// Content of the Add App popover: target Desktop, search, Running / Installed / Added to this profile.
/// Return adds the highlighted app and the popover stays open so several apps can be added in a row.
struct AppLibraryView: View {
    @ObservedObject var builder: ProfileBuilderModel
    /// Closes the popover (Esc).
    var onClose: () -> Void = {}
    @StateObject private var ui = AppLibraryUIModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            targetPicker
            TextField("Search apps", text: $builder.librarySearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8).padding(.bottom, 8)
                .focused($searchFocused)
                .onSubmit { addHighlighted() }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityLabel("Search apps")
                .help("Type to filter. Up / Down choose an app, Return adds it to the chosen Desktop, Esc closes")
            Divider()
            if builder.isLoadingLibrary && builder.library.isEmpty {
                ProgressView("Reading installed apps").padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App library")
        .onAppear {
            searchFocused = true
            if ui.selection == nil { ui.selection = flatKeys.first }
            DebugLog.log("studio", "add-app popover opened (\(builder.library.count) apps)")
        }
        .onChange(of: builder.librarySearch) { _, _ in ui.selection = flatKeys.first }
    }

    /// "Add to: Desktop N · monitor" as a menu over every Desktop of the profile.
    private var targetPicker: some View {
        let options = targetOptions
        let current = target().map { "\($0.display)|\($0.desktop)" } ?? ""
        return HStack(spacing: 6) {
            Text("Add to").foregroundStyle(.secondary)
            Picker("Add to", selection: Binding(
                get: { current },
                set: { value in
                    let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let n = Int(parts[1]) else { return }
                    builder.selectedDisplayUUID = parts[0]
                    builder.selectedDesktop = n
                })) {
                ForEach(options, id: \.id) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .disabled(options.isEmpty)
            .help("The Desktop new apps are added to")
            .accessibilityLabel("Add to Desktop")
        }
        .padding(8)
    }

    private var targetOptions: [(id: String, title: String)] {
        guard let profile = builder.profile else { return [] }
        return profile.displays.flatMap { display in
            desktopNumbers(of: display.uuid, in: profile).map { (id: "\(display.uuid)|\($0)", title: "Desktop \($0) · \(display.name)") }
        }
    }

    /// Keyboard order: the rows that can be added (Running, then Installed).
    private var flatKeys: [String] { (builder.runningLibrary + builder.installedLibrary).map { "lib:" + $0.bundleID } }

    private func moveSelection(_ delta: Int) {
        let keys = flatKeys
        guard !keys.isEmpty else { return }
        let index = ui.selection.flatMap { keys.firstIndex(of: $0) } ?? (delta > 0 ? -1 : keys.count)
        ui.selection = keys[min(max(index + delta, 0), keys.count - 1)]
    }

    private func addHighlighted() {
        guard let key = ui.selection, let entry = builder.library.first(where: { "lib:" + $0.bundleID == key }) else { return }
        place(entry)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            listBody.onChange(of: ui.selection) { _, key in
                if let key { proxy.scrollTo(key) }
            }
        }
    }

    private var listBody: some View {
        List(selection: $ui.selection) {
            if !builder.runningLibrary.isEmpty {
                Section("Running") {
                    ForEach(builder.runningLibrary, id: \.bundleID) { row(for: $0) }
                }
            }
            if !builder.installedLibrary.isEmpty {
                Section("Installed") {
                    ForEach(builder.installedLibrary, id: \.bundleID) { row(for: $0) }
                }
            }
            let added = filteredAdded
            if !added.isEmpty {
                Section("Added to this profile") {
                    ForEach(added, id: \.key) { item in
                        AddedAppRow(app: item.app, windowCount: item.windows)
                            .tag("added:" + item.key)
                    }
                }
            }
            if builder.runningLibrary.isEmpty, builder.installedLibrary.isEmpty, added.isEmpty {
                Text(builder.librarySearch.isEmpty ? "No apps found." : "No app matches the search.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            guard ui.selection != nil else { return .ignored }
            addHighlighted()
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(for entry: LibraryEntry) -> some View {
        let payload = LibraryDragPayload(bundleID: entry.bundleID, name: entry.name, path: entry.url?.path)
        return LibraryRow(entry: entry, canPlace: canPlace, onAdd: { place(entry) })
            .tag("lib:" + entry.bundleID)
            .id("lib:" + entry.bundleID)
            .draggable(payload) {
                HStack(spacing: 6) {
                    Image(nsImage: AppIconCache.icon(for: builder.appRef(for: entry))).resizable().frame(width: 20, height: 20)
                    Text(entry.name)
                }
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .contextMenu { contextMenu(for: entry) }
    }

    @ViewBuilder private func contextMenu(for entry: LibraryEntry) -> some View {
        Button("Add to the chosen Desktop") { place(entry) }.disabled(!canPlace)
            .help("Add \(entry.name) to the Desktop chosen above")
        if let profile = builder.profile {
            Menu("Add to") {
                ForEach(profile.displays, id: \.uuid) { display in
                    Menu(display.name) {
                        ForEach(desktopNumbers(of: display.uuid, in: profile), id: \.self) { number in
                            Button("Desktop \(number)") { place(entry, display: display.uuid, desktop: number) }
                                .help("Add \(entry.name) to Desktop \(number) on \(display.name)")
                        }
                    }
                }
            }
            .help("Choose the Desktop to add \(entry.name) to")
        }
        Divider()
        Button("Launch only, no window") {
            DebugLog.log("studio", "add-app popover: \(entry.name) added as launch only")
            builder.addLaunchOnly(app: builder.appRef(for: entry))
        }
        .help("Add \(entry.name) to the launch order without placing a window")
    }

    private var footer: some View {
        HStack {
            Button { addFromDisk() } label: { Label("Add app from disk…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .help("Choose an .app bundle that is not in the list")
            Spacer()
            Button { Task { await builder.loadLibrary(forceRescan: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rescan installed apps").help("Rescan installed apps")
        }
        .padding(8)
    }

    // MARK: Actions

    private var canPlace: Bool { target() != nil }

    /// The Desktop the keyboard path adds to: the selected one, else the first Desktop of the first monitor.
    private func target() -> (display: String, desktop: Int)? {
        guard let profile = builder.profile else { return nil }
        if let display = builder.selectedDisplayUUID, let n = builder.selectedDesktop,
           desktopNumbers(of: display, in: profile).contains(n) {
            return (display, n)
        }
        for display in profile.displays {
            if let n = desktopNumbers(of: display.uuid, in: profile).first { return (display.uuid, n) }
        }
        return nil
    }

    private func desktopNumbers(of display: String, in profile: Profile) -> [Int] {
        profile.spaces.filter { $0.displayUUID == display && $0.kind == .desktop }.compactMap(\.desktopNumber).sorted()
    }

    private func place(_ entry: LibraryEntry, display: String? = nil, desktop: Int? = nil) {
        guard let spot = display.flatMap({ d in desktop.map { (d, $0) } }) ?? target().map({ ($0.display, $0.desktop) })
        else { return }
        DebugLog.log("studio", "add-app popover: \(entry.name) added to Desktop \(spot.1)")
        builder.addWindow(app: builder.appRef(for: entry), onDisplay: spot.0, desktop: spot.1)
    }

    private func addFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose an app to add to the library"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let entry = builder.addAppBundle(at: url) { ui.selection = "lib:" + entry.bundleID }
    }

    // MARK: Added apps

    private struct AddedItem { var key: String; var app: AppRef; var windows: Int }

    private var filteredAdded: [AddedItem] {
        let q = builder.librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = builder.profile?.windows ?? []
        return builder.appsInProfile.compactMap { app in
            if !q.isEmpty, !app.name.localizedCaseInsensitiveContains(q),
               !(app.bundleID ?? "").localizedCaseInsensitiveContains(q) { return nil }
            let key = app.bundleID ?? app.name
            let count = windows.filter { ($0.app.bundleID ?? $0.app.name) == key }.count
            return AddedItem(key: key, app: app, windows: count)
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let canPlace: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconCache.icon(for: AppRef(bundleID: entry.bundleID, name: entry.name, path: entry.url?.path)))
                .resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            Text(entry.name).lineLimit(1)
            if entry.isRunning {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            Button(action: onAdd) { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .disabled(!canPlace)
                .accessibilityLabel("Add \(entry.name) to the chosen Desktop")
                .help("Add to the Desktop chosen above (or drag onto the map)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Press Return to add it to the chosen Desktop, or drag it onto the map.")
        .accessibilityValue(entry.isRunning ? "running" : "")
    }
}

private struct AddedAppRow: View {
    let app: AppRef
    let windowCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconCache.icon(for: app)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            Text(app.name).lineLimit(1)
            Spacer(minLength: 4)
            Text(windowCount == 0 ? "no window" : "\(windowCount) window\(windowCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
