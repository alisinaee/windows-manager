import Foundation
import Testing
@testable import WMCore

/// Tests for the pure part of SkyLightHealth: a fake symbol table in, flags and fallback lines out.
/// Nothing here touches the real SkyLight.
@Suite struct SkyLightHealthTests {
    // MARK: Fixture

    private static let allSymbols: [String: Bool] = Dictionary(
        uniqueKeysWithValues: SkyLightHealth.probedSymbols.map { ($0, true) })
    private static let allClasses: [String: Bool] = Dictionary(
        uniqueKeysWithValues: SkyLightHealth.probedClasses.map { ($0, true) })

    private static func table(removing names: [String]) -> [String: Bool] {
        var copy = allSymbols
        for name in names { copy[name] = false }
        return copy
    }

    private static func evaluate(symbols: [String: Bool] = allSymbols,
                                 classes: [String: Bool] = allClasses,
                                 loadError: String? = nil,
                                 selfTest: SkyLightHealth.SelfTest? = nil) -> SkyLightHealth {
        SkyLightHealth.evaluate(symbols: symbols, classes: classes, osVersion: "Version 27.0",
                                loadError: loadError, selfTest: selfTest)
    }

    private static let passingSelfTest = SkyLightHealth.SelfTest(
        ok: true, activeSpaceID: 42, displayCount: 1, elapsedMilliseconds: 0.4, error: nil)

    // MARK: Cases

    @Test func allPresentIsOk() {
        let health = Self.evaluate()
        #expect(health.overall == .ok)
        #expect(health.canReadSpaces)
        #expect(health.canMoveWindowsToSpace)
        #expect(health.canReadWindowSpaces)
        #expect(health.fallbacks.isEmpty)
        #expect(health.missing.isEmpty)
        #expect(health.macOS == "Version 27.0")
        #expect(health.selfTest == nil)
    }

    @Test func missingMoveSymbolIsDegradedWithFallbackText() {
        let health = Self.evaluate(
            symbols: Self.table(removing: [SkyLightHealth.moveSymbol]),
            classes: [SkyLightHealth.moveClass: false])
        #expect(health.overall == .degraded)
        #expect(health.canReadSpaces)
        #expect(!health.canMoveWindowsToSpace)
        #expect(health.canReadWindowSpaces)
        #expect(health.fallbacks == [
            "moving windows between Desktops is disabled; windows are placed on the current Desktop only",
        ])
        #expect(health.missing == [SkyLightHealth.moveSymbol, SkyLightHealth.moveClass])
    }

    @Test func bridgedClassAloneKeepsMoveAvailable() {
        let health = Self.evaluate(symbols: Self.table(removing: [SkyLightHealth.moveSymbol]))
        #expect(health.canMoveWindowsToSpace)
        #expect(health.overall == .ok)
        #expect(health.fallbacks.isEmpty)
        #expect(health.missing == [SkyLightHealth.moveSymbol])
    }

    @Test func missingReadSymbolsIsUnavailable() {
        let health = Self.evaluate(symbols: Self.table(removing: ["SLSCopyManagedDisplaySpaces"]))
        #expect(health.overall == .unavailable)
        #expect(!health.canReadSpaces)
        #expect(health.fallbacks.contains { $0.contains("Desktop list cannot be read") })
        #expect(health.missing.contains("SLSCopyManagedDisplaySpaces"))
    }

    @Test func missingActiveSpaceSymbolIsUnavailable() {
        let health = Self.evaluate(symbols: Self.table(removing: ["SLSGetActiveSpace"]))
        #expect(health.overall == .unavailable)
        #expect(!health.canReadSpaces)
    }

    @Test func missingConnectionSymbolIsUnavailable() {
        let health = Self.evaluate(symbols: Self.table(removing: [SkyLightHealth.mainConnectionSymbol]))
        #expect(health.overall == .unavailable)
        #expect(!health.canReadSpaces)
        #expect(!health.canReadWindowSpaces)
    }

    @Test func missingWindowSpacesSymbolIsDegraded() {
        let health = Self.evaluate(symbols: Self.table(removing: [SkyLightHealth.windowSpacesSymbol]))
        #expect(health.overall == .degraded)
        #expect(health.canReadSpaces)
        #expect(!health.canReadWindowSpaces)
        #expect(health.fallbacks.count == 1)
    }

    @Test func noSkyLightListsEverythingMissing() {
        let health = SkyLightHealth.evaluate(symbols: [:], classes: [:], osVersion: "x",
                                             loadError: "image not found")
        #expect(health.overall == .unavailable)
        #expect(health.missing == SkyLightHealth.probedSymbols + SkyLightHealth.probedClasses)
        #expect(health.fallbacks.first == "SkyLight could not be loaded (image not found); every Desktop feature is off.")
    }

    @Test func failedSelfTestTurnsReadsOff() {
        let failed = SkyLightHealth.SelfTest(ok: false, activeSpaceID: 0, displayCount: 0,
                                             elapsedMilliseconds: 0.1, error: "no displays reported")
        let health = Self.evaluate(selfTest: failed)
        #expect(health.overall == .unavailable)
        #expect(!health.canReadSpaces)
        #expect(health.fallbacks.contains { $0.contains("no displays reported") })
        #expect(health.selfTest == failed)
    }

    @Test func passingSelfTestKeepsOk() {
        let health = Self.evaluate(selfTest: Self.passingSelfTest)
        #expect(health.overall == .ok)
        #expect(health.selfTest == Self.passingSelfTest)
    }

    @Test func roundTripsThroughJSON() throws {
        let health = Self.evaluate(symbols: Self.table(removing: [SkyLightHealth.moveSymbol]),
                                   classes: [SkyLightHealth.moveClass: false],
                                   selfTest: Self.passingSelfTest)
        let data = try JSONEncoder().encode(health)
        let decoded = try JSONDecoder().decode(SkyLightHealth.self, from: data)
        #expect(decoded == health)
        #expect(decoded.overall == .degraded)
    }
}
