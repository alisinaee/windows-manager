import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WMCore

/// Edit state for the Profiles tab. Lives in a class because the build avoids `@State`.
@MainActor
final class ProfilesSettingsModel: ObservableObject {
    @Published var selection: UUID?
    @Published var nameText = ""
    @Published var message = ""
    @Published var confirmingDelete = false

    func select(_ id: UUID?, store: ProfileStore) {
        selection = id
        message = ""
        guard let id, let profile = try? store.load(id) else {
            nameText = ""
            return
        }
        nameText = profile.name
    }
}

struct ProfilesSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ProfilesSettingsModel()

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                list
                detail
            }
            HStack {
                Button("Import…") { importProfile() }
                Spacer()
                Text(model.message).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding()
        .onAppear { appState.reloadProfiles() }
    }

    private var list: some View {
        let selection = Binding<UUID?>(get: { model.selection }, set: { model.select($0, store: appState.store) })
        return Group {
            if appState.savedProfiles.isEmpty {
                Text("No saved profiles yet. Capture one from the menu bar.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.savedProfiles, selection: selection) { item in
                    HStack {
                        Image(systemName: item.icon.isEmpty ? "rectangle.3.group" : item.icon)
                        Text(item.name)
                        Spacer()
                        Text("\(item.windowCount)").foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selection {
            Form {
                TextField("Name", text: $model.nameText)
                    .onSubmit { rename(id) }
                Button("Rename") { rename(id) }
                Text("Set hotkeys in the Hotkeys tab.")
                    .foregroundStyle(.secondary)
                Section {
                    HStack {
                        Button("Duplicate") { duplicate(id) }
                        Button("Export…") { export(id) }
                        Button("Delete…", role: .destructive) { model.confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Move this profile to the Trash folder?", isPresented: $model.confirmingDelete) {
                Button("Delete", role: .destructive) { delete(id) }
            }
        } else {
            Text("Select a profile")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func fail(_ error: Error) {
        model.message = error.localizedDescription
    }

    private func rename(_ id: UUID) {
        do {
            try appState.store.rename(id, to: model.nameText)
            appState.reloadProfiles()
            model.message = "Renamed."
        } catch { fail(error) }
    }

    private func duplicate(_ id: UUID) {
        do {
            let copy = try appState.store.duplicate(id)
            appState.reloadProfiles()
            model.select(copy.id, store: appState.store)
            model.message = "Duplicated."
        } catch { fail(error) }
    }

    private func delete(_ id: UUID) {
        do {
            try appState.store.delete(id)
            appState.reloadProfiles()
            model.select(nil, store: appState.store)
            model.message = "Moved to Trash."
        } catch { fail(error) }
    }

    private func export(_ id: UUID) {
        do {
            let profile = try appState.store.load(id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(profile.name).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ProfileTransfer.export(profile).write(to: url, options: .atomic)
            model.message = "Exported to \(url.lastPathComponent)."
        } catch { fail(error) }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let profile = try ProfileTransfer.importProfile(data, existingNames: appState.savedProfiles.map(\.name),
                                                            source: url.lastPathComponent)
            let saved = try appState.store.save(profile)
            appState.reloadProfiles()
            model.select(saved.id, store: appState.store)
            model.message = "Imported \(saved.name)."
        } catch { fail(error) }
    }
}
