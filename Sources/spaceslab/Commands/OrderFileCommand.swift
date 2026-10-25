import AppKit
import Foundation
import WMCore

/// P1.7: does rewriting the Space order in com.apple.spaces and restarting the Dock reorder Spaces?
/// `show` and `backup` are read-only. `apply` and `restore` change the user's preferences and restart the Dock,
/// so both need --yes and always take a backup first.
enum OrderFileCommand {
    static let name = "order-file"
    static let help = "Show, back up, rewrite and restore the Space order stored in com.apple.spaces"

    static let usage = """
        Usage: spaceslab order-file <subcommand>

          show                    Read-only. Per display: the stored order (Monitors and ManagedSpaceOrdering)
                                  next to the live order from SkyLight. Differences are flagged.
          backup                  Save com.apple.spaces into ./lab-results/backups/. Changes nothing else.
          apply --display <identifier or number> --order <list> [--yes]
                                  Rewrite the stored order of one display, restart the Dock and check whether the
                                  live order follows. <list> holds the CURRENT 1-based positions in the new order,
                                  e.g. --order 2,1,3,4,5 swaps the first two Spaces. --display is "Main", a display
                                  UUID, or the display number from `spaceslab spaces`.
                                  Without --yes: dry run, prints old and new order and writes nothing.
                                  With --yes: backup, write, restart the Dock, read the live order, record
                                  the result as "order-file-apply".
          restore <backup file> --yes
                                  Put a backup back (defaults import) and restart the Dock. Records
                                  "order-file-restore". Without --yes: dry run.

        apply and restore restart the Dock: Mission Control and the Dock flicker for a few seconds.

        """

    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            fputs(usage, stderr)
            return 2
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "show": return show(rest)
        case "backup": return backup(rest)
        case "apply": return apply(rest)
        case "restore": return restore(rest)
        case "-h", "--help", "help":
            print(usage, terminator: "")
            return 0
        default:
            fputs("order-file: unknown subcommand \(sub)\n\n" + usage, stderr)
            return 2
        }
    }

    // MARK: Shared helpers

    static var backupsFolder: URL { LabResult.defaultFolder.appendingPathComponent("backups") }

    private static func fail(_ message: String) -> Int32 {
        fputs("order-file: \(message)\n", stderr)
        return 1
    }

    private static func usageError(_ message: String) -> Int32 {
        fputs("order-file: \(message)\n\n" + usage, stderr)
        return 2
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func sameID(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func liveDisplay(_ identifier: String, in displays: [DisplaySpaces]) -> DisplaySpaces? {
        displays.first { sameID($0.displayIdentifier, identifier) }
    }

    /// Live Space uuids of one display right now; nil when SpaceReader cannot answer or the display is gone.
    private static func liveUUIDs(_ identifier: String) -> [String]? {
        guard let displays = try? SpaceReader.displays() else { return nil }
        return liveDisplay(identifier, in: displays)?.spaces.map(\.uuid)
    }

    private static func displayTitle(_ live: DisplaySpaces, number: Int) -> String {
        live.displayName.map { "Display \(number): \($0) (\(live.displayIdentifier))" }
            ?? "Display \(number): \(live.displayIdentifier)"
    }

    // MARK: Pairing stored and live displays

    /// A stored display (Monitors entry) with the live display it describes, when there is one.
    private struct DisplayPair {
        var stored: StoredDisplayOrder
        var live: DisplaySpaces?
        /// 1-based position of the live display, as `spaceslab spaces` numbers it.
        var liveNumber: Int?
    }

    /// UUID of the main display (the one with the menu bar), the way SkyLight spells a display identifier.
    private static func mainDisplayUUID() -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The stored Monitors entry calls the main display "Main", while SkyLight may report its UUID. So a stored
    /// display is paired with the live display that has the same identifier; else the one named by its
    /// ManagedSpaceOrdering entry; else, for "Main", the live display whose UUID is the main display's. A rule
    /// counts only when it picks exactly one unused live display.
    private static func pairDisplays(stored: [StoredDisplayOrder], live: [DisplaySpaces]) -> [DisplayPair] {
        let mainUUID = mainDisplayUUID()
        var used = Set<Int>()
        return stored.map { entry in
            func find(_ matches: (DisplaySpaces) -> Bool) -> Int? {
                let hits = live.indices.filter { !used.contains($0) && matches(live[$0]) }
                return hits.count == 1 ? hits[0] : nil
            }
            var index = find { sameID($0.displayIdentifier, entry.displayIdentifier) }
            if index == nil, let orderingID = entry.orderingDisplayID {
                index = find { sameID($0.displayIdentifier, orderingID) }
            }
            if index == nil, sameID(entry.displayIdentifier, "Main"), let mainUUID {
                index = find { sameID($0.displayIdentifier, mainUUID) }
            }
            if let index { used.insert(index) }
            return DisplayPair(stored: entry, live: index.map { live[$0] }, liveNumber: index.map { $0 + 1 })
        }
    }

    // MARK: Tokens (short labels, same style as `spaceslab spaces --watch`)

    /// uuid -> "D1[1]", "FS:Google Chrome[37]" for a stored display.
    private static func storedTokens(_ display: StoredDisplayOrder) -> [String: String] {
        var desktops = 0
        var tokens: [String: String] = [:]
        for space in display.spaces {
            let base: String
            if space.isDesktop {
                desktops += 1
                base = "D\(desktops)"
            } else if space.isFullScreen {
                base = "FS:\(space.ownerName ?? "?")"
            } else {
                base = "?\(space.type ?? -1)"
            }
            tokens[space.uuid] = base + (space.id.map { "[\($0)]" } ?? "")
        }
        return tokens
    }

    /// uuid -> token for a live display.
    private static func liveTokens(_ display: DisplaySpaces) -> [String: String] {
        var tokens: [String: String] = [:]
        for space in display.spaces {
            let base: String
            switch space.kind {
            case .desktop:
                base = "D\(display.desktopNumber(of: space) ?? 0)"
            case .fullscreen:
                let apps = space.ownerAppNames.isEmpty ? "?" : space.ownerAppNames.joined(separator: " + ")
                base = "\(space.isSplitView ? "SV" : "FS"):\(apps)"
            case .other(let raw):
                base = "?\(raw)"
            }
            tokens[space.uuid] = base + "[\(space.id)]"
        }
        return tokens
    }

    private static func name(of uuid: String, _ tokens: [String: String]) -> String {
        tokens[uuid] ?? (uuid.isEmpty ? "(empty uuid)" : "uuid " + String(uuid.prefix(8)))
    }

    private static func orderLine(_ uuids: [String], _ tokens: [String: String]) -> String {
        uuids.map { name(of: $0, tokens) }.joined(separator: " | ")
    }

    /// nil when both lists are the same; otherwise a short reason.
    private static func difference(_ a: [String], _ b: [String], aName: String, bName: String,
                                   tokens: [String: String]) -> String? {
        if a == b { return nil }
        let onlyA = a.filter { !b.contains($0) }
        let onlyB = b.filter { !a.contains($0) }
        if !onlyA.isEmpty || !onlyB.isEmpty {
            var parts: [String] = []
            if !onlyA.isEmpty { parts.append("only in \(aName): " + onlyA.map { name(of: $0, tokens) }.joined(separator: ", ")) }
            if !onlyB.isEmpty { parts.append("only in \(bName): " + onlyB.map { name(of: $0, tokens) }.joined(separator: ", ")) }
            return parts.joined(separator: "; ")
        }
        let positions = (0..<min(a.count, b.count)).filter { a[$0] != b[$0] }.map { String($0 + 1) }
        return "same Spaces, different order (positions \(positions.joined(separator: ", ")) differ)"
    }

    private static func printTable(headers: [String], columns: [[String]], indent: String = "  ") {
        let rows = columns.map(\.count).max() ?? 0
        let widths = [3] + zip(headers, columns).map { header, column in max(header.count, column.map(\.count).max() ?? 0) }
        func line(_ cells: [String]) -> String {
            let padded = cells.enumerated().map { n, cell in n == cells.count - 1 ? cell : pad(cell, widths[n]) }
            return indent + padded.joined(separator: "  ")
        }
        print(line(["pos"] + headers))
        for row in 0..<rows {
            print(line([String(row + 1)] + columns.map { row < $0.count ? $0[row] : "-" }))
        }
    }

    /// True when a full-screen Space comes before the first Desktop.
    private static func fullScreenLeftOfFirstDesktop(_ spaces: [StoredSpace], order: [String]) -> Bool {
        let byUUID = Dictionary(spaces.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let kinds = order.compactMap { byUUID[$0] }
        guard let desktop = kinds.firstIndex(where: \.isDesktop),
              let fullScreen = kinds.firstIndex(where: \.isFullScreen) else { return false }
        return fullScreen < desktop
    }

    /// "Automatically rearrange Spaces based on most recent use": when on, macOS reorders Spaces by itself.
    private static func mruSpacesOn() -> Bool {
        let value = CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString)
        return (value as? Bool) ?? true
    }

    private static func printBackupBanner(_ url: URL, heading: String = "BACKUP SAVED") {
        let raw = SpaceOrderFile.rawCopyURL(forBackup: url)
        let line = String(repeating: "=", count: 72)
        print("")
        print(line)
        print(heading)
        print("  " + url.path)
        if FileManager.default.fileExists(atPath: raw.path) { print("  raw copy: " + raw.path) }
        print("To put it back:")
        print("  spaceslab order-file restore \(shellQuote(url.path)) --yes")
        print("or by hand:")
        print("  defaults import com.apple.spaces \(shellQuote(url.path)) && killall Dock")
        print(line)
        print("")
    }

    private static func printRestoreHint(_ url: URL?, heading: String) {
        guard let url else {
            print("No backup was taken, so nothing was changed by this command.")
            return
        }
        printBackupBanner(url, heading: heading)
    }

    private static func saveAndReport(_ result: inout LabResult) {
        result.finish()
        do {
            let url = try result.save()
            print("Lab result saved: \(url.path)")
        } catch {
            fputs("order-file: could not save the lab result: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: show

    static func show(_ args: [String]) -> Int32 {
        if let extra = args.first {
            if extra == "-h" || extra == "--help" {
                print(usage, terminator: "")
                return 0
            }
            return usageError("show takes no options (got \(extra))")
        }
        do {
            let config = try SpaceOrderFile.readDomain()
            let inspection = SpaceOrderFile.inspect(config)
            var liveError: String?
            var live: [DisplaySpaces] = []
            do { live = try SpaceReader.displays() } catch { liveError = error.localizedDescription }

            print("com.apple.spaces on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Layout: \(inspection.layout.summary)")
            print("Monitors entries: \(inspection.monitorEntryCount) "
                  + "(\(inspection.displays.count) with Spaces, \(inspection.staleMonitorCount) stale without Spaces)")
            for problem in inspection.layout.problems { print("PROBLEM: \(problem)") }
            if let liveError { print("PROBLEM: live order unavailable: \(liveError)") }
            if inspection.displays.isEmpty { print("No stored display has Spaces.") }

            var differences = 0
            let pairs = pairDisplays(stored: inspection.displays, live: live)
            for pair in pairs {
                differences += printStoredDisplay(pair, config: config)
            }
            for (n, liveDisplay) in live.enumerated() where !pairs.contains(where: { $0.liveNumber == n + 1 }) {
                differences += 1
                print("")
                print("DIFFERENT: live \(displayTitle(liveDisplay, number: n + 1)) has no stored Monitors entry with Spaces")
            }

            print("")
            print(differences == 0 && inspection.layout.problems.isEmpty
                  ? "Result: the stored order matches the live order on every display."
                  : "Result: \(differences) difference(s) or problem(s) found (see DIFFERENT / PROBLEM above).")
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Prints one stored display and returns the number of differences found.
    private static func printStoredDisplay(_ pair: DisplayPair, config: [String: Any]) -> Int {
        var differences = 0
        let display = pair.stored
        var tokens = storedTokens(display)
        if let live = pair.live { tokens.merge(liveTokens(live)) { stored, _ in stored } }

        print("")
        var heading = "Display \(display.displayIdentifier) (stored Monitors entry \(display.monitorIndex + 1))"
        if let live = pair.live, let number = pair.liveNumber {
            heading += " = live " + displayTitle(live, number: number)
        } else {
            differences += 1
            heading += " = no live display found for it (DIFFERENT)"
        }
        print(heading)

        let liveUUIDs = pair.live.map { $0.spaces.map(\.uuid) }
        let orderingUUIDs = display.orderingLiveUUIDs
        printTable(headers: ["Monitors (stored)", "ManagedSpaceOrdering", "Live (SkyLight)"], columns: [
            display.monitorUUIDs.map { name(of: $0, tokens) },
            (orderingUUIDs ?? []).map { name(of: $0, tokens) },
            (liveUUIDs ?? []).map { name(of: $0, tokens) },
        ])

        if let id = display.orderingDisplayID {
            var line = "  ManagedSpaceOrdering entry #\((display.orderingIndex ?? 0) + 1): ManagedDisplayID \(id)"
            if let note = display.orderingNote { line += " (\(note))" }
            print(line)
        } else {
            differences += 1
            print("  DIFFERENT: no ManagedSpaceOrdering entry matched (\(display.orderingNote ?? "unknown reason"))")
        }
        for problem in display.problems {
            differences += 1
            print("  PROBLEM: \(problem)")
        }
        if !display.staleOrderingUUIDs.isEmpty {
            print("  note: the ordering entry also lists \(display.staleOrderingUUIDs.count) stale uuid(s) that are not "
                  + "Spaces of this display: " + display.staleOrderingUUIDs.map { name(of: $0, tokens) }.joined(separator: ", "))
        }

        if let orderingUUIDs {
            if let why = difference(display.monitorUUIDs, orderingUUIDs, aName: "Monitors", bName: "ordering", tokens: tokens) {
                differences += 1
                print("  DIFFERENT: Monitors vs ManagedSpaceOrdering: \(why)")
            } else {
                print("  OK: Monitors and ManagedSpaceOrdering list the same order.")
            }
        }
        if let liveUUIDs {
            if let why = difference(display.monitorUUIDs, liveUUIDs, aName: "stored", bName: "live", tokens: tokens) {
                differences += 1
                print("  DIFFERENT: stored vs live: \(why)")
            } else {
                print("  OK: stored order equals the live order.")
            }
        }

        // Would `apply` accept this display? Reordering to the current order changes nothing but runs every check.
        do {
            _ = try SpaceOrderFile.reordered(config, displayID: display.displayIdentifier,
                                             newOrderUUIDs: display.monitorUUIDs)
            print("  apply check: layout accepted.")
        } catch {
            print("  apply check: would be refused: \(error.localizedDescription)")
        }
        return differences
    }

    // MARK: backup

    static func backup(_ args: [String]) -> Int32 {
        if let extra = args.first {
            if extra == "-h" || extra == "--help" {
                print(usage, terminator: "")
                return 0
            }
            return usageError("backup takes no options (got \(extra))")
        }
        do {
            let url = try SpaceOrderFile.backup(to: backupsFolder)
            printBackupBanner(url)
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: apply

    private struct ApplyOptions {
        var display: String?
        var order: String?
        var yes = false
    }

    static func apply(_ args: [String]) -> Int32 {
        var options = ApplyOptions()
        var index = 0
        func value(_ flag: String, _ arg: String) -> String? {
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            index += 1
            return index < args.count ? args[index] : nil
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--yes": options.yes = true
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            case _ where arg == "--display" || arg.hasPrefix("--display="):
                guard let v = value("--display", arg) else { return usageError("--display needs a value") }
                options.display = v
            case _ where arg == "--order" || arg.hasPrefix("--order="):
                guard let v = value("--order", arg) else { return usageError("--order needs a value") }
                options.order = v
            default:
                return usageError("apply: unknown option \(arg)")
            }
            index += 1
        }
        guard let displayArg = options.display, let orderArg = options.order else {
            return usageError("apply needs --display and --order")
        }

        // Everything up to the dry-run output only reads.
        let config: [String: Any]
        let live: [DisplaySpaces]
        do {
            config = try SpaceOrderFile.readDomain()
            live = try SpaceReader.displays()
        } catch {
            return fail(error.localizedDescription)
        }
        let inspection = SpaceOrderFile.inspect(config)

        let pair: DisplayPair
        switch resolvePair(displayArg, pairs: pairDisplays(stored: inspection.displays, live: live), live: live) {
        case .success(let found): pair = found
        case .failure(let error): return fail(error.message)
        }
        let stored = pair.stored
        guard let liveTarget = pair.live, let liveNumber = pair.liveNumber else {
            return fail("the stored display \(stored.displayIdentifier) matches no live display; run `order-file show`")
        }
        let target = ResolvedDisplay(display: liveTarget, number: liveNumber)

        let count = stored.spaces.count
        let positions: [Int]
        switch parsePositions(orderArg, count: count) {
        case .success(let parsed): positions = parsed
        case .failure(let error): return usageError(error.message)
        }

        let liveUUIDs = target.display.spaces.map(\.uuid)
        var tokens = storedTokens(stored)
        tokens.merge(liveTokens(target.display)) { stored, _ in stored }
        if let why = difference(stored.monitorUUIDs, liveUUIDs, aName: "stored", bName: "live", tokens: tokens) {
            return fail("the stored order does not match the live order (\(why)), so position numbers are ambiguous. "
                        + "Run `order-file show`, fix the difference, then try again.")
        }

        let newUUIDs = positions.map { stored.monitorUUIDs[$0 - 1] }
        if newUUIDs == stored.monitorUUIDs {
            print("The order \(orderArg) is the current order. Nothing to do.")
            return 0
        }
        do {
            // Dry check only; `performApply` builds the config again from fresh data right before writing.
            _ = try SpaceOrderFile.reordered(config, displayID: stored.displayIdentifier, newOrderUUIDs: newUUIDs)
        } catch {
            return fail(error.localizedDescription)
        }
        if SpaceOrderFile.dockPID() == nil {
            return fail("the Dock is not running, so there is nothing to restart. Refusing.")
        }

        // Dry-run report.
        let leftBefore = fullScreenLeftOfFirstDesktop(stored.spaces, order: stored.monitorUUIDs)
        let leftAfter = fullScreenLeftOfFirstDesktop(stored.spaces, order: newUUIDs)
        print("\(displayTitle(target.display, number: target.number)); order \(orderArg)")
        printTable(headers: ["now", "after"], columns: [
            stored.monitorUUIDs.map { name(of: $0, tokens) },
            newUUIDs.map { name(of: $0, tokens) },
        ])
        print("  Both the Monitors entry and ManagedSpaceOrdering entry \(stored.orderingDisplayID ?? "?") get this order.")
        print("  Full-screen Space left of Desktop 1: before \(leftBefore ? "yes" : "no"), after \(leftAfter ? "yes" : "no").")
        if stored.monitorUUIDs.first == "" && newUUIDs.first != "" {
            print("  WARNING: this moves the original first Desktop (empty uuid) away from position 1. macOS may treat it specially.")
        }
        if mruSpacesOn() {
            print("  WARNING: \"Automatically rearrange Spaces based on most recent use\" is on (mru-spaces). "
                  + "macOS may reorder Spaces by itself and blur this test. `spaceslab doctor` shows the setting.")
        }
        if stored.isConsistent == false {
            print("  note: Monitors and ManagedSpaceOrdering disagreed before; both will agree after.")
        }

        guard options.yes else {
            print("")
            print("Dry run: nothing written, Dock not restarted. Add --yes to backup, write, restart the Dock and check the result.")
            return 0
        }

        return performApply(stored: stored, target: target.display,
                            newUUIDs: newUUIDs, tokens: tokens, orderArg: orderArg, leftBefore: leftBefore,
                            leftAfter: leftAfter, liveBefore: live)
    }

    private struct ResolvedDisplay {
        var display: DisplaySpaces
        var number: Int
    }

    private struct OrderParseError: Error { var message: String }

    /// A number is the 1-based position among live displays (as in `spaceslab spaces`); text is a display
    /// identifier, either the stored one ("Main") or the live one (a UUID).
    private static func resolvePair(_ argument: String, pairs: [DisplayPair],
                                    live: [DisplaySpaces]) -> Result<DisplayPair, OrderParseError> {
        let known = "Live displays: "
            + live.enumerated().map { "\($0.offset + 1) = \($0.element.displayIdentifier)" }.joined(separator: ", ")
            + "; stored displays with Spaces: " + pairs.map(\.stored.displayIdentifier).joined(separator: ", ")
        if let number = Int(argument) {
            guard number >= 1, number <= live.count else {
                return .failure(OrderParseError(message: "--display \(number) is not a live display number. \(known)"))
            }
            guard let pair = pairs.first(where: { $0.liveNumber == number }) else {
                return .failure(OrderParseError(message: "live display \(number) has no stored Monitors entry with Spaces; run `order-file show`"))
            }
            return .success(pair)
        }
        let hits = pairs.filter { pair in
            sameID(pair.stored.displayIdentifier, argument) || (pair.live.map { sameID($0.displayIdentifier, argument) } ?? false)
        }
        guard hits.count == 1, let pair = hits.first else {
            return .failure(OrderParseError(message: hits.isEmpty
                ? "--display \(argument) matches no display. \(known)"
                : "--display \(argument) matches \(hits.count) displays; use the display number"))
        }
        return .success(pair)
    }

    private static func parsePositions(_ text: String, count: Int) -> Result<[Int], OrderParseError> {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var positions: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return .failure(OrderParseError(message: "--order: \"\(part)\" is not a number")) }
            positions.append(n)
        }
        guard positions.count == count else {
            return .failure(OrderParseError(message: "--order lists \(positions.count) position(s) but the display has \(count) Spaces; "
                                            + "list every current position 1...\(count) once, e.g. "
                                            + (1...count).map(String.init).joined(separator: ",")))
        }
        guard positions.allSatisfy({ (1...count).contains($0) }), Set(positions).count == count else {
            return .failure(OrderParseError(message: "--order must use each position 1...\(count) exactly once"))
        }
        return .success(positions)
    }

    private static func performApply(stored: StoredDisplayOrder,
                                     target: DisplaySpaces, newUUIDs: [String], tokens: [String: String],
                                     orderArg: String, leftBefore: Bool, leftAfter: Bool,
                                     liveBefore: [DisplaySpaces]) -> Int32 {
        var result = LabResult(test: "order-file-apply")
        let storedID = stored.displayIdentifier
        let liveID = target.displayIdentifier
        result.observe("display", storedID)
        result.observe("display-live-identifier", liveID)
        result.observe("order-argument", orderArg)
        result.observe("spaces-before", orderLine(stored.monitorUUIDs, tokens))
        result.observe("spaces-expected", orderLine(newUUIDs, tokens))
        result.observe("uuids-before", stored.monitorUUIDs.joined(separator: ","))
        result.observe("uuids-expected", newUUIDs.joined(separator: ","))
        result.observe("ordering-entry", stored.orderingDisplayID ?? "?")
        result.observe("fullscreen-left-of-desktop1-before", String(leftBefore))
        result.observe("fullscreen-left-of-desktop1-requested", String(leftAfter))
        result.observe("mru-spaces", String(mruSpacesOn()))
        result.step("preflight ok: stored order equals live order, layout accepted, Dock running")

        var backupURL: URL?
        var passed = false
        do {
            let url = try SpaceOrderFile.backup(to: backupsFolder)
            backupURL = url
            result.observe("backup-file", url.path)
            result.step("backup written: \(url.path)")
            printBackupBanner(url)

            // Re-read right before writing: the new config is built from fresh data, and the write is
            // abandoned if the stored order moved since the dry-run check.
            let fresh = try SpaceOrderFile.readDomain()
            guard SpaceOrderFile.parseStoredOrder(fresh).first(where: { sameID($0.displayIdentifier, storedID) })?.monitorUUIDs
                    == stored.monitorUUIDs else {
                throw SpaceOrderFileError.spaceSetMismatch("the stored order changed while the command was running; nothing was written")
            }
            let newConfig = try SpaceOrderFile.reordered(fresh, displayID: storedID, newOrderUUIDs: newUUIDs)
            try SpaceOrderFile.write(newConfig)
            result.step("wrote new order to com.apple.spaces")
            let written = SpaceOrderFile.inspect(try SpaceOrderFile.readDomain()).displays
                .first { sameID($0.displayIdentifier, storedID) }
            let writtenOK = written?.monitorUUIDs == newUUIDs && written?.orderingLiveUUIDs == newUUIDs
            result.observe("stored-after-write-matches", String(writtenOK))
            result.step("read back after write: \(writtenOK ? "both arrays hold the new order" : "MISMATCH")")
            print("Wrote the new order. Restarting the Dock ...")

            let restart = try SpaceOrderFile.restartDock()
            result.observe("dock-pid-before", restart.oldPID.map(String.init) ?? "none")
            result.observe("dock-pid-after", String(restart.newPID))
            result.observe("seconds-until-dock", String(format: "%.1f", restart.secondsUntilDock))
            result.observe("seconds-until-spaces", String(format: "%.1f", restart.secondsUntilSpaces))
            let oldPID = restart.oldPID.map(String.init) ?? "none"
            let dockSeconds = String(format: "%.1f", restart.secondsUntilDock)
            let spacesSeconds = String(format: "%.1f", restart.secondsUntilSpaces)
            result.step("Dock restarted (pid \(oldPID) -> \(restart.newPID)), Dock up after \(dockSeconds) s, "
                        + "SpaceReader answered after \(spacesSeconds) s")

            // The Dock may need a moment after it is back before the live order is final.
            let matchedAfter = waitUntil(timeout: 10, interval: 0.5) { liveUUIDs(liveID) == newUUIDs }
            let liveAfter = liveUUIDs(liveID)
            let matches = matchedAfter != nil
            passed = matches
            result.observe("live-matches-expected", String(matches))
            if let matchedAfter { result.observe("seconds-until-live-matched", String(format: "%.1f", matchedAfter)) }
            result.observe("live-after", orderLine(liveAfter ?? [], tokens))
            result.observe("uuids-live-after", (liveAfter ?? []).joined(separator: ","))
            result.step("live order after restart \(matches ? "MATCHES" : "does NOT match") the requested order")

            let setIntact = Set(liveAfter ?? []) == Set(stored.monitorUUIDs)
            result.observe("space-set-intact", String(setIntact))
            let othersBefore = Dictionary(uniqueKeysWithValues: liveBefore.filter { !sameID($0.displayIdentifier, liveID) }
                .map { ($0.displayIdentifier.lowercased(), $0.spaces.map(\.uuid)) })
            let liveNow = (try? SpaceReader.displays()) ?? []
            let othersUnchanged = othersBefore.allSatisfy { key, uuids in
                liveNow.first { $0.displayIdentifier.lowercased() == key }?.spaces.map(\.uuid) == uuids
            }
            result.observe("other-displays-unchanged", String(othersUnchanged))

            // Did the Dock keep what we wrote, or write its own state back over it?
            let after = SpaceOrderFile.inspect(try SpaceOrderFile.readDomain()).displays
                .first { sameID($0.displayIdentifier, storedID) }
            let storedAfterMonitors = after?.monitorUUIDs
            let storedAfterOrdering = after?.orderingLiveUUIDs
            result.observe("stored-after-restart-monitors", orderLine(storedAfterMonitors ?? [], tokens))
            result.observe("stored-after-restart-ordering", orderLine(storedAfterOrdering ?? [], tokens))
            let kept = storedAfterMonitors == newUUIDs && storedAfterOrdering == newUUIDs
            let reverted = storedAfterMonitors == stored.monitorUUIDs
            result.observe("stored-after-restart-kept", String(kept))
            result.observe("stored-after-restart-reverted", String(reverted))
            result.step("stored order after restart: \(kept ? "still the new order" : reverted ? "back to the old order" : "something else")")

            print("")
            print("Live order now: \(orderLine(liveAfter ?? [], tokens))")
            print("Expected:       \(orderLine(newUUIDs, tokens))")
            print("Space set intact: \(setIntact ? "yes" : "NO"); other displays unchanged: \(othersUnchanged ? "yes" : "NO")")
            print("Stored file after restart: \(kept ? "still holds the new order" : reverted ? "was reverted to the old order" : "holds a different order")")
            if matches {
                print("RESULT: PASS - the Dock restart picked up the rewritten order.")
                if leftAfter { print("        A full-screen Space is now left of Desktop 1 (live order confirms it).") }
            } else if kept {
                print("RESULT: FAIL - the file kept the new order but the live order did not change: the Dock ignores it at startup.")
            } else if reverted {
                print("RESULT: FAIL - the stored order was reverted: the Dock/WindowServer wrote its own state back over the file.")
            } else {
                print("RESULT: FAIL - the live order does not match the requested order.")
            }
            if !setIntact || !othersUnchanged {
                print("WARNING: the Space set or another display changed. Restore the backup (see below).")
            }
            result.observe("verdict", matches ? "pass" : kept ? "ignored" : reverted ? "reverted" : "mismatch")
        } catch {
            result.observe("error", error.localizedDescription)
            result.step("FAILED: \(error.localizedDescription)")
            fputs("order-file: \(error.localizedDescription)\n", stderr)
            passed = false
        }

        result.passed = passed
        saveAndReport(&result)
        printRestoreHint(backupURL, heading: passed ? "TO GO BACK TO THE ORDER BEFORE THIS TEST"
                                                   : "IF ANYTHING LOOKS WRONG, RESTORE THIS BACKUP")
        return passed ? 0 : 1
    }

    // MARK: restore

    static func restore(_ args: [String]) -> Int32 {
        var file: String?
        var yes = false
        for arg in args {
            switch arg {
            case "--yes": yes = true
            case "-h", "--help":
                print(usage, terminator: "")
                return 0
            default:
                if arg.hasPrefix("-") { return usageError("restore: unknown option \(arg)") }
                if file != nil { return usageError("restore takes one backup file") }
                file = arg
            }
        }
        guard let file else { return usageError("restore needs a backup file") }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)

        // Read-only part: is this a backup we understand, and how does it differ from now?
        let backupConfig: [String: Any]
        do { backupConfig = try SpaceOrderFile.readBackup(url) } catch { return fail(error.localizedDescription) }
        let backupInspection = SpaceOrderFile.inspect(backupConfig)
        guard backupConfig["SpacesDisplayConfiguration"] != nil, !backupInspection.displays.isEmpty,
              backupInspection.layout.monitorsPath != nil else {
            return fail("\(url.path) does not look like a com.apple.spaces backup (no SpacesDisplayConfiguration with Spaces); refusing to import it")
        }
        let currentInspection = (try? SpaceOrderFile.readDomain()).map(SpaceOrderFile.inspect)
        let live = (try? SpaceReader.displays()) ?? []

        let backupPairs = pairDisplays(stored: backupInspection.displays, live: live)
        print("Backup file: \(url.path)")
        for pair in backupPairs {
            let display = pair.stored
            var tokens = storedTokens(display)
            let current = currentInspection?.displays.first { sameID($0.displayIdentifier, display.displayIdentifier) }
            let liveNow = pair.live
            if let current { tokens.merge(storedTokens(current)) { backup, _ in backup } }
            if let liveNow { tokens.merge(liveTokens(liveNow)) { backup, _ in backup } }
            print("Display \(display.displayIdentifier)")
            print("  backup holds: " + orderLine(display.monitorUUIDs, tokens))
            print("  stored now:   " + (current.map { orderLine($0.monitorUUIDs, tokens) } ?? "(no such display stored)"))
            print("  live now:     " + (liveNow.map { orderLine($0.spaces.map(\.uuid), tokens) } ?? "(no such live display)"))
        }

        guard yes else {
            print("")
            print("Dry run: nothing imported, Dock not restarted. Add --yes to import this backup (replaces the whole com.apple.spaces domain) and restart the Dock.")
            return 0
        }
        if SpaceOrderFile.dockPID() == nil { return fail("the Dock is not running, so there is nothing to restart. Refusing.") }

        var result = LabResult(test: "order-file-restore")
        result.observe("backup-file", url.path)
        var passed: Bool?
        do {
            // Take a backup of the current state first, so the restore itself can be undone.
            let safety = try SpaceOrderFile.backup(to: backupsFolder)
            result.observe("pre-restore-backup", safety.path)
            result.step("backed up the current state first: \(safety.path)")
            printBackupBanner(safety, heading: "STATE BEFORE THIS RESTORE SAVED")

            try SpaceOrderFile.restore(from: url)
            result.step("imported the backup into com.apple.spaces")
            print("Imported the backup. Restarting the Dock ...")

            let restart = try SpaceOrderFile.restartDock()
            result.observe("seconds-until-dock", String(format: "%.1f", restart.secondsUntilDock))
            result.observe("seconds-until-spaces", String(format: "%.1f", restart.secondsUntilSpaces))
            result.step(String(format: "Dock restarted, up after %.1f s, SpaceReader answered after %.1f s",
                               restart.secondsUntilDock, restart.secondsUntilSpaces))

            // Compare every backed-up display that still exists with the same Spaces; others cannot be judged.
            struct Check { var identifier: String; var expected: [String] }
            var checks: [Check] = []
            let liveNow = (try? SpaceReader.displays()) ?? []
            for pair in pairDisplays(stored: backupInspection.displays, live: liveNow) {
                let display = pair.stored
                if let liveDisplay = pair.live, Set(liveDisplay.spaces.map(\.uuid)) == Set(display.monitorUUIDs) {
                    checks.append(Check(identifier: liveDisplay.displayIdentifier, expected: display.monitorUUIDs))
                } else {
                    result.step("display \(display.displayIdentifier): live Spaces differ from the backup, order not compared")
                }
            }
            let allMatch: Bool? = checks.isEmpty ? nil : {
                waitUntil(timeout: 10, interval: 0.5) {
                    checks.allSatisfy { liveUUIDs($0.identifier) == $0.expected }
                } != nil
            }()
            passed = allMatch
            result.observe("displays-compared", String(checks.count))
            result.observe("live-matches-backup", allMatch.map(String.init) ?? "not compared")

            let afterInspection = SpaceOrderFile.inspect(try SpaceOrderFile.readDomain())
            let storedKept = backupInspection.displays.allSatisfy { display in
                afterInspection.displays.first { sameID($0.displayIdentifier, display.displayIdentifier) }?.monitorUUIDs
                    == display.monitorUUIDs
            }
            result.observe("stored-after-restart-matches-backup", String(storedKept))
            result.step("live order \(allMatch.map { $0 ? "matches" : "does NOT match" } ?? "was not compared with") the backup; stored order \(storedKept ? "matches" : "differs from") the backup")

            print("")
            switch allMatch {
            case .some(true): print("RESULT: PASS - the live order matches the backup (\(checks.count) display(s) compared).")
            case .some(false): print("RESULT: FAIL - the live order does not match the backup. Run `spaceslab order-file show` to see the difference.")
            case .none: print("RESULT: not decided - no display has the same Spaces as the backup, so the order was not compared. Check with `spaceslab spaces`.")
            }
        } catch {
            result.observe("error", error.localizedDescription)
            result.step("FAILED: \(error.localizedDescription)")
            fputs("order-file: \(error.localizedDescription)\n", stderr)
            passed = false
        }

        result.passed = passed
        saveAndReport(&result)
        return passed == false ? 1 : 0
    }
}
