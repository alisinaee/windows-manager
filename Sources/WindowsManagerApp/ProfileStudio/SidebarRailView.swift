import SwiftUI

// There is no collapsed icon rail: the system sidebar collapse hides the sidebar entirely (UX review P2-13).
// This file only holds the per-profile tint shared by the sidebar rows.

/// A stable colour per profile for the sidebar rows.
enum ProfileRowTint {
    /// No red here: a red icon reads as an error. Brown stands in for it.
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(for id: UUID) -> Color {
        let sum = id.uuid.0 &+ id.uuid.5 &+ id.uuid.10 &+ id.uuid.15
        return palette[Int(sum) % palette.count]
    }
}
