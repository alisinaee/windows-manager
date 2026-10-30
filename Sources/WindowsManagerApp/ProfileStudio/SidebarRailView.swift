import SwiftUI

/// A stable colour per profile, shared by the full sidebar row and the collapsed rail.
enum ProfileRowTint {
    /// No red here: a red icon reads as an error. Brown stands in for it.
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(for id: UUID) -> Color {
        let sum = id.uuid.0 &+ id.uuid.5 &+ id.uuid.10 &+ id.uuid.15
        return palette[Int(sum) % palette.count]
    }
}
