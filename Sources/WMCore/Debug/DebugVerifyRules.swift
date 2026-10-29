import CoreGraphics
import Foundation

// Extra pure verify rules (P6.125): size-limited pass, idempotence, inconclusive on missing data, duplicate ids.

/// Per-window frame a restore run left behind, keyed by window id, for the idempotence comparison.
public typealias DebugFrameSnapshot = [UInt32: CGRect]

public extension DebugVerify {
    /// A window that cannot reach the wanted size passes when it ended exactly at the size limit learned earlier
    /// (the app's minimum or maximum). `learned` nil or an unmeasured result gives an INCONCLUSIVE pass, never a fail.
    static func sizeLimitedCheck(id: String, label: String, wanted: CGRect, actual: CGRect?,
                                 learnedLimit learned: CGSize?) -> DebugCheck {
        let name = "\(label): size-limited window"
        guard let actual else {
            return DebugCheck(id: id, name: name, passed: true, detail: "INCONCLUSIVE: window frame is missing")
        }
        if framesMatch(actual, wanted) {
            return DebugCheck(id: id, name: name, passed: true, detail: "reached the wanted size")
        }
        guard let learned else {
            return DebugCheck(id: id, name: name, passed: true, detail: "INCONCLUSIVE: no learned size limit")
        }
        let atLimit = abs(actual.width - learned.width) <= tolerance && abs(actual.height - learned.height) <= tolerance
        return DebugCheck(id: id, name: name, passed: atLimit,
                          detail: atLimit ? "at the learned limit \(Int(learned.width))x\(Int(learned.height))"
                              : "is \(describe(actual)), learned limit \(Int(learned.width))x\(Int(learned.height))")
    }

    /// A second run must change nothing: every window id present in both snapshots keeps its frame. Empty data on
    /// either side is INCONCLUSIVE (pass). Windows that appear or vanish between runs fail.
    static func idempotenceChecks(first: DebugFrameSnapshot, second: DebugFrameSnapshot) -> [DebugCheck] {
        if first.isEmpty || second.isEmpty {
            return [DebugCheck(id: "idempotence", name: "second run changes nothing", passed: true,
                               detail: "INCONCLUSIVE: no windows captured after the \(first.isEmpty ? "first" : "second") run")]
        }
        var checks: [DebugCheck] = []
        for id in Set(first.keys).union(second.keys).sorted() {
            let name = "window \(id): unchanged by second run"
            switch (first[id], second[id]) {
            case let (a?, b?):
                let same = framesMatch(a, b)
                checks.append(DebugCheck(id: "idem-\(id)", name: name, passed: same,
                                         detail: same ? "same frame" : "moved \(describe(a)) -> \(describe(b))"))
            case (_?, nil):
                checks.append(DebugCheck(id: "idem-\(id)", name: name, passed: false, detail: "window gone after second run"))
            default:
                checks.append(DebugCheck(id: "idem-\(id)", name: name, passed: false, detail: "window appeared during second run"))
            }
        }
        return checks
    }

    /// Window ids must be unique in one scan; a repeat means the scan or the pairing is unreliable.
    static func duplicateIDChecks(live: [DebugLiveWindow]) -> [DebugCheck] {
        var counts: [UInt32: Int] = [:]
        for w in live { counts[w.windowID, default: 0] += 1 }
        let dups = counts.filter { $0.value > 1 }.keys.sorted()
        if dups.isEmpty {
            return [DebugCheck(id: "dup-ids", name: "window ids unique", passed: true, detail: "\(live.count) window(s)")]
        }
        return dups.map {
            DebugCheck(id: "dup-id-\($0)", name: "window ids unique", passed: false,
                       detail: "window id \($0) appears \(counts[$0] ?? 0) times")
        }
    }
}
