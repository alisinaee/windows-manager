import Testing
import Foundation
@testable import WMCore

@Suite struct CLISystemCommandsTests {
    @Test func serviceErrorsMapToExitCodes() {
        #expect(CLIServiceErrorMapping.failure(ServiceError.notFound("x")).exit == .notFound)
        #expect(CLIServiceErrorMapping.failure(ServiceError.invalid("x")).exit == .usage)
        #expect(CLIServiceErrorMapping.failure(ServiceError.conflict("x")).exit == .runtime)
        #expect(CLIServiceErrorMapping.failure(ServiceError.failed("x")).exit == .runtime)
        #expect(CLIServiceErrorMapping.failure(ServiceError.notFound("x")).code == "not_found")
    }

    @Test func unknownErrorIsRuntime() {
        struct Boom: Error {}
        #expect(CLIServiceErrorMapping.failure(Boom()).exit == .runtime)
    }

    @Test func doctorExitFollowsAccessibility() {
        let trusted = DoctorItem(id: "accessibility", title: "Accessibility", ok: true, detail: "trusted", fix: nil)
        let missing = DoctorItem(id: "accessibility", title: "Accessibility", ok: false, detail: "NOT trusted", fix: "add it")
        #expect(DoctorReport.exit([trusted]) == .ok)
        #expect(DoctorReport.exit([missing]) == .permission)
        #expect(DoctorReport.exit([]) == .ok)
    }

    @Test func doctorTextShowsFixOnlyWhenFailing() {
        let ok = DoctorItem(id: "a", title: "A", ok: true, detail: "fine", fix: "unused")
        let bad = DoctorItem(id: "b", title: "B", ok: false, detail: "missing", fix: "grant it")
        #expect(DoctorReport.text([ok]) == "ok   A: fine")
        #expect(DoctorReport.text([bad]) == "FAIL B: missing\n      fix: grant it")
    }

    @Test func settingValuesUseJSONTypes() {
        #expect(CLISettingFormat.json(.bool(true)) == .bool(true))
        #expect(CLISettingFormat.json(.int(3)) == .int(3))
        #expect(CLISettingFormat.json(.double(0.5)) == .double(0.5))
        #expect(CLISettingFormat.json(.string("option")) == .string("option"))
    }

    @Test func settingLineMarksNonDefault() {
        let changed = SettingEntry(key: "snap.gap", value: .double(8), defaultValue: .double(0),
                                   isDefault: false, kind: "double", summary: "Gap")
        let same = SettingEntry(key: "snap.enabled", value: .bool(true), defaultValue: .bool(true),
                                isDefault: true, kind: "bool", summary: "Snap")
        #expect(CLISettingFormat.line(changed) == "snap.gap = 8.0  (default 0.0)")
        #expect(CLISettingFormat.line(same) == "snap.enabled = true")
    }
}
