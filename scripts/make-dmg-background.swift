// Renders the DMG window's background: `swift scripts/make-dmg-background.swift out.png 2`.
// 600 by 400 pt, an arrow from the app (centred at 150, 190) to Applications (450, 190).
import AppKit
import SwiftUI

struct Background: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.97), Color(white: 0.91)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let ink = Color(white: 0.62)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 250, y: 190))
            arrow.addLine(to: CGPoint(x: 348, y: 190))
            arrow.move(to: CGPoint(x: 332, y: 174))
            arrow.addLine(to: CGPoint(x: 350, y: 190))
            arrow.addLine(to: CGPoint(x: 332, y: 206))
            context.stroke(
                arrow, with: .color(ink),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.draw(
                Text("Drag MacTree into Applications")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(white: 0.45)),
                at: CGPoint(x: 300, y: 330))
        }
        .frame(width: 600, height: 400)
    }
}

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "background.png"
let scale = arguments.count > 2 ? Double(arguments[2]) ?? 1 : 1
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let image = renderer.cgImage,
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
    else {
        fatalError("could not render the background")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(output)")
    }
}
