import AppKit

/// Renders the Trackaro app icon into an asset catalog icon set, drawing each size from vectors so small sizes
/// stay crisp. Run from the repository root:
///
///     swift scripts/make-icon.swift App/Trackaro/Assets.xcassets/AppIcon.appiconset
///
/// The mark: an indigo tile with a nearly closed white progress ring around a checkmark, and a warm spark where the
/// ring opens. The ring is the work, the check is it getting done, the spark is the agent doing it.

let canvas: CGFloat = 1024

func drawIcon(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.scaleBy(x: size / canvas, y: size / canvas)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor(srgbRed: 0.18, green: 0.19, blue: 0.55, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.49, green: 0.53, blue: 0.97, alpha: 1).cgColor,
        NSColor(srgbRed: 0.30, green: 0.34, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.15, green: 0.16, blue: 0.47, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 900), end: CGPoint(x: 860, y: 120), options: [])
    }
    let glow = [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    if let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glow, locations: [0, 1]) {
        context.drawRadialGradient(highlight, startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                                   endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
    }
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    context.setLineWidth(4)
    context.strokePath()

    let center = CGPoint(x: 512, y: 500)
    let radius: CGFloat = 228
    let gapStart = CGFloat.pi * 0.36
    let gapEnd = CGFloat.pi * 0.14

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineCap(.round)
    context.setLineWidth(66)
    context.addArc(center: center, radius: radius, startAngle: gapStart, endAngle: gapEnd + 2 * .pi, clockwise: false)
    context.strokePath()

    context.setLineWidth(70)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 405, y: 505))
    context.addLine(to: CGPoint(x: 485, y: 422))
    context.addLine(to: CGPoint(x: 630, y: 590))
    context.strokePath()
    context.restoreGState()

    let sparkCenter = CGPoint(x: center.x + radius * cos(gapStart - 0.11), y: center.y + radius * sin(gapStart - 0.11))
    let spark = CGPoint(x: sparkCenter.x + 58, y: sparkCenter.y + 46)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 30, color: NSColor(srgbRed: 1, green: 0.82, blue: 0.4, alpha: 0.9).cgColor)
    context.setFillColor(NSColor(srgbRed: 1, green: 0.84, blue: 0.42, alpha: 1).cgColor)
    context.addPath(sparkle(at: spark, radius: 92, waist: 0.2))
    context.fillPath()
    context.restoreGState()
    context.setFillColor(NSColor(srgbRed: 1, green: 0.93, blue: 0.72, alpha: 1).cgColor)
    context.addPath(sparkle(at: CGPoint(x: spark.x - 112, y: spark.y + 74), radius: 34, waist: 0.24))
    context.fillPath()

    context.restoreGState()
}

/// A four-pointed star with concave sides.
func sparkle(at center: CGPoint, radius: CGFloat, waist: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let inner = radius * waist
    for index in 0..<4 {
        let angle = CGFloat(index) * .pi / 2
        let tip = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        let nextAngle = angle + .pi / 2
        let nextTip = CGPoint(x: center.x + radius * cos(nextAngle), y: center.y + radius * sin(nextAngle))
        let control = CGPoint(x: center.x + inner * cos(angle + .pi / 4), y: center.y + inner * sin(angle + .pi / 4))
        if index == 0 { path.move(to: tip) }
        path.addQuadCurve(to: nextTip, control: control)
    }
    path.closeSubpath()
    return path
}

func png(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.interpolationQuality = .high
    drawIcon(in: graphics.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let data = png(size: pixels) else { fatalError("could not render \(name)") }
        try data.write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
