import Foundation

// Single-file profile transfer (phase P6.5): a profile is exported as one JSON file and imported from one.
// These functions are pure: they only turn bytes into a `Profile` and back. Reading and writing files,
// and saving into the store, belong to the callers (see `spaceslab profile export|import`).
// The file format is the same one `ProfileStore` writes, so every supported schema version can be imported.

public enum ProfileTransfer {
    /// The exported file: pretty printed JSON, sorted keys, ISO-8601 dates.
    public static func export(_ profile: Profile) throws -> Data {
        try ProfileStore.encode(profile)
    }

    /// Reads one exported profile. The schema version is checked by `ProfileStore.decode` (a version newer
    /// than this build, or an invalid one, throws `ProfileStoreError.unsupportedSchema`), and the content by
    /// `Profile.validate()` (throws `ProfileStoreError.invalidProfile`).
    ///
    /// The result is a new copy: it gets a fresh id, a name that does not clash with `existingNames`
    /// (see `uniqueName`), and no hotkey, because a hotkey belongs to one profile. Dates are kept.
    public static func importProfile(_ data: Data, existingNames: [String], source: String = "The file",
                                     newID: UUID = UUID()) throws -> Profile {
        var profile = try ProfileStore.decode(data, source: source)
        let problems = profile.validate()
        guard problems.isEmpty else { throw ProfileStoreError.invalidProfile(problems) }

        profile.id = newID
        profile.name = uniqueName(profile.name, among: existingNames)
        profile.options.hotkey = nil
        return profile
    }

    /// `name` when no existing name matches it (ignoring case and surrounding spaces), otherwise the first free
    /// "<name> 2", "<name> 3", ... For example "Home" becomes "Home 2" when "Home" already exists.
    public static func uniqueName(_ name: String, among existingNames: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func taken(_ candidate: String) -> Bool {
            existingNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard taken(base) else { return base }
        var number = 2
        while taken("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
