import AppKit
import SwiftUI
import WMCore

@MainActor
final class WindowRulesModel: ObservableObject {
    @Published var rules: WindowRules
    @Published var newBundleID = ""
    @Published var message = ""
    private let store = WindowRulesStore()

    init() { rules = store.load() }

    func persist() {
        do { try store.save(rules); message = "" } catch { message = error.localizedDescription }
    }

    func add() {
        let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if rules.rule(for: id) == nil { rules.set(WindowRule(bundleID: id, action: .ignore)) }
        newBundleID = ""
        persist()
    }

    func remove(_ bundleID: String) {
        rules.remove(bundleID: bundleID)
        persist()
    }

    func set(_ rule: WindowRule) {
        rules.set(rule)
        persist()
    }

    /// Picks an app bundle and fills in its bundle id.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        newBundleID = id
    }
}

struct WindowRulesSettingsTab: View {
    @StateObject private var model = WindowRulesModel()
    private let displays = DisplayMap.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rules are saved per app. They are not applied to restores yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.rules.rules.isEmpty {
                Text("No rules yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rules.rules) { rule in
                    row(rule)
                }
            }
            HStack {
                TextField("Bundle ID", text: $model.newBundleID, prompt: Text("com.apple.Safari"))
                    .onSubmit { model.add() }
                Button("Choose App…") { model.chooseApp() }
                Button("Add") { model.add() }
                    .disabled(model.newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func kind(_ action: WindowRuleAction) -> String {
        switch action {
        case .ignore: return "ignore"
        case .alwaysRestore: return "alwaysRestore"
        case .pinToDisplay: return "pin"
        }
    }

    private func row(_ rule: WindowRule) -> some View {
        let kindBinding = Binding<String>(
            get: { kind(rule.action) },
            set: { value in
                switch value {
                case "ignore": model.set(WindowRule(bundleID: rule.bundleID, action: .ignore))
                case "alwaysRestore": model.set(WindowRule(bundleID: rule.bundleID, action: .alwaysRestore))
                default:
                    let uuid = displays.first(where: \.isMain)?.uuid ?? displays.first?.uuid ?? ""
                    model.set(WindowRule(bundleID: rule.bundleID, action: .pinToDisplay(uuid: uuid)))
                }
            })
        return HStack {
            Text(rule.bundleID).lineLimit(1).truncationMode(.middle)
            Spacer()
            Picker("", selection: kindBinding) {
                Text("Ignore").tag("ignore")
                Text("Always restore").tag("alwaysRestore")
                Text("Pin to display").tag("pin")
            }
            .labelsHidden()
            .frame(width: 140)
            if case .pinToDisplay(let uuid) = rule.action {
                let uuidBinding = Binding<String>(
                    get: { uuid },
                    set: { model.set(WindowRule(bundleID: rule.bundleID, action: .pinToDisplay(uuid: $0))) })
                Picker("", selection: uuidBinding) {
                    ForEach(displays, id: \.uuid) { Text($0.name).tag($0.uuid) }
                    if !displays.contains(where: { $0.uuid == uuid }) { Text("Disconnected display").tag(uuid) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Button { model.remove(rule.bundleID) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}
