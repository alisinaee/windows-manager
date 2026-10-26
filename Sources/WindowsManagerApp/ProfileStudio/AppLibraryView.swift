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

/// Left panel of Edit mode: search, Running / Installed / Added to this profile, with drag and an Add button.
struct AppLibraryView: View {
    @ObservedObject var builder: ProfileBuilderModel
    @StateObject private var ui = AppLibraryUIModel()

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $builder.librarySearch)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .accessibilityLabel("Search apps")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App library")
    }

    private var list: some View {
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
            guard let key = ui.selection, let entry = builder.library.first(where: { "lib:" + $0.bundleID == key })
            else { return .ignored }
            place(entry)
            return .handled
        }
    }

    private func row(for entry: LibraryEntry) -> some View {
        let payload = LibraryDragPayload(bundleID: entry.bundleID, name: entry.name, path: entry.url?.path)
        return LibraryRow(entry: entry, canPlace: canPlace, onAdd: { place(entry) })
            .tag("lib:" + entry.bundleID)
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
        Button("Add to the selected Desktop") { place(entry) }.disabled(!canPlace)
        if let profile = builder.profile {
            Menu("Add to") {
                ForEach(profile.displays, id: \.uuid) { display in
                    Menu(display.name) {
                        ForEach(desktopNumbers(of: display.uuid, in: profile), id: \.self) { number in
                            Button("Desktop \(number)") { place(entry, display: display.uuid, desktop: number) }
                        }
                    }
                }
            }
        }
        Divider()
        Button("Launch only, no window") { builder.addLaunchOnly(app: builder.appRef(for: entry)) }
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
                .accessibilityLabel("Add \(entry.name) to the selected Desktop")
                .help("Add to the selected Desktop (or drag onto the map)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Press Return to add it to the selected Desktop, or drag it onto the map.")
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
