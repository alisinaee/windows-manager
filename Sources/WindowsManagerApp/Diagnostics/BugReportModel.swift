import AppKit
import SwiftUI
import WMCore

@MainActor
final class BugReportModel: ObservableObject {
    @Published var title = ""
    @Published var details = ""
    @Published var includeLogs = true { didSet { refresh() } }
    @Published var includeProfile = false
    @Published var preview = ""
    @Published var status = ""
    private var input = BugReportInput()
    private let redactor = BugRedactor.current

    init() { refresh() }

    func refresh() {
        input = BugReportCollector.input(title: title, description: details, includeLogs: includeLogs,
                                         info: Bundle.main.infoDictionary)
        preview = BugReport.body(input, redactor: redactor)
    }

    private func profileJSON() -> Data? {
        guard includeProfile else { return nil }
        let store = ProfileStore()
        guard let latest = store.list().first else { return nil }
        return try? Data(contentsOf: store.fileURL(for: latest.id))
    }

    func openIssue() {
        refresh()
        let link = BugReport.issueLink(input, redactor: redactor)
        NSWorkspace.shared.open(link.url)
        status = link.truncated ? "Opened GitHub. The text was shortened; create the zip and attach it." : "Opened GitHub."
    }

    func revealZip() {
        refresh()
        do {
            let zip = try BugReportCollector.writeBundle(input, redactor: redactor, profileJSON: profileJSON(),
                                                         directory: BugReportCollector.desktopFolder)
            NSWorkspace.shared.activateFileViewerSelecting([zip])
            status = "Saved \(zip.lastPathComponent) to the Desktop."
        } catch { status = error.localizedDescription }
    }

    func copyReport() {
        refresh()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview, forType: .string)
        status = "Copied."
    }
}

struct BugReportView: View {
    @StateObject private var model = BugReportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Short title", text: $model.title).onChange(of: model.title) { model.refresh() }
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.details).frame(height: 70).border(Color.secondary.opacity(0.3))
                .onChange(of: model.details) { model.refresh() }
            Toggle("Include logs", isOn: $model.includeLogs)
            Toggle("Include the profile I just ran", isOn: $model.includeProfile)
            Text("Exactly what will be sent (redacted)").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(model.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }
                .padding(6).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Open GitHub issue") { model.openIssue() }.keyboardShortcut(.defaultAction)
                Button("Reveal logs zip in Finder") { model.revealZip() }
                Button("Copy report") { model.copyReport() }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 480)
    }
}
