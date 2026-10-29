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
