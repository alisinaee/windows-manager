import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of SpaceMover: choosing the target Desktop, judging a read-back, and the
/// outcome record. No system calls are made and nothing is moved.
@Suite struct SpaceMoverTests {
    // MARK: Fixture

    private static func desktop(_ id: UInt64, index: Int, current: Bool = false) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "D\(id)", kind: .desktop, index: index, isCurrent: current)
    }

    private static func fullScreen(_ id: UInt64, index: Int, app: String, window: UInt32) -> SpaceInfo {
        SpaceInfo(id: id, uuid: "F\(id)", kind: .fullscreen, index: index, isCurrent: false,
                  fullScreenOwnerPID: 100, fullScreenWindowIDs: [window], ownerAppNames: [app])
    }

    /// Main: FS(37) D1(1) FS(59) D2(2) D3(3). Second display: D1(67) FS(73) D2(68).
    private static let displays: [DisplaySpaces] = [
        DisplaySpaces(displayIdentifier: "Main", displayName: "Built-in", currentSpaceID: 1, spaces: [
            fullScreen(37, index: 0, app: "Google Chrome", window: 84),
            desktop(1, index: 1, current: true),
            fullScreen(59, index: 2, app: "Arc", window: 337),
            desktop(2, index: 3),
            desktop(3, index: 4),
        ]),
        DisplaySpaces(displayIdentifier: "37D8832A-2D66-02CA-B9F7-8F30A301B230", displayName: "External",
                      currentSpaceID: 67, spaces: [
            desktop(67, index: 0, current: true),
            fullScreen(73, index: 1, app: "Code", window: 506),
            desktop(68, index: 2),
        ]),
    ]

    // MARK: Choosing the target Desktop

    @Test func desktopNumberSkipsFullScreenSpaces() throws {
        // Window on Desktop 1; Mission Control order has a full-screen Space between Desktop 1 and 2.
        let second = try SpaceMover.plan(windowSpaceIDs: [1], target: .desktopNumber(2), displays: Self.displays)
        #expect(second.targetSpaceID == 2)
        #expect(second.targetDesktopNumber == 2)
        #expect(second.sourceSpaceID == 1)
        #expect(second.sourceDesktopNumber == 1)
        #expect(!second.isNoOp)
        #expect(!second.isCrossDisplay)

        let third = try SpaceMover.plan(windowSpaceIDs: [1], target: .desktopNumber(3), displays: Self.displays)
        #expect(third.targetSpaceID == 3)
    }

    @Test func desktopNumberIsRelativeToTheWindowsDisplay() throws {
        // The same "Desktop 2" is Space 2 on the main display and Space 68 on the external one.
        let external = try SpaceMover.plan(windowSpaceIDs: [67], target: .desktopNumber(2), displays: Self.displays)
        #expect(external.targetSpaceID == 68)
        #expect(external.sourceDisplay == "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        #expect(external.targetDisplay == external.sourceDisplay)

        let main = try SpaceMover.plan(windowSpaceIDs: [3], target: .desktopNumber(2), displays: Self.displays)
        #expect(main.targetSpaceID == 2)
        #expect(main.sourceDesktopNumber == 3)
    }

    @Test func desktopNumberOutOfRangeIsRefused() {
        #expect(throws: MovePlanError.noSuchDesktop(number: 4, available: 3, display: "Main")) {
            try SpaceMover.plan(windowSpaceIDs: [1], target: .desktopNumber(4), displays: Self.displays)
        }
        #expect(throws: MovePlanError.noSuchDesktop(number: 0, available: 3, display: "Main")) {
            try SpaceMover.plan(windowSpaceIDs: [1], target: .desktopNumber(0), displays: Self.displays)
        }
        // The external display only has two Desktops.
        #expect(throws: MovePlanError.noSuchDesktop(number: 3, available: 2,
                                                   display: "37D8832A-2D66-02CA-B9F7-8F30A301B230")) {
            try SpaceMover.plan(windowSpaceIDs: [67], target: .desktopNumber(3), displays: Self.displays)
        }
    }

    @Test func sameDesktopIsANoOp() throws {
        let plan = try SpaceMover.plan(windowSpaceIDs: [2], target: .desktopNumber(2), displays: Self.displays)
        #expect(plan.isNoOp)
        let byID = try SpaceMover.plan(windowSpaceIDs: [2], target: .spaceID(2), displays: Self.displays)
        #expect(byID.isNoOp)
    }

    // MARK: Target by Space id

    @Test func spaceIDTargetsADesktopOnAnyDisplay() throws {
        let plan = try SpaceMover.plan(windowSpaceIDs: [1], target: .spaceID(68), displays: Self.displays)
        #expect(plan.targetSpaceID == 68)
        #expect(plan.targetDesktopNumber == 2)
        #expect(plan.isCrossDisplay)
    }

    @Test func fullScreenTargetIsRefusedWithAClearMessage() {
        #expect(throws: MovePlanError.targetNotDesktop(37, "a full-screen Space (Google Chrome)")) {
            try SpaceMover.plan(windowSpaceIDs: [1], target: .spaceID(37), displays: Self.displays)
        }
        let message = MovePlanError.targetNotDesktop(37, "a full-screen Space (Google Chrome)").errorDescription ?? ""
        #expect(message.contains("full-screen"))
        #expect(message.contains("Google Chrome"))
        #expect(message.contains("Desktop"))
    }

    @Test func unknownTargetSpaceIsRefused() {
        #expect(throws: MovePlanError.unknownSpace(999)) {
            try SpaceMover.plan(windowSpaceIDs: [1], target: .spaceID(999), displays: Self.displays)
        }
    }

    // MARK: Refusing bad windows

    @Test func windowInAFullScreenSpaceIsRefused() {
        #expect(throws: MovePlanError.sourceNotDesktop("a full-screen Space (Arc)")) {
            try SpaceMover.plan(windowSpaceIDs: [59], target: .desktopNumber(1), displays: Self.displays)
        }
    }

    @Test func windowOnNoSpaceOrSeveralSpacesIsRefused() {
        #expect(throws: MovePlanError.windowOnNoSpace) {
            try SpaceMover.plan(windowSpaceIDs: [], target: .desktopNumber(1), displays: Self.displays)
        }
        #expect(throws: MovePlanError.windowOnSeveralSpaces(3)) {
            try SpaceMover.plan(windowSpaceIDs: [1, 2, 3], target: .desktopNumber(1), displays: Self.displays)
        }
    }

    @Test func windowOnAnUnknownSpaceIsRefused() {
        #expect(throws: MovePlanError.unknownSpace(555)) {
            try SpaceMover.plan(windowSpaceIDs: [555], target: .desktopNumber(1), displays: Self.displays)
        }
    }

    @Test func everyPlanErrorHasAMessage() {
        let errors: [MovePlanError] = [
            .windowOnNoSpace, .windowOnSeveralSpaces(2), .unknownSpace(7), .sourceNotDesktop("a full-screen Space"),
            .targetNotDesktop(1, "a full-screen Space"), .noSuchDesktop(number: 9, available: 1, display: "Main"),
        ]
        for error in errors { #expect(!(error.errorDescription ?? "").isEmpty) }
    }

    // MARK: Judging a read-back

    @Test func movedMeansExactlyOnTheTargetSpace() {
        #expect(SpaceMover.isMoved(spaces: [10: [5]], windows: [10], target: 5))
        #expect(!SpaceMover.isMoved(spaces: [10: [1]], windows: [10], target: 5))
        // On the target and still somewhere else (all Desktops, or half way): not moved yet.
        #expect(!SpaceMover.isMoved(spaces: [10: [1, 5]], windows: [10], target: 5))
        #expect(!SpaceMover.isMoved(spaces: [10: []], windows: [10], target: 5))
        #expect(!SpaceMover.isMoved(spaces: [:], windows: [10], target: 5))
    }

    @Test func allWindowsMustBeOnTheTarget() {
        #expect(SpaceMover.isMoved(spaces: [10: [5], 11: [5]], windows: [10, 11], target: 5))
        #expect(!SpaceMover.isMoved(spaces: [10: [5], 11: [1]], windows: [10, 11], target: 5))
        #expect(!SpaceMover.isMoved(spaces: [10: [5]], windows: [], target: 5))
    }

    // MARK: Methods and outcome record

    @Test func methodNamesAreStable() {
        #expect(MoveMethod.allCases.map(\.rawValue) == ["bridgedExported", "bridgedScanned", "compatID", "legacy"])
        for method in MoveMethod.allCases { #expect(MoveMethod(rawValue: method.rawValue) == method) }
        #expect(MoveMethod(rawValue: "nonsense") == nil)
    }

    private static func sampleOutcome() -> MoveOutcome {
        MoveOutcome(
            windowIDs: [4242],
            targetSpaceID: 2,
            requestedMethod: nil,
            spacesBefore: ["4242": [1]],
            alreadyOnTarget: false,
            appKitReady: true,
            attempts: [
                MethodAttempt(method: .bridgedExported, invoked: false,
                              detail: "skipped, not available: SkyLight does not export it"),
                MethodAttempt(method: .bridgedScanned, invoked: true, detail: "built operation; performed",
                              verified: true, late: false, secondsToVerify: 0.25, spacesAfter: ["4242": [2]]),
            ],
            succeededWith: .bridgedScanned,
            verifiedSpaces: ["4242": [2]],
            elapsed: 0.5
        )
    }

    @Test func outcomeRoundTripsThroughJSON() throws {
        let outcome = Self.sampleOutcome()
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(MoveOutcome.self, from: data)
        #expect(decoded == outcome)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"bridgedScanned\""))
        #expect(text.contains("\"bridgedExported\""))
        #expect(text.contains("\"4242\""))
    }

    @Test func outcomeSuccessFollowsTheVerifiedMethod() {
        var outcome = Self.sampleOutcome()
        #expect(outcome.success)

        outcome.succeededWith = nil
        #expect(!outcome.success)

        // Nothing to do because the window was already there still counts as success.
        outcome.alreadyOnTarget = true
        #expect(outcome.success)
    }

    @Test func failedOutcomeKeepsEveryAttempt() throws {
        var outcome = Self.sampleOutcome()
        outcome.succeededWith = nil
        outcome.attempts[1].verified = false
        outcome.attempts[1].secondsToVerify = nil
        outcome.verifiedSpaces = ["4242": [1]]

        let decoded = try JSONDecoder().decode(MoveOutcome.self, from: JSONEncoder().encode(outcome))
        #expect(!decoded.success)
        #expect(decoded.attempts.count == 2)
        #expect(decoded.attempts[1].secondsToVerify == nil)
        #expect(decoded.verifiedSpaces["4242"] == [1])
    }
}
