// Renders the app icon: `swift scripts/make-icon.swift out.png` (1024 px).
// A tiny MacTree on a macOS icon plate, in the app's own colours.
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        Canvas { context, size in
            // Apple's grid: an 824 pt plate centred on 1024, radius about 185.
            let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
            let shape = Path(roundedRect: plate, cornerRadius: 185, style: .continuous)
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.28), radius: 18, y: 10))
            shadowed.fill(shape, with: .color(Color(white: 0.80)))
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.84), Color(white: 0.74)]),
                    startPoint: CGPoint(x: 0, y: plate.minY), endPoint: CGPoint(x: 0, y: plate.maxY)))
            context.clip(to: shape)

            let green = Color(red: 0.20, green: 0.78, blue: 0.35)
            let orange = Color(red: 1.00, green: 0.58, blue: 0.00)
            let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
            let blue = Color(red: 0.00, green: 0.48, blue: 1.00)
            let inset = plate.insetBy(dx: 84, dy: 84)
            let gap: CGFloat = 22
            let left = CGRect(x: inset.minX, y: inset.minY, width: 330, height: inset.height)
            let right = inset.minX + left.width + gap
            let rightWidth = inset.maxX - right

            // A reclaimable folder holding a file and a smaller folder.
            folder(&context, left, band: green)
            let body = CGRect(x: left.minX + 18, y: left.minY + 92, width: left.width - 36,
                height: left.height - 110)
            block(&context, CGRect(x: body.minX, y: body.minY, width: body.width, height: 230),
                color: green.mix(with: .white, by: 0.55))
            folder(&context,
                CGRect(x: body.minX, y: body.minY + 230 + 16, width: body.width,
                    height: body.height - 246),
                band: green)

            // Git, an app and a System block down the right.
            folder(&context, CGRect(x: right, y: inset.minY, width: rightWidth, height: 250),
                band: orange)
            block(&context, CGRect(x: right, y: inset.minY + 250 + gap, width: rightWidth,
                height: 150), color: purple.mix(with: .white, by: 0.35))
            let bottom = inset.minY + 250 + gap + 150 + gap
            block(&context, CGRect(x: right, y: bottom, width: rightWidth * 0.58,
                height: inset.maxY - bottom), color: blue.mix(with: .white, by: 0.45))
            block(&context, CGRect(x: right + rightWidth * 0.58 + gap, y: bottom,
                width: rightWidth * 0.42 - gap, height: inset.maxY - bottom),
                color: Color(white: 0.97))
        }
        .frame(width: 1024, height: 1024)
    }

    /// A folder: light body, coloured band on top.
    private func folder(_ context: inout GraphicsContext, _ rect: CGRect, band: Color) {
        block(&context, rect, color: Color(white: 0.97))
        var top = context
        top.clip(to: Path(roundedRect: rect, cornerRadius: 34, style: .continuous))
        top.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 74)),
            with: .color(band.mix(with: .white, by: 0.35)))
    }

    /// A tile with the app's soft shadow and top-left highlight.
    private func block(_ context: inout GraphicsContext, _ rect: CGRect, color: Color) {
        let shape = Path(roundedRect: rect, cornerRadius: 34, style: .continuous)
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.22), radius: 12, y: 5))
        shadowed.fill(shape, with: .color(color))
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
    else {
        fatalError("could not render the icon")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(output)")
    }
}
