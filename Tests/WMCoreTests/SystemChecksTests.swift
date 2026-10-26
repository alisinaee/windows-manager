import Foundation
import Testing
@testable import WMCore

/// Tests for the pure report builder. They never read the real system settings.
@Suite struct SystemChecksTests {
    @Test func emptyValuesGiveMacOSDefaults() {
        let report = SystemChecks.make(from: [:])
        #expect(report.accessibilityTrusted == false)
        #expect(report.autoRearrangeSpaces == true)
        #expect(report.displaysHaveSeparateSpaces == true)
        #expect(report.stageManagerOn == false)
        #expect(report.switchToSpaceWithOpenWindows == true)
        #expect(report.macOSVersion == "unknown")
    }

    @Test func nilAndNullCountAsMissing() {
        let report = SystemChecks.make(from: [
            SystemChecks.Key.autoRearrangeSpaces: nil,
            SystemChecks.Key.stageManager: NSNull(),
            SystemChecks.Key.switchToSpaceWithOpenWindows: NSNull(),
            SystemChecks.Key.macOSVersion: "",
        ])
        #expect(report.autoRearrangeSpaces == true)
        #expect(report.stageManagerOn == false)
        #expect(report.switchToSpaceWithOpenWindows == true)
        #expect(report.macOSVersion == "unknown")
    }

    @Test func accessibilityFlag() {
        #expect(SystemChecks.make(from: [SystemChecks.Key.accessibilityTrusted: true]).accessibilityTrusted)
        #expect(!SystemChecks.make(from: [SystemChecks.Key.accessibilityTrusted: false]).accessibilityTrusted)
    }

    @Test func autoRearrangeFlag() {
        #expect(SystemChecks.make(from: ["mru-spaces": true]).autoRearrangeSpaces)
        #expect(!SystemChecks.make(from: ["mru-spaces": false]).autoRearrangeSpaces)
    }

    @Test func separateSpacesIsTheOppositeOfSpansDisplays() {
        #expect(SystemChecks.make(from: ["spans-displays": false]).displaysHaveSeparateSpaces)
        #expect(!SystemChecks.make(from: ["spans-displays": true]).displaysHaveSeparateSpaces)
        #expect(SystemChecks.make(from: [:]).displaysHaveSeparateSpaces)
    }

    @Test func stageManagerFlag() {
        #expect(SystemChecks.make(from: ["GloballyEnabled": true]).stageManagerOn)
        #expect(!SystemChecks.make(from: ["GloballyEnabled": false]).stageManagerOn)
    }

    @Test func switchToSpaceFlag() {
        #expect(SystemChecks.make(from: ["AppleSpacesSwitchOnActivate": true]).switchToSpaceWithOpenWindows)
        #expect(!SystemChecks.make(from: ["AppleSpacesSwitchOnActivate": false]).switchToSpaceWithOpenWindows)
    }

    @Test func versionIsPassedThrough() {
        #expect(SystemChecks.make(from: ["macOSVersion": "27.0.1"]).macOSVersion == "27.0.1")
    }

    @Test func numbersAndStringsAreAccepted() {
        let report = SystemChecks.make(from: [
            "mru-spaces": NSNumber(value: 0),
            "spans-displays": 1,
            "GloballyEnabled": "true",
            "AppleSpacesSwitchOnActivate": "0",
        ])
        #expect(!report.autoRearrangeSpaces)
        #expect(!report.displaysHaveSeparateSpaces)
        #expect(report.stageManagerOn)
        #expect(!report.switchToSpaceWithOpenWindows)
    }

    @Test func unreadableValuesFallBackToDefaults() {
        let report = SystemChecks.make(from: [
            "mru-spaces": "maybe",
            "GloballyEnabled": ["not", "a", "bool"],
        ])
        #expect(report.autoRearrangeSpaces == true)
        #expect(report.stageManagerOn == false)
    }

    @Test func allFlagsAtOnce() {
        let report = SystemChecks.make(from: [
            SystemChecks.Key.accessibilityTrusted: true,
            SystemChecks.Key.autoRearrangeSpaces: false,
            SystemChecks.Key.spansDisplays: true,
            SystemChecks.Key.stageManager: true,
            SystemChecks.Key.switchToSpaceWithOpenWindows: false,
            SystemChecks.Key.macOSVersion: "26.4",
        ])
        #expect(report == SystemReport(
            accessibilityTrusted: true, autoRearrangeSpaces: false, displaysHaveSeparateSpaces: false,
            stageManagerOn: true, switchToSpaceWithOpenWindows: false, macOSVersion: "26.4"))
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = SystemChecks.make(from: ["mru-spaces": false, "macOSVersion": "27.0.1"])
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(SystemReport.self, from: data) == report)
    }

    @Test func liveReportHasAVersion() {
        // Reads the real system, read only; only the shape is checked.
        let report = SystemChecks.report()
        #expect(report.macOSVersion != "unknown")
        #expect(report.macOSVersion.split(separator: ".").count == 3)
    }
}
