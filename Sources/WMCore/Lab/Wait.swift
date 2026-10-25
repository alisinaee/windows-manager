import Foundation

/// Polls `condition` until it is true or `timeout` seconds pass.
/// Returns the elapsed seconds, or nil on timeout. The run loop keeps spinning between polls so
/// AX and AppKit notifications keep being delivered.
@discardableResult
public func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> TimeInterval? {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() { return ProcessInfo.processInfo.systemUptime - start }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if elapsed >= timeout { return nil }
        let step = min(interval, timeout - elapsed)
        // run(mode:before:) returns at once when the run loop has no sources, so sleep in that case.
        if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: step)) {
            Thread.sleep(forTimeInterval: step)
        }
    }
}
