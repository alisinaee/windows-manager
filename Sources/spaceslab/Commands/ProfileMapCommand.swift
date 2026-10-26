import Foundation
import WMCore

// `spaceslab profile map <name> [--width N]`: prints a saved profile as a plain-text map (PM8).
// Registered as "profile map" in main.swift, because "profile" alone is the export/import command.
enum ProfileMapCommand {
    static let name = "profile map"
    static let help = "Print a saved profile as a text map (profile map <name> [--width N])"
    static let defaultWidth = 100

    static let usage = """
        Usage: spaceslab profile map <name> [--width N]

          map      Prints the saved profile named <name> (case-insensitive) as a text map: its displays,
                   Spaces and windows, with each window's position as a percentage of its display.
          --width  Width of the box maps in characters (default \(defaultWidth), at least \(ProfileMapText.minimumWidth)).

        """

    static func run(_ args: [String]) -> Int32 {
        var nameWords: [String] = []
        var width = defaultWidth
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--width" {
                guard index + 1 < args.count, let value = Int(args[index + 1]), value > 0 else {
                    fputs("profile map: --width needs a whole number greater than 0\n\n" + usage, stderr)
                    return 2
                }
                width = value
                index += 2
            } else if arg.hasPrefix("-") {
                fputs("profile map: unknown option \(arg)\n\n" + usage, stderr)
                return 2
            } else {
                nameWords.append(arg)
                index += 1
            }
        }
        guard !nameWords.isEmpty else {
            fputs("profile map: needs a profile name\n\n" + usage, stderr)
            return 2
        }
        return printMap(named: nameWords.joined(separator: " "), width: width)
    }

    private static func printMap(named wanted: String, width: Int) -> Int32 {
        let store = ProfileStore()
        let matches = store.list().filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
        }
        guard let summary = matches.first else {
            fputs("profile map: no saved profile is named \"\(wanted)\"\n", stderr)
            return 1
        }
        guard matches.count == 1 else {
            fputs("profile map: \(matches.count) profiles are named \"\(wanted)\"; rename one of them first\n", stderr)
            return 1
        }
        do {
            let profile = try store.load(summary.id)
            print(ProfileMapText.render(profile: profile, width: width), terminator: "")
            return 0
        } catch {
            fputs("profile map: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
