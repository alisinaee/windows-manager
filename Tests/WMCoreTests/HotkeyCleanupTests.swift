import Foundation
import Testing
@testable import WMCore

@Suite struct HotkeyCleanupTests {
    static let a = UUID(uuidString: "0000000A-0000-4000-8000-000000000001")!
    static let b = UUID(uuidString: "0000000B-0000-4000-8000-000000000002")!
    static let c = UUID(uuidString: "0000000C-0000-4000-8000-000000000003")!

    @Test func staleIDsAreRegisteredButNoLongerSaved() {
        let stale = HotkeyCleanup.staleProfileIDs(registered: [Self.a, Self.b], current: [Self.b, Self.c])
        #expect(stale == [Self.a])
    }

    @Test func nothingIsStaleWhenEverythingRegisteredIsStillSaved() {
        #expect(HotkeyCleanup.staleProfileIDs(registered: [Self.a], current: [Self.a, Self.b]).isEmpty)
        #expect(HotkeyCleanup.staleProfileIDs(registered: [], current: [Self.a]).isEmpty)
    }

    @Test func defaultsKeysOfDeletedProfilesAreStale() {
        let keys = [
            "KeyboardShortcuts_profile.\(Self.a.uuidString)",
            "KeyboardShortcuts_profile.\(Self.b.uuidString)",
        ]
        let stale = HotkeyCleanup.staleDefaultsKeys(in: keys, current: [Self.b])
        #expect(stale == ["KeyboardShortcuts_profile.\(Self.a.uuidString)"])
    }

    @Test func defaultsKeysOutsideProfileNamespaceAreKept() {
        let keys = [
            "KeyboardShortcuts_workspace.next",
            "KeyboardShortcuts_snap.zone.1",
            "KeyboardShortcuts_shortcutByNameDidChange",
            "AppleLanguages",
        ]
        #expect(HotkeyCleanup.staleDefaultsKeys(in: keys, current: []).isEmpty)
    }

    @Test func defaultsKeyMatchingIsCaseInsensitiveForUUIDs() {
        // UUID strings written by KeyboardShortcuts are uppercase; a lowercase copy is the same profile.
        let keys = ["KeyboardShortcuts_profile.\(Self.a.uuidString.lowercased())"]
        #expect(HotkeyCleanup.staleDefaultsKeys(in: keys, current: [Self.a]).isEmpty)
    }

    @Test func malformedProfileKeysAreStale() {
        let keys = ["KeyboardShortcuts_profile.not-a-uuid"]
        #expect(HotkeyCleanup.staleDefaultsKeys(in: keys, current: [Self.a]) == keys)
    }

    @Test func staleDefaultsKeysAreSortedAndUnique() {
        let keys = [
            "KeyboardShortcuts_profile.\(Self.c.uuidString)",
            "KeyboardShortcuts_profile.\(Self.a.uuidString)",
            "KeyboardShortcuts_profile.\(Self.b.uuidString)",
        ]
        let stale = HotkeyCleanup.staleDefaultsKeys(in: keys, current: [Self.b])
        #expect(stale == stale.sorted())
        #expect(stale.count == 2)
    }

    @Test func shortcutNameStripsDefaultsPrefix() {
        #expect(HotkeyCleanup.shortcutName(forDefaultsKey: "KeyboardShortcuts_profile.\(Self.a.uuidString)")
            == "profile.\(Self.a.uuidString)")
        #expect(HotkeyCleanup.shortcutName(forDefaultsKey: "AppleLanguages") == nil)
    }
}
