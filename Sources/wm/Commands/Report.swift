import Foundation
import WMCore

private func whichGH() -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin").split(separator: ":") {
        let p = "\(dir)/gh"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func registerReportCommands(_ r: Registry) {
    r.register(Command(["report"],
                       summary: "Write a redacted bug-report bundle (zip) and print the prefilled GitHub issue URL; never uses the network without --submit",
                       options: [CLIOption("title", short: "t", "Issue title", takesValue: true, valueName: "T"),
                                 CLIOption("description", short: "d", "What happened", takesValue: true, valueName: "D"),
                                 CLIOption("include-profile", "Add this profile's JSON to the zip", takesValue: true, valueName: "NAME"),
                                 CLIOption("out", "Folder for the zip (default ~/Desktop)", takesValue: true, valueName: "DIR"),
                                 CLIOption("submit", "Create the issue with the gh CLI (network)")],
                       mutates: true) { args, _ in
        let title = args.value("title") ?? "Bug report"
        let input = BugReportCollector.input(title: title, description: args.value("description") ?? "",
                                             includeLogs: true, info: nil)
        let redactor = BugRedactor.current
        var profileJSON: Data?
        if let name = args.value("include-profile") {
            let store = ProfileStore()
            guard let summary = store.list().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CLIFailure.notFound("No profile named '\(name)'", hint: "wm profile list")
            }
            profileJSON = try? Data(contentsOf: store.fileURL(for: summary.id))
        }
        let outDir = args.value("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? BugReportCollector.desktopFolder
        let zip: URL
        do { zip = try BugReportCollector.writeBundle(input, redactor: redactor, profileJSON: profileJSON, directory: outDir) }
        catch { throw CLIFailure(.runtime, code: "bundle_failed", message: "\(error.localizedDescription)") }
        let link = BugReport.issueLink(input, redactor: redactor)

        var submitted: String?
        if args.flag("submit") {
            guard let gh = whichGH() else {
                throw CLIFailure(.runtime, code: "gh_missing", message: "The GitHub CLI (gh) was not found",
                                 hint: "Open the URL instead, or install gh")
            }
            let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("wm-report-\(UUID().uuidString).md")
            try? BugReport.body(input, redactor: redactor, compact: link.truncated)
                .write(to: bodyFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["issue", "create", "--repo", BugReport.repo, "--title", redactor.redact(title), "--body-file", bodyFile.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            do { try p.run() } catch { throw CLIFailure(.runtime, code: "gh_failed", message: "\(error.localizedDescription)") }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw CLIFailure(.runtime, code: "gh_failed", message: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var obj: [String: JSONValue] = ["zip": .string(zip.path), "issueURL": .string(link.url.absoluteString),
                                        "truncated": .bool(link.truncated)]
        if let submitted { obj["submitted"] = .string(submitted) }
        var text = "Bundle: \(zip.path)\nIssue URL: \(link.url.absoluteString)"
        if link.truncated { text += "\nThe body was shortened for the URL; attach the zip to the issue." }
        if let submitted { text += "\nCreated: \(submitted)" }
        return CLIResult(data: .object(obj), text: text)
    })
}
