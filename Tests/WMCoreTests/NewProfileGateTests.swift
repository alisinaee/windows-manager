import Testing
@testable import WMCore

@Suite struct NewProfileGateTests {
    @Test func viewModeCanStart() {
        #expect(NewProfileGate.refusal(isEditing: false, hasUnsavedChanges: false) == nil)
        #expect(NewProfileGate.refusal(isEditing: false, hasUnsavedChanges: true) == nil)
    }

    @Test func editModeSaysWhy() throws {
        let clean = try #require(NewProfileGate.refusal(isEditing: true, hasUnsavedChanges: false))
        let dirty = try #require(NewProfileGate.refusal(isEditing: true, hasUnsavedChanges: true))
        #expect(clean.contains("Cancel"))
        #expect(dirty.contains("unsaved"))
        #expect(clean != dirty)
    }
}
