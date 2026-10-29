import Foundation

// `wm layouts zones list|add|set|remove`: zone editing over LayoutService. Rects are fractions of the display
// (0...1, origin top-left), the same numbers the layout editor stores.

public enum LayoutZoneCommands {
    /// Parses "x,y,width,height" (fractions of the display).
    public static func parseRect(_ text: String) throws -> NormalizedRect {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && $0!.isFinite }) else {
            throw CLIFailure.usage("--rect needs four fractions x,y,width,height, for example 0,0,0.5,1", hint: "Values are 0...1 of the display, origin top-left.")
        }
        return NormalizedRect(x: parts[0]!, y: parts[1]!, width: parts[2]!, height: parts[3]!)
    }

    static func line(_ z: Zone) -> String {
        let r = z.rect
        return "\(z.name)\t\(z.id.uuidString)\trect=\(r.x),\(r.y),\(r.width),\(r.height)"
    }

    static func result(_ layout: Layout) throws -> CLIResult {
        CLIResult(data: .object(["layout": .string(layout.name), "zones": try JSONValue.from(layout.zones)]),
                  text: layout.zones.map(line).joined(separator: "\n"))
    }

    public static func register(_ r: Registry, service: @escaping () -> LayoutService) {
        let rectOption = CLIOption("rect", "x,y,width,height as fractions of the display", takesValue: true, valueName: "x,y,w,h")
        r.register(Command(["layouts", "zones", "list"], summary: "List the zones of a layout", args: [CLIArg("layout")]) { a, _ in
            try result(try cliService { try service().get(a.positionals[0]) })
        })
        r.register(Command(["layouts", "zones", "add"], summary: "Add a zone to a layout", args: [CLIArg("layout"), CLIArg("name")],
                           options: [rectOption], mutates: true) { a, _ in
            guard let rect = a.value("rect") else { throw CLIFailure.usage("--rect is required, for example --rect 0,0,0.5,1") }
            let parsed = try parseRect(rect)
            return try result(try cliService { try service().addZone(to: a.positionals[0], name: a.positionals[1], rect: parsed) })
        })
        r.register(Command(["layouts", "zones", "set"], summary: "Rename or move/resize a zone", args: [CLIArg("layout"), CLIArg("zone", "Zone id or name")],
                           options: [rectOption, CLIOption("name", "New zone name", takesValue: true, valueName: "text")], mutates: true) { a, _ in
            guard a.value("rect") != nil || a.value("name") != nil else { throw CLIFailure.usage("Give --rect and/or --name.") }
            let rect = try a.value("rect").map(parseRect)
            return try result(try cliService { try service().updateZone(in: a.positionals[0], zone: a.positionals[1], name: a.value("name"), rect: rect) })
        })
        r.register(Command(["layouts", "zones", "remove"], summary: "Remove a zone and its app assignments", args: [CLIArg("layout"), CLIArg("zone")],
                           mutates: true) { a, _ in
            try result(try cliService { try service().removeZone(from: a.positionals[0], zone: a.positionals[1]) })
        })
    }
}
