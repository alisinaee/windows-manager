import Foundation
import WMCore

private func layoutLine(_ layout: Layout) -> String {
    "\(layout.name)\tdisplay=\(layout.displayKey ?? "any")\tzones=\(layout.zones.count)"
}

func registerLayoutCommands(_ r: Registry) {
    r.register(Command(["layouts", "list"], summary: "List saved layouts") { _, _ in
        let layouts = try cliService { try LayoutService().list() }
        let data = JSONValue.object(["layouts": try JSONValue.from(layouts)])
        return CLIResult(data: data, text: layouts.map(layoutLine).joined(separator: "\n"))
    })

    r.register(Command(["layouts", "show"], summary: "Show one layout by id or name", args: [CLIArg("layout")]) { a, _ in
        let layout = try cliService { try LayoutService().get(a.positionals[0]) }
        return CLIResult(data: try JSONValue.from(layout), text: layoutLine(layout))
    })

    r.register(Command(["layouts", "create"], summary: "Create an empty layout",
                       args: [CLIArg("name")],
                       options: [CLIOption("display", "Display UUID the layout is for (default: any)", takesValue: true, valueName: "uuid")]) { a, _ in
        let layout = try cliService {
            try LayoutService().create(name: a.positionals[0], displayKey: a.value("display"))
        }
        return CLIResult(data: try JSONValue.from(layout), text: layoutLine(layout))
    })

    r.register(Command(["layouts", "delete"], summary: "Delete a layout by id or name", args: [CLIArg("layout")]) { a, _ in
        let service = LayoutService()
        let ref = a.positionals[0]
        let layout = try cliService { try service.get(ref) }
        try cliService { try service.delete(ref) }
        let data = JSONValue.object(["deleted": .bool(true), "id": .string(layout.id.uuidString), "name": .string(layout.name)])
        return CLIResult(data: data, text: "deleted \(layout.name)")
    })

    r.register(Command(["layouts", "rename"], summary: "Rename a layout",
                       args: [CLIArg("layout"), CLIArg("newName")]) { a, _ in
        let layout = try cliService { try LayoutService().rename(a.positionals[0], to: a.positionals[1]) }
        return CLIResult(data: try JSONValue.from(layout), text: layoutLine(layout))
    })
}
