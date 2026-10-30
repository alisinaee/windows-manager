import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import WMCore

/// A raise always ends as done, skipped or failed (never pending), and a repeated restore of a profile whose
/// windows already sit where they were saved plans no moves.
@Suite struct RestoreRepeatTests {
    typealias F = RestoreFixtures

    static let calculator = AppRef(bundleID: "com.apple.calculator", name: "Calculator")

    static func moves(_ plan: RestorePlan) -> [String] {
        plan.steps.map(\.kind).filter { $0 == "setFrame" || $0 == "moveToDesktop" }
    }

    // MARK: Raise outcome

    @Test func unsupportedRaiseWithStageManagerOnIsSkipped() {
        for e in [AXError.actionUnsupported, .attributeUnsupported] {
            let result = RaiseOutcome.result(for: e, stageManagerOn: true)
            #expect(result.skippedReason != nil)
            #expect(result.succeeded == false)
        }
    }

    @Test func unsupportedRaiseWithStageManagerOffIsFailedNotSkipped() {
        for e in [AXError.actionUnsupported, .attributeUnsupported] {
            let result = RaiseOutcome.result(for: e, stageManagerOn: false)
            #expect(result.skippedReason == nil)
            #expect(result.succeeded == false)
            #expect(result.detail == "the window did not accept AXRaise (AXError \(e.rawValue))")
        }
    }

    @MainActor @Test func raiseStepsEndAsDoneOrSkippedOrFailedNeverPending() async {
        // Calculator is saved in front of Slack, so both windows get a raise step.
        let profile = F.profile([F.snap(1, Self.calculator, z: 1), F.snap(2, F.slack, z: 0)])
        let scans = [F.scan([F.live(101, Self.calculator), F.live(102, F.slack)])]

        // Stage Manager case: the window sits in another stage, so its raise is skipped.
        let stage = FakeRestoreEnvironment(scans: scans)
        stage.skips["raise:101"] = "the window cannot be raised (it sits in another Stage Manager stage or Space)"
        let stageReport = await RestoreEngine(environment: stage).run(profile)
        let stageRaises = stageReport.steps.filter { $0.kind == "raise" }
        #expect(stageRaises.count == 2)
        #expect(stageRaises.allSatisfy { $0.status.isDone || $0.status.isSkipped || $0.status.isFailed })
        #expect(stageRaises.contains { $0.status.isSkipped })
        #expect(stageRaises.contains { $0.app == "Calculator" })

        // Non-Stage-Manager case: an unsupported AXRaise is a failure, and the step still ends (not pending).
        let plain = FakeRestoreEnvironment(scans: scans)
        plain.failures["raise:101"] = "the window did not accept AXRaise (AXError \(AXError.actionUnsupported.rawValue))"
        let plainReport = await RestoreEngine(environment: plain).run(profile)
        let plainRaises = plainReport.steps.filter { $0.kind == "raise" }
        #expect(plainRaises.count == 2)
        #expect(plainRaises.allSatisfy { $0.status.isDone || $0.status.isSkipped || $0.status.isFailed })
        #expect(plainRaises.contains { $0.status.isFailed })
        #expect(!plainRaises.contains { $0.status.isSkipped })
    }

    // MARK: Repeated restore

    @Test func repeatedRestoreWithWindowsInPlacePlansNoMoves() {
        let profile = F.profile([F.snap(1, Self.calculator), F.snap(2, F.slack, frame: CGRect(x: 300, y: 300, width: 500, height: 400))])
        // Every live frame is within 1.5 pt of the saved one (position and size, both directions).
        let scan = F.scan([
            F.live(101, Self.calculator, frame: CGRect(x: 101.5, y: 98.5, width: 801, height: 598)),
            F.live(102, F.slack, frame: CGRect(x: 298.5, y: 301.5, width: 501.5, height: 398.5)),
        ])
        let plan = F.plan(profile, scan)
        #expect(Self.moves(plan).isEmpty)
        #expect(!plan.steps.contains { $0.kind == "setFrame" })
    }

    @Test func frameExactlyAtToleranceIsStillInPlace() {
        let profile = F.profile([F.snap(1, Self.calculator)])
        let scan = F.scan([F.live(101, Self.calculator, frame: CGRect(x: 102, y: 98, width: 802, height: 602))])
        #expect(Self.moves(F.plan(profile, scan)).isEmpty)
    }

    @Test func frameOffByMoreThanTolerancePlansAMove() {
        let profile = F.profile([F.snap(1, Self.calculator)])
        // 2.5 pt to the right: outside the 2 pt tolerance.
        let scan = F.scan([F.live(101, Self.calculator, frame: CGRect(x: 102.5, y: 100, width: 800, height: 600))])
        let plan = F.plan(profile, scan)
        #expect(Self.moves(plan) == ["setFrame"])
        guard case .setFrame(_, let frame, _, _) = plan.steps.first(where: { $0.kind == "setFrame" }) else {
            Issue.record("expected a setFrame step")
            return
        }
        #expect(frame == F.defaultFrame)
    }

    @Test func sizeOffByMoreThanTolerancePlansAMove() {
        let profile = F.profile([F.snap(1, Self.calculator)])
        // Height 3 pt too small: outside the 2 pt tolerance.
        let scan = F.scan([F.live(101, Self.calculator, frame: CGRect(x: 100, y: 100, width: 800, height: 597))])
        #expect(Self.moves(F.plan(profile, scan)) == ["setFrame"])
    }
}
