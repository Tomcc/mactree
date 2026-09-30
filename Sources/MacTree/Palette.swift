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

    /// A tile's body: neutral, and lighter the deeper it is nested, the way
    /// stacked things catch more light. Level 0 is the darkest in both modes.
    static func body(depth: Int, in environment: EnvironmentValues) -> Color {
        let step = Float(min(depth, 4))
        let surface = surface.resolve(in: environment)
        if environment.colorScheme == .dark {
            return Color(surface.mixed(with: .white, 0.02 + 0.035 * step))
        }
        return Color(surface.mixed(with: .black, 0.12 - 0.025 * step))
    }

    /// The gaps between tiles: darker than any tile, so they always separate.
    static func well(in environment: EnvironmentValues) -> Color {
        let dark = environment.colorScheme == .dark
        return Color(surface.resolve(in: environment).mixed(with: .black, dark ? 0.5 : 0.2))
    }

    /// A title band: the kind's colour over the body's lightness, the one
    /// place the colour is shown.
    static func title(_ kind: Kind, depth: Int, in environment: EnvironmentValues) -> Color {
        let body = body(depth: depth, in: environment).resolve(in: environment)
        // The same tint reads stronger on a dark background.
        let scale: Float = environment.colorScheme == .dark ? 0.7 : 1
        let amount = (kind == .other ? 0.06 : 0.24) * scale
        return Color(body.mixed(with: color(kind).resolve(in: environment), amount))
    }
}

private extension Color.Resolved {
    static let white = Color.Resolved(red: 1, green: 1, blue: 1)
    static let black = Color.Resolved(red: 0, green: 0, blue: 0)

    /// Solid, so nested tiles never blend into each other's hue.
    func mixed(with other: Color.Resolved, _ amount: Float) -> Color.Resolved {
        let mix = { (a: Float, b: Float) in a + (b - a) * amount }
        return Color.Resolved(
            red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }
}
