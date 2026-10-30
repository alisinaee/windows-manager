import AppKit
import Combine
import SwiftUI
import WMCore

@MainActor
final class WindowRulesModel: ObservableObject {
    @Published var rules: WindowRules
    @Published var newBundleID = ""
    @Published var message = ""
    @Published private(set) var displays: [DisplayIdentity] = []
    private let store = WindowRulesStore()

    init() {
        rules = store.load()
        refreshDisplays()
    }

    /// Re-reads the monitors so a hot-plugged or removed display shows up correctly.
    func refreshDisplays() { displays = DisplayMap.current() }

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

    var body: some View {
        Form {
            if !model.message.isEmpty {
                Section {
                    Banner(tone: .danger, title: "Could not save rules", message: model.message,
                           actionLabel: "Retry", action: { model.persist() },
                           onDismiss: { model.message = "" })
                }
            }
            Section {
                if model.rules.rules.isEmpty {
                    ContentUnavailableView("No rules yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Add an app below to ignore it, always restore it, or pin it to a display."))
                } else {
                    ForEach(model.rules.rules) { rule in
                        row(rule)
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules are saved per app. They are not applied to restores yet.")
            }
            Section("Add a rule") {
                TextField("Bundle ID", text: $model.newBundleID, prompt: Text("com.apple.Safari"))
                    .onSubmit { model.add() }
                HStack {
                    Button("Choose App…") { model.chooseApp() }
                    Spacer()
                    Button("Add") { model.add() }
                        .disabled(model.newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refreshDisplays()
        }
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
                    let uuid = model.displays.first(where: \.isMain)?.uuid ?? model.displays.first?.uuid ?? ""
                    model.set(WindowRule(bundleID: rule.bundleID, action: .pinToDisplay(uuid: uuid)))
                }
            })
        return HStack {
            Text(rule.bundleID).lineLimit(1).truncationMode(.middle)
            Spacer()
            Picker("Rule kind", selection: kindBinding) {
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
                Picker("Display", selection: uuidBinding) {
                    ForEach(model.displays, id: \.uuid) { Text($0.name).tag($0.uuid) }
                    if !model.displays.contains(where: { $0.uuid == uuid }) { Text("Disconnected display").tag(uuid) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Button { model.remove(rule.bundleID) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove rule for \(rule.bundleID)")
                .help("Remove this rule")
        }
    }
}
