import Foundation
import SwiftUI
import WMCore

/// App side of the Space preference backups (P3.6). Lists backups, takes new ones and restores them after the
/// user confirms in `BackupSection`. Only `restore(_:confirmed:)` changes system preferences, and it is called
/// with `confirmed: true` only from the confirmation alert.
@MainActor
final class BackupController: ObservableObject {
    @Published private(set) var backups: [BackupInfo] = []
    /// One line for the section: what the last action did.
    @Published private(set) var status: String = ""
    /// The backup waiting for the user's confirmation. Setting it shows the alert.
    @Published var pendingRestore: BackupInfo?

    private let backup: SpaceBindingsBackup

    init(backup: SpaceBindingsBackup = SpaceBindingsBackup()) {
        self.backup = backup
        refresh()
    }

    func refresh() {
        backups = backup.list()
    }

    func backUpNow() {
        do {
            let info = try backup.backupNow(reason: "manual")
            status = "Backed up at \(info.date.formatted(date: .omitted, time: .standard))."
        } catch {
            status = error.localizedDescription
        }
        refresh()
    }

    /// Restores `info`. Refuses (and changes nothing) unless `confirmed` is true.
    func restore(_ info: BackupInfo, confirmed: Bool) {
        do {
            try backup.restore(info, confirmed: confirmed, killDock: true)
            status = "Restored the backup from \(info.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            status = error.localizedDescription
        }
        refresh()
    }

    static func describe(_ info: BackupInfo) -> String {
        info.reason == "manual" ? "Manual backup" : info.reason.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
