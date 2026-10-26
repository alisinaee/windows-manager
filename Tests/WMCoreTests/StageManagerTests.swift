import CoreGraphics
import Foundation
import Testing
@testable import WMCore

@Suite struct StageManagerTests {
    typealias F = RestoreFixtures

    static let far = CGRect(x: -5000, y: 100, width: 300, height: 200)

    @Test func offscreenDetection() {
        let displays = [F.displayA()]
        #expect(StageManager.isParkedOffscreen(Self.far, displays: displays))
        #expect(!StageManager.isParkedOffscreen(CGRect(x: 100, y: 100, width: 800, height: 600), displays: displays))
        // Sticking out a bit is fine.
        #expect(!StageManager.isParkedOffscreen(CGRect(x: -300, y: 100, width: 800, height: 600), displays: displays))
    }

    @Test func annotateMarksParkedWindowsOnlyWhenOn() {
        let parked = F.live(1, F.chrome, frame: Self.far)
        let shown = F.live(2, F.chrome)
        let full = F.live(3, F.notes, frame: Self.far, fullScreen: true)
        let scan = F.scan([parked, shown, full])
        let on = StageManager.annotate(scan, provider: .fixed(true))
        #expect(on.stageManagerOn == true)
        #expect(on.windows.map(\.isInStageStrip) == [true, false, false])
        let off = StageManager.annotate(scan, provider: .fixed(false))
        #expect(off.stageManagerOn == false)
        #expect(off.windows.allSatisfy { !$0.isInStageStrip })
        #expect(StageManager.annotate(scan, provider: .fixed(nil)).stageManagerOn == nil)
    }

    @Test func captureRecordsStageManager() {
        let scan = WorkspaceScan(displays: [F.displayA()], windows: [F.live(1, F.chrome)], stageManagerOn: true)
        #expect(ProfileCapture.makeProfile(name: "p", from: scan).0.stageManagerOn == true)
        let plain = WorkspaceScan(displays: [F.displayA()], windows: [F.live(1, F.chrome)])
        #expect(ProfileCapture.makeProfile(name: "p", from: plain).0.stageManagerOn == nil)
    }

    @Test func profileFieldIsAdditive() throws {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.stageManagerOn = true
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(Profile.self, from: data).stageManagerOn == true)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "stageManagerOn")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Profile.self, from: old).stageManagerOn == nil)
    }

    @Test func parkedWindowIsLeftAloneWithWarning() {
        let moved = CGRect(x: 10, y: 10, width: 500, height: 400)
        let profile = F.profile([F.snap(1, F.chrome, title: "A", index: 0), F.snap(2, F.chrome, title: "B", index: 1)])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: moved, index: 0),
                           F.live(11, F.chrome, title: "B", frame: Self.far, index: 1, ).withStrip()])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.steps.allSatisfy { $0.target?.windowID != 11 })
        #expect(plan.steps.contains { $0.target?.windowID == 10 })
        #expect(plan.unmatched.isEmpty)
        #expect(plan.warnings.contains { $0.contains("Stage Manager is on") && $0.contains("11") })
    }

    @Test func parkedWindowIsMovedWhenStageManagerIsOff() {
        let profile = F.profile([F.snap(1, F.chrome, title: "A")])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: Self.far).withStrip()])
        scan.stageManagerOn = false
        let plan = F.plan(profile, scan)
        #expect(plan.steps.contains { $0.target?.windowID == 10 })
        #expect(!plan.warnings.contains { $0.contains("Stage Manager is on") })
    }

    @Test func missingWindowWithParkedSiblingIsAWarningNotMissing() {
        let profile = F.profile([F.snap(1, F.chrome, title: "A", index: 0), F.snap(2, F.chrome, title: "B", index: 1),
                                   F.snap(3, F.chrome, title: "C", index: 2)])
        var scan = F.scan([F.live(10, F.chrome, title: "A", frame: F.defaultFrame, index: 0),
                           F.live(12, F.chrome, title: "Z", frame: Self.far, index: 1).withStrip()])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.warnings.contains { $0.contains("may be in the strip") })
    }

    @Test func differingStateIsOnlyInformational() {
        var profile = F.profile([F.snap(1, F.chrome)])
        profile.stageManagerOn = false
        var scan = F.scan([F.live(10, F.chrome)])
        scan.stageManagerOn = true
        let plan = F.plan(profile, scan)
        #expect(plan.warnings.contains { $0.contains("was off when this profile was captured") })
        #expect(!plan.warnings.joined().lowercased().contains("turn"))
    }
}

private extension LiveWindow {
    func withStrip() -> LiveWindow { var copy = self; copy.isInStageStrip = true; return copy }
}
