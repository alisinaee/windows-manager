import AppKit
import Combine
import SwiftUI
import WMCore

/// Edits the pin rules. `onChange` runs after every save, so the watcher can start or stop polling.
@MainActor
final class PinRulesModel: ObservableObject {
    @Published var rules: [PinRule]
    @Published var bundleID = ""
    @Published var titleFilter = ""
    @Published var desktopNumber = 1
    @Published var displayUUID = ""
    @Published private(set) var displays: [DisplayIdentity] = []
    @Published var message = ""
    private let store: PinRulesStore
    private let onChange: () -> Void

    init(store: PinRulesStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        rules = store.load()
        refreshDisplays()
    }

    /// Re-reads the monitors so a hot-plugged or removed display shows up correctly.
    func refreshDisplays() {
        displays = DisplayMap.current()
        if !displays.contains(where: { $0.uuid == displayUUID }) {
            displayUUID = displays.first(where: \.isMain)?.uuid ?? displays.first?.uuid ?? ""
        }
    }

    func displayName(for uuid: String) -> String {
        displays.first(where: { $0.uuid == uuid })?.name ?? "disconnected display"
    }

    func add() {
        let app = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, !displayUUID.isEmpty else { return }
        rules.append(PinRule(bundleID: app, titleContains: title.isEmpty ? nil : title,
                             target: .desktopIndex(number: desktopNumber, displayUUID: displayUUID)))
        bundleID = ""
        titleFilter = ""
        persist()
    }

    func remove(_ rule: PinRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    /// Picks an app bundle and fills in its bundle id.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        bundleID = id
    }

    private func persist() {
        do {
            try store.save(rules)
            message = ""
            onChange()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A Settings section that lists, adds and removes pin rules. Place it inside a `Form`.
struct PinRulesSection: View {
    @StateObject private var model: PinRulesModel

    init(store: PinRulesStore = PinRulesStore(), onChange: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: PinRulesModel(store: store, onChange: onChange))
    }

    var body: some View {
        Section {
            if model.rules.isEmpty {
                Text("No pin rules yet.").foregroundStyle(.secondary)
            }
            ForEach(model.rules) { rule in
                row(rule)
            }
            TextField("App bundle ID", text: $model.bundleID, prompt: Text("com.apple.Safari"))
            TextField("Window title contains (optional)", text: $model.titleFilter)
            Picker("Desktop", selection: $model.desktopNumber) {
                ForEach(1...16, id: \.self) { Text("Desktop \($0)").tag($0) }
            }
            if model.displays.count > 1 {
                Picker("Display", selection: $model.displayUUID) {
                    ForEach(model.displays, id: \.uuid) { Text($0.name).tag($0.uuid) }
                }
            }
            HStack {
                Button("Choose App…") { model.chooseApp() }
                Spacer()
                Button("Add Rule") { model.add() }
                    .disabled(model.bundleID.trimmingCharacters(in: .whitespaces).isEmpty || model.displayUUID.isEmpty)
            }
            Text("A new window of the app (matching the title, if one is given) is moved to that Desktop once, when it appears. Windows already open are not moved, and neither are full-screen windows or windows you moved by hand a moment ago.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !model.message.isEmpty {
                Text(model.message).font(.footnote).foregroundStyle(Tone.danger.color)
            }
        } header: {
            Text("Pin rules")
        }
        .onAppear { model.refreshDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refreshDisplays()
        }
    }

    private func row(_ rule: PinRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.bundleID).lineLimit(1).truncationMode(.middle)
                if let title = rule.titleContains {
                    Text("Title contains \"\(title)\"").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(targetText(rule.target)).font(.footnote).foregroundStyle(.secondary)
            Button { model.remove(rule) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove pin rule")
        }
    }

    private func targetText(_ target: PinTarget) -> String {
        switch target {
        case .desktopIndex(let number, let uuid):
            return "Desktop \(number), \(model.displayName(for: uuid))"
        case .spaceID(let id):
            return "Space \(id)"
        }
    }
}
