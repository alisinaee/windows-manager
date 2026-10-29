import Foundation
import Testing
@testable import WMCore

@Suite struct DebugRunnerRegistryTests {
    @Test func idsAreUniqueAndCoverLegacyAndPowerUser() {
        let ids = DebugRunnerRegistry.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(DebugRunnerRegistry.entries.count == DebugScenarioID.allCases.count + DebugFixtures.scenarios.count)
        for s in DebugScenarioID.allCases { #expect(DebugRunnerRegistry.entry(id: s.rawValue)?.legacy == s) }
        for spec in DebugFixtures.scenarios { #expect(DebugRunnerRegistry.entry(id: spec.id)?.legacy == nil) }
    }

    @Test func entriesAreWiredToRulesAndFixtures() {
        for e in DebugRunnerRegistry.entries {
            #expect(!e.fixtureProfile.isEmpty)
            #expect(!e.verifyRules.isEmpty && e.verifyRules.allSatisfy(DebugRunnerRegistry.knownRules.contains))
        }
        let vpn = DebugRunnerRegistry.entry(id: "vpn-tools")
        #expect(vpn?.verifyRules.contains("size-limited") == true)
        #expect(vpn?.verifyRules.contains("idempotence") == true)
        #expect(vpn?.fixtureProfile == DebugFixtures.profile(for: "vpn-tools")?.name)
        #expect(DebugRunnerRegistry.entry(id: "deep-work")?.requiredDisplays == 2)
    }

    @Test func resolveAllOneAndUnknown() {
        #expect(DebugRunnerRegistry.resolve("ALL")?.count == DebugRunnerRegistry.entries.count)
        #expect(DebugRunnerRegistry.resolve("dupes")?.map(\.id) == ["dupes"])
        #expect(DebugRunnerRegistry.resolve("nope") == nil)
    }

    @Test func listTextAndJSONShowLastResult() {
        let text = DebugRunnerRegistry.listText(last: ["dupes": .inconclusive])
        let lines = text.split(separator: "\n")
        #expect(lines.count == DebugRunnerRegistry.entries.count)
        #expect(lines.contains { $0.hasPrefix("dupes\tINCONCLUSIVE\t") })
        #expect(lines.contains { $0.hasPrefix("deep-work\t-\t") })
        guard case .object(let root) = DebugRunnerRegistry.listJSON(last: ["dupes": .pass]),
              case .array(let rows)? = root["scenarios"] else { Issue.record("bad json"); return }
        #expect(rows.count == DebugRunnerRegistry.entries.count)
        let dupes = rows.first { if case .object(let o) = $0, o["id"] == .string("dupes") { return true }; return false }
        if case .object(let o)? = dupes { #expect(o["last"] == .string("PASS")) } else { Issue.record("no dupes row") }
    }

    @Test func exitCodes() {
        #expect(DebugRunStatus.exitCode([.pass, .pass]) == 0)
        #expect(DebugRunStatus.exitCode([.pass, .fail, .inconclusive]) == 1)
        #expect(DebugRunStatus.exitCode([.pass, .inconclusive]) == 2)
        #expect(DebugRunStatus.exitCode([.skipped]) == 2)
        #expect(DebugRunStatus.exitCode([]) == 1)
    }

    @Test func lastStatusesRoundTripThroughReportDocument() throws {
        let r1 = DebugRunResult(scenarioID: "dupes", title: "Duplicates", status: .inconclusive, checks: [], log: [])
        let r2 = DebugRunResult(scenario: .home, passed: true, checks: [], log: [])
        let data = try JSONEncoder().encode(DebugRunReport.document(results: [r1, r2], error: nil))
        let last = DebugRunReport.lastStatuses(from: data)
        #expect(last["dupes"] == .inconclusive)
        #expect(last["home"] == .pass)
        #expect(DebugRunReport.lastStatuses(from: Data("x".utf8)).isEmpty)
    }
}
