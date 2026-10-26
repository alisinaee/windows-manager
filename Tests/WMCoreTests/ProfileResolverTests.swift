import Foundation
import Testing
@testable import WMCore

@Suite struct ProfileResolverTests {
    static let a = UUID(uuidString: "0000000A-0000-4000-8000-000000000001")!
    static let b = UUID(uuidString: "0000000B-0000-4000-8000-000000000002")!
    static let c = UUID(uuidString: "0000000C-0000-4000-8000-000000000003")!

    static func summary(_ id: UUID, _ name: String) -> ProfileSummary {
        ProfileSummary(id: id, name: name, icon: "", updatedAt: Date(timeIntervalSince1970: 0), windowCount: 0)
    }

    @Test func uniqueNameFound() {
        let profiles = [Self.summary(Self.a, "Work"), Self.summary(Self.b, "Home")]
        #expect(ProfileResolver.resolve("Home", in: profiles) == .found(Self.b))
    }

    @Test func caseInsensitiveUniqueNameFound() {
        let profiles = [Self.summary(Self.a, "Work"), Self.summary(Self.b, "Home")]
        #expect(ProfileResolver.resolve("  home ", in: profiles) == .found(Self.b))
    }

    @Test func duplicateExactNamesAreAmbiguous() {
        let profiles = [Self.summary(Self.a, "Work"), Self.summary(Self.b, "Work"), Self.summary(Self.c, "Home")]
        #expect(ProfileResolver.resolve("Work", in: profiles) == .ambiguous)
    }

    @Test func exactMatchWinsOverCaseOnlyMatch() {
        let profiles = [Self.summary(Self.a, "work"), Self.summary(Self.b, "Work")]
        #expect(ProfileResolver.resolve("Work", in: profiles) == .found(Self.b))
        #expect(ProfileResolver.resolve("work", in: profiles) == .found(Self.a))
    }

    @Test func caseOnlyDuplicatesAreAmbiguousForOtherCase() {
        let profiles = [Self.summary(Self.a, "Work"), Self.summary(Self.b, "WORK")]
        #expect(ProfileResolver.resolve("wOrK", in: profiles) == .ambiguous)
    }

    @Test func unknownAndEmptyNamesAreNone() {
        let profiles = [Self.summary(Self.a, "Work")]
        #expect(ProfileResolver.resolve("Play", in: profiles) == .none)
        #expect(ProfileResolver.resolve("   ", in: profiles) == .none)
        #expect(ProfileResolver.resolve("Work", in: []) == .none)
    }
}
