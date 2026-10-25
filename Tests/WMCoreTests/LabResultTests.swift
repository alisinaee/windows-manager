import Foundation
import Testing
@testable import WMCore

@Suite struct LabResultTests {
    /// A fresh empty folder that is removed again by the caller.
    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-lab-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func sampleResult(test: String, passed: Bool?) -> LabResult {
        // Whole seconds: ISO-8601 dates in the JSON have no fractions.
        var result = LabResult(test: test, started: Date(timeIntervalSince1970: 1_800_000_000))
        result.step("first step")
        result.step("second step")
        result.observe("new-space-position", "end of list")
        result.observe("pipe|key", "a|b")
        result.finished = Date(timeIntervalSince1970: 1_800_000_003)
        result.passed = passed
        return result
    }

    @Test func jsonRoundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = sampleResult(test: "roundtrip", passed: true)
        let url = try original.save(in: folder)
        #expect(url.lastPathComponent.hasPrefix("roundtrip-"))
        #expect(url.pathExtension == "json")

        let loaded = try LabResult.load(from: url)
        #expect(loaded.test == original.test)
        #expect(loaded.started == original.started)
        #expect(loaded.finished == original.finished)
        #expect(loaded.macOS == original.macOS)
        #expect(loaded.passed == true)
        #expect(loaded.steps == original.steps)
        #expect(loaded.observations == original.observations)
    }

    @Test func saveNeverOverwritesAnEarlierFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = sampleResult(test: "twice", passed: nil)
        let first = try result.save(in: folder)
        let second = try result.save(in: folder)
        #expect(first != second)
        #expect(try LabResult.load(from: second).passed == nil)
    }

    @Test func stepsAreTimestampedFromStart() {
        var result = LabResult(test: "steps")
        result.step("a")
        result.step("b")
        #expect(result.steps.count == 2)
        #expect(result.steps[0].offset >= 0)
        #expect(result.steps[1].offset >= result.steps[0].offset)
    }

    @Test func reportSummarisesEveryResult() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try sampleResult(test: "alpha", passed: true).save(in: folder)
        _ = try sampleResult(test: "beta", passed: false).save(in: folder)
        try "not json".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let markdown = try LabReport.markdown(from: folder)
        #expect(markdown.contains("| Test |"))
        #expect(markdown.contains("| alpha |"))
        #expect(markdown.contains("| beta |"))
        #expect(markdown.contains("PASS"))
        #expect(markdown.contains("FAIL"))
        #expect(markdown.contains("`new-space-position`: end of list"))
        #expect(markdown.contains("broken.json"))
    }

    @Test func reportHandlesAMissingFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-lab-missing-\(UUID().uuidString)")
        let markdown = try LabReport.markdown(from: folder)
        #expect(markdown.contains("No lab results"))
    }

    @Test func waitUntilReturnsElapsedOrNil() {
        #expect(waitUntil(timeout: 1) { true } != nil)
        #expect(waitUntil(timeout: 0.1) { false } == nil)
    }
}
