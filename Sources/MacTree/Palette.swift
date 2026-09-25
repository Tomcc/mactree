import MacTreeCore
import SwiftUI

// Colour that means something, from disktree's palette.rs: hue is the kind of
// data, all at one muted level; reclaimable space is a hatch, not a colour;
// amber is kept apart for the selection and what can be had back.

/// Tokyo Night, the theme disktree's screenshot is in.
enum Theme {
    static let background = RGB(0x1a1b26)
    static let panel = RGB(0x1f2335)
    static let inset = RGB(0x16161e)
    static let line = RGB(0x292e42)
    static let foreground = RGB(0xa9b1d6)
    static let bright = RGB(0xc0caf5)
    static let muted = RGB(0x565f89)
    static let warning = RGB(0xe0af68)
}

struct RGB: Hashable {
    var r, g, b: Double

    init(_ hex: Int) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }

    init(r: Double, g: Double, b: Double) {
        (self.r, self.g, self.b) = (r, g, b)
    }

    init(h: Double, s: Double, l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) =
            switch Int(h * 6) % 6 {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
        self.init(r: r + m, g: g + m, b: b + m)
    }

    /// In RGB: interpolating hue would drag a colour around the wheel.
    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

enum Palette {
    /// The hue a kind is drawn in, and how much colour it carries.
    private static func hue(_ kind: Kind) -> (Double, Double) {
        switch kind {
        case .code: (0.605, 1.0)
        case .agentScratch: (0.065, 1.0)
        case .toolchain: (0.415, 1.0)
        case .synced: (0.535, 1.0)
        case .git: (0.955, 1.0)
        case .media: (0.745, 1.0)
        case .cache: (0.125, 0.95)
        case .documents: (0.6, 0.18)
        case .other: (0.6, 0.08)
        }
    }

    /// Deeper tiles lift slightly, so nesting reads without borders.
    static func fill(_ kind: Kind, depth: Int) -> RGB {
        let (h, chroma) = hue(kind)
        let step = Double(min(depth, 4))
        return RGB(h: h, s: 0.26 * chroma, l: 0.215 + step * 0.028)
            .mix(Theme.inset, 0.12)
    }

    /// The strip over a top-level directory, and the legend swatch.
    static func accent(_ kind: Kind) -> RGB {
        let (h, chroma) = hue(kind)
        return RGB(h: h, s: 0.42 * chroma, l: 0.52)
    }

    static let hatch = Theme.bright.color.opacity(0.16)
    static let hover = Theme.bright.color.opacity(0.55)
}
