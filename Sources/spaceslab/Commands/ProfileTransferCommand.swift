import Foundation
import WMCore

enum ProfileTransferCommand {
    static let name = "profile"
    static let help = "Export a saved profile to one JSON file, or import one (profile export <name> <path> | profile import <path>)"

    static let usage = """
        Usage: spaceslab profile export <name> <path>
               spaceslab profile import <path>

          export  Writes the saved profile named <name> (case-insensitive) to <path> as one JSON file.
          import  Reads a profile JSON file and saves it as a new profile. It gets a new id, and if its name
                  is already used, the name becomes "<name> 2" (or the next free number). Its hotkey is cleared.

        """

    static func run(_ args: [String]) -> Int32 {
        guard let subcommand = args.first else {
            fputs(usage, stderr)
            return 2
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "export":
            guard rest.count == 2 else {
                fputs("profile export: needs a profile name and a file path\n" + usage, stderr)
                return 2
            }
            return exportProfile(named: rest[0], to: rest[1])
        case "import":
            guard rest.count == 1 else {
                fputs("profile import: needs a file path\n" + usage, stderr)
                return 2
            }
            return importProfile(from: rest[0])
        default:
            fputs("profile: unknown subcommand \(subcommand)\n" + usage, stderr)
            return 2
        }
    }

    private static func exportProfile(named wanted: String, to path: String) -> Int32 {
        let store = ProfileStore()
        let matches = store.list().filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
        }
        guard let summary = matches.first else {
            fputs("profile export: no saved profile is named \"\(wanted)\"\n", stderr)
            return 1
        }
        guard matches.count == 1 else {
            fputs("profile export: \(matches.count) profiles are named \"\(wanted)\"; rename one of them first\n", stderr)
            return 1
        }
        do {
            let profile = try store.load(summary.id)
            let data = try ProfileTransfer.export(profile)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Exported \"\(profile.name)\" to \(path)")
            return 0
        } catch {
            fputs("profile export: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func importProfile(from path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let store = ProfileStore()
            let imported = try ProfileTransfer.importProfile(data, existingNames: store.list().map(\.name),
                                                             source: URL(fileURLWithPath: path).lastPathComponent)
            let saved = try store.save(imported)
            print("Imported \"\(saved.name)\" (\(saved.id.uuidString))")
            return 0
        } catch {
            fputs("profile import: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
