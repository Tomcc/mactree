import AppKit
import MacTreeCore
import SwiftUI

// Fills are system colours mixed lightly into the window background, so they
// follow light and dark mode and black or white text stays readable on them.

enum Palette {
    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .reclaimable: Color(nsColor: .systemGreen)
        case .git: Color(nsColor: .systemOrange)
        case .system: Color(nsColor: .systemBlue)
        case .other: Color(nsColor: .systemGray)
        }
    }

    static let background = Color(nsColor: .windowBackgroundColor)

    /// A solid fill, so nested tiles never blend into each other's hue.
    /// Deeper tiles carry a little more colour, so nesting reads without borders.
    static func fill(_ kind: Kind, depth: Int, in environment: EnvironmentValues) -> Color {
        let base = background.resolve(in: environment)
        let tint = color(kind).resolve(in: environment)
        // The same tint reads stronger on a dark background.
        let scale: Float = environment.colorScheme == .dark ? 0.7 : 1
        let amount = ((kind == .other ? 0.04 : 0.11) + 0.025 * Float(min(depth, 4))) * scale
        let mix = { (a: Float, b: Float) in a + (b - a) * amount }
        return Color(Color.Resolved(
            red: mix(base.red, tint.red), green: mix(base.green, tint.green),
            blue: mix(base.blue, tint.blue)))
    }
}
