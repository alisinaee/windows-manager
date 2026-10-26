import Foundation

// Every command is an enum with `name`, `help` and `run(_:)`. Later tasks replace only their own file.
struct Command {
    let name: String
    let help: String
    let run: ([String]) -> Int32
}

let commands: [Command] = [
    Command(name: DoctorCommand.name, help: DoctorCommand.help, run: DoctorCommand.run),
    Command(name: ReportCommand.name, help: ReportCommand.help, run: ReportCommand.run),
    Command(name: SpacesCommand.name, help: SpacesCommand.help, run: SpacesCommand.run),
    Command(name: MoveCommand.name, help: MoveCommand.help, run: MoveCommand.run),
    Command(name: FullscreenCommand.name, help: FullscreenCommand.help, run: FullscreenCommand.run),
    Command(name: SwitchCommand.name, help: SwitchCommand.help, run: SwitchCommand.run),
    Command(name: DesktopsCommand.name, help: DesktopsCommand.help, run: DesktopsCommand.run),
    Command(name: OrderFileCommand.name, help: OrderFileCommand.help, run: OrderFileCommand.run),
    Command(name: VirtualCommand.name, help: VirtualCommand.help, run: VirtualCommand.run),
    Command(name: AXRemoteCommand.name, help: AXRemoteCommand.help, run: AXRemoteCommand.run),
    Command(name: CaptureCommand.name, help: CaptureCommand.help, run: CaptureCommand.run),
    Command(name: RestoreCommand.name, help: RestoreCommand.help, run: RestoreCommand.run),
]

func usageText() -> String {
    var text = "spaceslab - Windows Manager Spaces Lab\n\nUsage: spaceslab <command> [options]\n\nCommands:\n"
    let width = (commands.map { $0.name.count } + [4]).max() ?? 4
    for command in commands {
        text += "  " + command.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + command.help + "\n"
    }
    text += "  " + "help".padding(toLength: width, withPad: " ", startingAt: 0) + "  Show this list\n"
    text += "\nExit codes: 0 ok, 1 failure, 2 usage error.\n"
    return text
}

func runMain() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first else {
        fputs(usageText(), stderr)
        return 2
    }
    if ["help", "--help", "-h"].contains(first) {
        print(usageText(), terminator: "")
        return 0
    }
    guard let command = commands.first(where: { $0.name == first }) else {
        fputs("Unknown command: \(first)\n\n" + usageText(), stderr)
        return 2
    }
    return command.run(Array(args.dropFirst()))
}

exit(runMain())
