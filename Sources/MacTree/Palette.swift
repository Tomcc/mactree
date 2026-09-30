import AppKit
import MacTreeCore
import SwiftUI

// Hue is the kind of data. Fills are system colours mixed into the window
// background, so they follow light and dark mode and the user's contrast.

enum Palette {
    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .code: Color(nsColor: .systemBlue)
        case .agentScratch: Color(nsColor: .systemOrange)
        case .toolchain: Color(nsColor: .systemTeal)
        case .synced: Color(nsColor: .systemIndigo)
        case .git: Color(nsColor: .systemRed)
        case .media: Color(nsColor: .systemPurple)
        case .documents, .other: Color(nsColor: .systemGray)
        case .cache: Color(nsColor: .systemYellow)
        }
    }

    static let background = Color(nsColor: .windowBackgroundColor)
    static let worth = Color(nsColor: .systemGreen)

    /// A solid fill, so nested tiles never blend into each other's hue.
    /// Deeper tiles carry a little more colour, so nesting reads without borders.
    static func fill(_ kind: Kind, depth: Int, in environment: EnvironmentValues) -> Color {
        let base = background.resolve(in: environment)
        let tint = color(kind).resolve(in: environment)
        let amount = (kind == .other ? 0.12 : 0.28) + 0.05 * Float(min(depth, 5))
        let mix = { (a: Float, b: Float) in a + (b - a) * amount }
        return Color(Color.Resolved(
            red: mix(base.red, tint.red), green: mix(base.green, tint.green),
            blue: mix(base.blue, tint.blue)))
    }
}
