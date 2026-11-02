import Foundation
import Testing
@testable import WMCore

@Suite struct StudioSidebarStateTests {
    @Test func startsExpandedAndToggles() {
        var s = StudioSidebarState()
        #expect(s.isShown)
        s.toggle()
        #expect(!s.isShown && !s.isVisible)
        s.toggle()
        #expect(s.isShown && s.isVisible)
    }

    @Test func restoresRememberedChoice() {
        #expect(!StudioSidebarState(isVisible: false).isShown)
    }

    @Test func narrowWindowCollapsesUntilUserOpensIt() {
        var s = StudioSidebarState()
        s.contentWidthChanged(600)
        #expect(!s.isShown)
        #expect(s.isVisible)          // the stored choice is untouched by the window width
        s.toggle()                    // user opens it on purpose
        #expect(s.isShown)
        s.contentWidthChanged(500)    // still narrow: stays open
        #expect(s.isShown)
        s.contentWidthChanged(900)    // wide again: normal rules, still expanded
        #expect(s.isShown)
        s.toggle()
        #expect(!s.isShown)
    }

    @Test func wideAgainForgetsForcedOpen() {
        var s = StudioSidebarState()
        s.contentWidthChanged(600)
        s.toggle()
        s.contentWidthChanged(1000)
        s.contentWidthChanged(600)
        #expect(!s.isShown || s.isVisible)
        #expect(!s.isShown)           // forced-open was reset by the wide window
    }

    @Test func collapsedStaysCollapsedWhenWide() {
        var s = StudioSidebarState()
        s.toggle()
        s.contentWidthChanged(1200)
        #expect(!s.isShown)
    }

    @Test func setShownIsIdempotent() {
        var s = StudioSidebarState()
        s.set(shown: true)
        #expect(s.isShown)
        s.set(shown: false); s.set(shown: false)
        #expect(!s.isShown)
        s.set(shown: true)
        #expect(s.isShown)
    }
}

@Suite struct StudioSidebarRowsTests {
    @Test func draftRowComesFirstAndIsHighlighted() {
        let a = UUID(), b = UUID(), d = UUID()
        let rows = StudioSidebarRows.entries(saved: [a, b], draftID: d, badge: .draft)
        #expect(rows.map(\.id) == [d, a, b])
        #expect(rows.first?.badge == .draft)
        #expect(StudioSidebarRows.highlighted(selected: a, draftID: d, badge: .draft) == d)
    }

    @Test func noDraftLeavesSavedRowsAndSelection() {
        let a = UUID(), d = UUID()
        #expect(StudioSidebarRows.entries(saved: [a], draftID: d, badge: nil).map(\.id) == [a])
        #expect(StudioSidebarRows.highlighted(selected: a, draftID: d, badge: nil) == a)
    }

    @Test func discardReselectsPreviousOrFirst() {
        let a = UUID(), b = UUID()
        #expect(StudioSidebarRows.selectionAfterDraft(previous: b, saved: [a, b]) == b)
        #expect(StudioSidebarRows.selectionAfterDraft(previous: UUID(), saved: [a, b]) == a)
        #expect(StudioSidebarRows.selectionAfterDraft(previous: nil, saved: []) == nil)
    }

    @Test func recoveredBadge() {
        let rows = StudioSidebarRows.entries(saved: [], draftID: UUID(), badge: .recovered)
        #expect(rows.first?.badge?.rawValue == "Recovered")
    }
}
