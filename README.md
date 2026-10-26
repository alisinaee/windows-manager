# Windows Manager

Windows Manager is a macOS menu bar app that saves how your windows are arranged and puts them back with one click.

A profile (for example "Home" or "Work") records where each app's windows are: the monitor, position, size, full screen state and Desktop. Running the profile opens apps that are closed and moves the windows that are already open.

## Status

This is an early version, still in development.

What works today:

- **Menu bar app.** Capture the current workspace under a name, save it as a profile, and run any saved profile with one click.
- **Stage Manager.** Works with Stage Manager on or off. A profile records whether Stage Manager was on when it was captured, and the restore plan warns when that has changed.
- **Import and export.** Profiles can be exported to one JSON file and imported again, using the `spaceslab profile` command.
- **URL scheme and control command.** The app answers `windowsmanager://` links. The `spaceslab ctl` command sends them for you.
- **spaceslab.** A command line tool for checks and tests on your Mac (the "Spaces Lab"). See [docs/LAB.md](docs/LAB.md).

Not done yet: the Settings window is still a placeholder, the layout editor and zones are not built, and the app is not yet signed with a Developer ID or notarized.

## Requirements

- macOS 26 or later.
- Accessibility permission for Windows Manager (System Settings > Privacy & Security > Accessibility). The app cannot move windows without it.
- Xcode is recommended. The build scripts use Xcode's toolchain when it is installed.

## Build and run

From the project folder:

```bash
scripts/run-app.sh
```

This builds the app, puts it in `build/Windows Manager.app`, quits a running copy and opens the new build.

Other scripts:

- `scripts/bundle-app.sh` builds and signs the app bundle without opening it.
- `scripts/build.sh` builds the `spaceslab` command line tool to `.build/release/spaceslab`.
- `scripts/make-dev-cert.sh` creates a local code-signing certificate, once. With it, the Accessibility permission survives rebuilds. The certificate stays in the git-ignored `.signing/` folder.
- `scripts/env.sh` is sourced by the other scripts. It selects Xcode's toolchain.

## Tests

```bash
swift test
```

The test target is `WMCoreTests`.

## Project layout

- `Sources/WMCore/` is the shared library: profiles, display map, window matching, restore engine, Spaces and Stage Manager code.
- `Sources/WindowsManagerApp/` is the menu bar app.
- `Sources/spaceslab/` is the command line tool.
- `Tests/WMCoreTests/` holds the unit tests.
- `Resources/App/` holds the app's `Info.plist`.
- `docs/` holds the user guide, the Spaces Lab guide and the research notes.

## Documentation

- [User guide](docs/USER-GUIDE.md): first run, capturing and running profiles, import and export, URL examples.
- [Spaces Lab guide](docs/LAB.md): how to run the Spaces tests on your Mac.
- [Credits](docs/CREDITS.md): third-party code and ideas.

## License

Windows Manager is released under the MIT License (see [LICENSE](LICENSE)). The name stays "Windows Manager" for now.
