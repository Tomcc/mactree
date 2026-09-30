import AppKit
import MacTreeCore
import SwiftUI

// Fills are system colours mixed lightly into the text background (white, or
// near-black in dark mode), so text reads on them; the gaps between tiles show
// the window background, which always sits between the two.

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
    private static let surface = Color(nsColor: .textBackgroundColor)

    /// A tile's body: neutral, a shade further from the surface per level so
    /// nesting still reads.
    static func body(depth: Int, in environment: EnvironmentValues) -> Color {
        mixed(Color(nsColor: .systemGray), 0.03 * Float(min(depth, 5)), in: environment)
    }

    /// A title band: the kind's colour, the one place it is shown.
    static func title(_ kind: Kind, depth: Int, in environment: EnvironmentValues) -> Color {
        let amount = (kind == .other ? 0.08 : 0.2) + 0.03 * Float(min(depth, 4))
        // The same tint reads stronger on a dark background.
        let scale: Float = environment.colorScheme == .dark ? 0.7 : 1
        return mixed(color(kind), amount * scale, in: environment)
    }

    /// Solid, so nested tiles never blend into each other's hue.
    private static func mixed(_ tint: Color, _ amount: Float, in environment: EnvironmentValues)
        -> Color
    {
        let base = surface.resolve(in: environment)
        let tint = tint.resolve(in: environment)
        let mix = { (a: Float, b: Float) in a + (b - a) * amount }
        return Color(Color.Resolved(
            red: mix(base.red, tint.red), green: mix(base.green, tint.green),
            blue: mix(base.blue, tint.blue)))
    }
}
