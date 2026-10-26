import Testing
@testable import WMCore

@Suite struct WorkspaceNameEditTests {
    @Test func trimsSurroundingWhitespace() {
        #expect(WorkspaceNameEdit.committedName(draft: "  Work \n", current: "A") == "Work")
    }

    @Test func keepsSpacesInsideAName() {
        #expect(WorkspaceNameEdit.committedName(draft: "My Work", current: "A") == "My Work")
    }

    @Test func emptyOrBlankDraftKeepsCurrentName() {
        #expect(WorkspaceNameEdit.committedName(draft: "", current: "A") == "A")
        #expect(WorkspaceNameEdit.committedName(draft: "   ", current: "A") == "A")
    }
}
