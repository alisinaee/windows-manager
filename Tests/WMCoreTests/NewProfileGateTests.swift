import Testing
@testable import WMCore

@Suite struct NewProfileGateTests {
    @Test func viewModeStarts() {
        #expect(NewProfileGate.action(isEditing: false, hasUnsavedChanges: false) == .start)
        #expect(NewProfileGate.action(isEditing: false, hasUnsavedChanges: true) == .start)
    }

    @Test func cleanEditStartsSilently() {
        #expect(NewProfileGate.action(isEditing: true, hasUnsavedChanges: false) == .start)
    }

    @Test func dirtyEditAsksFirst() {
        #expect(NewProfileGate.action(isEditing: true, hasUnsavedChanges: true) == .confirm)
    }
}
