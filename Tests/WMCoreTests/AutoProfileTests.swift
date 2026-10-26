import Foundation
import Testing
@testable import WMCore

/// Tests for the auto profile decision and its settings store. No display or profile file is touched.
@Suite struct AutoProfileTests {
    static let desk = "A+B"
    static let laptop = "LAPTOP"
    static let deskProfile = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!
    static let laptopProfile = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!
    static let saved = [
        AutoProfileCandidate(id: deskProfile, monitorSetKey: desk),
        AutoProfileCandidate(id: laptopProfile, monitorSetKey: laptop),
    ]
    static let now = Date(timeIntervalSince1970: 1_000_000)

    private func settings(enabled: Bool = true, triggers: AutoProfileTriggers = AutoProfileTriggers(),
                          mapping: [String: UUID] = [:], cooldown: Double = 60) -> AutoProfileSettings {
        AutoProfileSettings(enabled: enabled, triggers: triggers, mapping: mapping, delaySeconds: 3,
                            cooldownSeconds: cooldown)
    }

    private func decide(_ event: AutoProfileEvent = .monitorChange, key: String = Self.desk,
                        _ s: AutoProfileSettings, lastRun: Date? = nil,
                        saved: [AutoProfileCandidate] = Self.saved, now: Date = Self.now) -> UUID? {
        AutoProfileDecider.decide(event: event, currentMonitorSetKey: key, settings: s, savedProfiles: saved,
                                  lastRun: lastRun, now: now)
    }

    private func decide(_ s: AutoProfileSettings, key: String = Self.desk, lastRun: Date? = nil,
                        saved: [AutoProfileCandidate] = Self.saved, now: Date = Self.now) -> UUID? {
        decide(.monitorChange, key: key, s, lastRun: lastRun, saved: saved, now: now)
    }

    @Test func defaultsAreOffWithThreeSecondsAndSixtySecondCooldown() {
        let s = AutoProfileSettings()
        #expect(!s.enabled)
        #expect(s.delaySeconds == 3)
        #expect(s.cooldownSeconds == 60)
        #expect(s.triggers.monitorChange && s.triggers.wake && s.triggers.unlock)
        #expect(s.mapping.isEmpty)
    }

    @Test func disabledNeverFires() {
        #expect(decide(settings(enabled: false)) == nil)
        #expect(decide(.wake, settings(enabled: false)) == nil)
    }

    @Test func wrongTriggerDoesNotFire() {
        let onlyUnlock = AutoProfileTriggers(monitorChange: false, wake: false, unlock: true)
        #expect(decide(.monitorChange, settings(triggers: onlyUnlock)) == nil)
        #expect(decide(.wake, settings(triggers: onlyUnlock)) == nil)
        #expect(decide(.unlock, settings(triggers: onlyUnlock)) == Self.deskProfile)
    }

    @Test func noMatchingProfileDoesNotFire() {
        #expect(decide(key: "UNKNOWN", settings()) == nil)
        #expect(decide(settings()) != nil)
        #expect(decide(settings(), saved: []) == nil)
    }

    @Test func matchingProfileForTheCurrentMonitorSetFires() {
        #expect(decide(key: Self.laptop, settings()) == Self.laptopProfile)
        #expect(decide(key: Self.desk, settings()) == Self.deskProfile)
    }

    @Test func explicitMappingWinsOverCapturedKey() {
        let mapped = settings(mapping: [Self.desk: Self.laptopProfile])
        #expect(decide(key: Self.desk, mapped) == Self.laptopProfile)
    }

    @Test func mappingToAProfileThatNoLongerExistsDoesNotFire() {
        let gone = UUID()
        let s = settings(mapping: [Self.desk: gone])
        #expect(decide(key: Self.desk, s) == nil)
    }

    @Test func cooldownBlocksARunInsideTheWindow() {
        let s = settings(cooldown: 60)
        let recent = Self.now.addingTimeInterval(-30)
        #expect(decide(s, lastRun: recent) == nil)
        #expect(decide(s, lastRun: Self.now.addingTimeInterval(-60)) == Self.deskProfile)
        #expect(decide(s, lastRun: Self.now.addingTimeInterval(-120)) == Self.deskProfile)
    }

    @Test func zeroCooldownAllowsImmediateRuns() {
        #expect(decide(settings(cooldown: 0), lastRun: Self.now) == Self.deskProfile)
    }

    @Test func oneBurstOfEventsDecidesOnce() {
        // A burst (display change, then wake, then unlock) is collapsed by the caller into one decision.
        // The first decision starts a run; the caller records it as lastRun, so the rest is refused.
        let s = settings()
        let first = decide(.monitorChange, s, lastRun: nil)
        #expect(first == Self.deskProfile)
        #expect(decide(.wake, s, lastRun: Self.now) == nil)
        #expect(decide(.unlock, s, lastRun: Self.now.addingTimeInterval(1)) == nil)
    }

    @Test func settingsRoundTripThroughTheStore() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoProfileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("auto-profile.json")
        let store = AutoProfileStore(fileURL: url)

        #expect(store.load() == AutoProfileSettings())

        var s = AutoProfileSettings(enabled: true, triggers: AutoProfileTriggers(monitorChange: true, wake: false, unlock: true),
                                    mapping: [Self.desk: Self.laptopProfile], delaySeconds: 5, cooldownSeconds: 120)
        try store.save(s)
        #expect(AutoProfileStore(fileURL: url).load() == s)

        s.enabled = false
        try store.save(s)
        #expect(store.load().enabled == false)
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoProfileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("auto-profile.json")
        try Data("not json".utf8).write(to: url)
        #expect(AutoProfileStore(fileURL: url).load() == AutoProfileSettings())
    }
}
