import Testing
import Foundation
import CoreGraphics
@testable import WMCore

@Suite struct CLIRunResultsTests {
    func summary(_ name: String, _ id: UUID = UUID()) -> ProfileSummary {
        ProfileSummary(id: id, name: name, icon: "x", updatedAt: Date(), windowCount: 0)
    }

    func snapshot(_ app: String, bundle: String, restore: Bool = true) -> WindowSnapshot {
        WindowSnapshot(app: AppRef(bundleID: bundle, name: app), title: "t", displayUUID: "D",
                       frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                       relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), placement: .unknown)
    }

    @Test func lookupByNameIDAndPrefix() {
        let a = summary("Work"), b = summary("Home")
        let list = [a, b]
        #expect(CLIProfileLookup.resolve("work", in: list) == .found(a.id))
        #expect(CLIProfileLookup.resolve(b.id.uuidString.lowercased(), in: list) == .found(b.id))
        #expect(CLIProfileLookup.resolve("Ho", in: list) == .found(b.id))
        #expect(CLIProfileLookup.resolve("zzz", in: list) == .notFound)
        if case .ambiguous = CLIProfileLookup.resolve("Work", in: [a, summary("work")]) {} else { Issue.record("expected ambiguous") }
    }

    @Test func planGroupsByPhase() {
        let app = AppRef(bundleID: "b", name: "A")
        let t = RestoreTarget(snapshotID: UUID(), windowID: 5, pid: 1, app: app, title: "x")
        let plan = RestorePlan(profileName: "P", steps: [
            .launch(app: app, windowCount: 1),
            .setFrame(t, frame: CGRect(x: 1, y: 2, width: 3, height: 4), from: .zero, beforeFullScreen: false),
            .raise(t, zIndex: 0),
        ], unmatched: [UnmatchedSnapshot(snapshotID: UUID(), app: app, title: nil, reason: "gone")])
        let r = CLIPlanResult(profileID: UUID(), plan: plan)
        #expect(r.stepCount == 3)
        #expect(r.phases.map(\.phase) == ["launch", "setFrame", "raise"])
        #expect(r.phases[1].steps[0].frame?.width == 3)
        #expect(r.phases[1].steps[0].windowID == 5)
        #expect(r.exit == .partial)
        #expect(CLIPlanResult(profileID: UUID(), plan: RestorePlan(profileName: "P")).exit == .ok)
        #expect((try? JSONValue.from(r)) != nil)
    }

    @Test func progressEventFields() {
        let f = CLIRunEvents.fields(for: .stepFinished(index: 1, total: 2, description: "d", status: .failed("no"), elapsed: 0.5))
        #expect(f["stage"] == .string("step_finished"))
        #expect(f["status"] == .string("failed"))
        #expect(f["reason"] == .string("no"))
        #expect(CLIRunEvents.fields(for: .scanning)["stage"] == .string("scanning"))
        #expect(CLIRunEvents.fields(for: .launching([AppRef(bundleID: nil, name: "Z")]))["apps"] == .array([.string("Z")]))
    }

    @Test func runExitCode() {
        var report = RestoreReport(profileID: UUID(), profileName: "P")
        #expect(CLIRunOutcome.exit(for: report) == .ok)
        report.totals.windowsNotFound = 1
        #expect(CLIRunOutcome.exit(for: report) == .partial)
    }

    @Test func captureFilterSelectors() {
        let a = snapshot("Safari", bundle: "com.apple.Safari"), b = snapshot("Notes", bundle: "com.apple.Notes")
        let p = Profile(name: "P", monitorSetKey: "k", windows: [a, b])
        #expect(CLICaptureFilter.windowIDs(in: p, selectors: ["app:safari"]) == [a.id])
        #expect(CLICaptureFilter.windowIDs(in: p, selectors: ["com.apple.Notes"]) == [b.id])
        #expect(CLICaptureFilter.windowIDs(in: p, selectors: ["all"]).count == 2)
        #expect(CLICaptureFilter.windowIDs(in: p, selectors: ["nothing"]).isEmpty)
    }

    @Test func verifyDiffsPlan() {
        let a = snapshot("Safari", bundle: "s"), b = snapshot("Notes", bundle: "n"), c = snapshot("Mail", bundle: "m")
        let p = Profile(name: "P", monitorSetKey: "k", windows: [a, b, c])
        let t = RestoreTarget(snapshotID: a.id, windowID: 1, pid: 1, app: a.app, title: nil)
        let plan = RestorePlan(profileName: "P",
                               steps: [.setFrame(t, frame: .zero, from: .zero, beforeFullScreen: false)],
                               unmatched: [UnmatchedSnapshot(snapshotID: c.id, app: c.app, title: nil, reason: "none")])
        let r = CLIVerifyResult(profile: p, plan: plan)
        #expect(r.windows.map(\.status) == ["mismatch", "ok", "missing"])
        #expect(r.mismatches == 2 && !r.ok && r.exit == .partial)
        #expect(r.windows[0].pendingSteps.count == 1)
        let clean = CLIVerifyResult(profile: p, plan: RestorePlan(profileName: "P"))
        #expect(clean.ok && clean.exit == .ok)
    }
}
