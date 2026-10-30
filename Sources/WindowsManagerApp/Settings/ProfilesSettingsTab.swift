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
    /// Set for a few seconds after a delete so the user can undo it.
    @Published var deletedName: String?
    var deletedProfile: Profile?
    var dismissTask: Task<Void, Never>?

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
    @Environment(\.undoManager) private var undoManager
    @StateObject private var model = ProfilesSettingsModel()

    var body: some View {
        VStack(spacing: 10) {
            if let name = model.deletedName {
                Banner(tone: .info, title: "Deleted \(name)", actionLabel: "Undo",
                       action: { undoDelete() }, onDismiss: { clearDeleted() })
            }
            HStack(alignment: .top, spacing: 12) {
                list
                detail
            }
            HStack {
                Button("Import…") { importProfile() }
                Button("New Profile…") { newProfile() }
                Spacer()
                Text(model.message).font(.wmCaption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding()
        .onAppear { appState.reloadProfiles() }
    }

    private var list: some View {
        let selection = Binding<UUID?>(get: { model.selection }, set: { model.select($0, store: appState.store) })
        return Group {
            if appState.savedProfiles.isEmpty {
                ContentUnavailableView("No profiles yet", systemImage: "rectangle.3.group",
                                       description: Text("Capture one from the menu bar, or use New Profile."))
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
                Text("Set hotkeys in the Shortcuts tab.")
                    .foregroundStyle(.secondary)
                Section {
                    Button("Open in Profile Studio") { ProfileStudioWindowController.shared.show(profileID: id) }
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
            ContentUnavailableView("Select a profile", systemImage: "sidebar.left")
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
            let name = appState.savedProfiles.first(where: { $0.id == id })?.name ?? "profile"
            let deleted = try appState.profileService.delete(id.uuidString)
            appState.reloadProfiles()
            model.select(nil, store: appState.store)
            model.message = "Moved to Trash."
            model.deletedProfile = deleted
            model.deletedName = name
            undoManager?.registerUndo(withTarget: model) { _ in MainActor.assumeIsolated { undoDelete() } }
            undoManager?.setActionName("Delete Profile")
            model.dismissTask?.cancel()
            model.dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { clearDeleted() }
            }
        } catch { fail(error) }
    }

    private func clearDeleted() {
        model.dismissTask?.cancel()
        model.deletedName = nil
        model.deletedProfile = nil
    }

    private func undoDelete() {
        guard let profile = model.deletedProfile else { return }
        do {
            let saved = try appState.profileService.restore(profile)
            appState.reloadProfiles()
            model.select(saved.id, store: appState.store)
            model.message = "Restored \(saved.name)."
        } catch { fail(error) }
        clearDeleted()
    }

    private func export(_ id: UUID) {
        do {
            let profile = try appState.profileService.show(id.uuidString)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(profile.name).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try appState.profileService.exportData(id.uuidString).write(to: url, options: .atomic)
            model.message = "Exported to \(url.lastPathComponent)."
        } catch { fail(error) }
    }

    /// Same action as the Studio menu's New Profile: opens the Studio and starts a capture of the current workspace.
    private func newProfile() {
        ProfileStudioWindowController.shared.show()
        ProfileStudioWindowController.shared.model.beginNewProfile()
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let saved = try appState.profileService.importData(data, source: url.lastPathComponent)
            appState.reloadProfiles()
            model.select(saved.id, store: appState.store)
            model.message = "Imported \(saved.name)."
        } catch { fail(error) }
    }
}
