import Testing
@testable import WMCore

@Suite("Bundle id validation for layout drops")
struct BundleIDValidationTests {
    @Test("reverse-DNS ids are accepted")
    func acceptsReverseDNS() {
        #expect(BundleIDValidation.looksLikeBundleID("com.apple.Safari"))
        #expect(BundleIDValidation.looksLikeBundleID("org.example.my-app2"))
        #expect(BundleIDValidation.looksLikeBundleID("a.b"))
    }

    @Test("free text and malformed ids are rejected")
    func rejectsNonBundleIDs() {
        #expect(!BundleIDValidation.looksLikeBundleID(""))
        #expect(!BundleIDValidation.looksLikeBundleID("Safari"))
        #expect(!BundleIDValidation.looksLikeBundleID("hello world.txt"))
        #expect(!BundleIDValidation.looksLikeBundleID("https://example.com"))
        #expect(!BundleIDValidation.looksLikeBundleID("com.apple."))
        #expect(!BundleIDValidation.looksLikeBundleID(".com.apple"))
        #expect(!BundleIDValidation.looksLikeBundleID("com..apple"))
        #expect(!BundleIDValidation.looksLikeBundleID("com.apple/Safari"))
    }

    @Test("a running app's id is accepted even without the shape")
    func acceptsRunningApp() {
        let running: Set<String> = ["com_weird_id"]
        #expect(BundleIDValidation.accepts("com_weird_id", runningBundleIDs: running))
        #expect(!BundleIDValidation.accepts("com_weird_id", runningBundleIDs: []))
        #expect(!BundleIDValidation.accepts("random text", runningBundleIDs: running))
        #expect(BundleIDValidation.accepts("com.apple.Notes", runningBundleIDs: []))
    }
}
