import Foundation
import WMCore

/// P6.86 gap closers: hotkeys, Space backups, live window list, updates check, layout zones.
/// Logic and parsing live in WMCore/CLI so unit tests can run them against injected stores.
func registerSystemExtraCommands(_ r: Registry) {
    HotkeyCommands.register(r) { try HotkeyStore(suiteName: "dev.windowsmanager.WindowsManager") }
    BackupCommands.register(r) { SpaceBindingsBackup() }
    WindowListCommands.register(r, windows: { WindowCatalog.all() }, displays: { try SpaceReader.displays() })
    UpdateCommands.register(r, locate: UpdateCheck.liveAppLocator, fetch: UpdateCheck.liveFetch)
    LayoutZoneCommands.register(r) { LayoutService() }
    AutoMapCommands.register(r, rules: { RuleService() }, profiles: { ProfileService() },
                             currentKey: { DisplayMap.monitorSetKey(DisplayMap.current()) })
}
