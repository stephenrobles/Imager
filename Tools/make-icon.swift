// Renders the Imager app icon: a picture frame with a sun-and-mountains landscape, like the
// framed-picture emoji, on a teal-to-blue tile.
//
// Usage: swift Tools/make-icon.swift <output-dir>
// Writes icon_<size>.png for 16…1024 (rounded macOS tile with shadow) into <output-dir>.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS-style continuous-corner tile (superellipse) inside the standard 824pt icon grid.
func tilePath() -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, in context: CGContext, gradient colors: [CGColor], locations: [CGFloat], from start: CGPoint, to end: CGPoint, rule: CGPathFillRule = .winding) {
    context.saveGState()
    context.addPath(path)
    context.clip(using: rule)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// An arrow head pointing toward the center from one corner: a short shaft with a chevron tip.
func arrow(at corner: CGPoint, towards center: CGPoint, length: CGFloat, width: CGFloat) -> CGPath {
    let dx = center.x - corner.x, dy = center.y - corner.y
    let distance = hypot(dx, dy)
    let ux = dx / distance, uy = dy / distance      // unit vector toward the center
    let px = -uy, py = ux                           // perpendicular
    let tip = CGPoint(x: corner.x + ux * length, y: corner.y + uy * length)
    let tail = corner
    let head: CGFloat = width * 1.9
    let path = CGMutablePath()
    // Shaft.
    path.move(to: CGPoint(x: tail.x + px * width / 2, y: tail.y + py * width / 2))
    path.addLine(to: CGPoint(x: tail.x - px * width / 2, y: tail.y - py * width / 2))
    path.addLine(to: CGPoint(x: tip.x - ux * head - px * width / 2, y: tip.y - uy * head - py * width / 2))
    path.addLine(to: CGPoint(x: tip.x - ux * head - px * head, y: tip.y - uy * head - py * head))
    path.addLine(to: tip)
    path.addLine(to: CGPoint(x: tip.x - ux * head + px * head, y: tip.y - uy * head + py * head))
    path.addLine(to: CGPoint(x: tip.x - ux * head + px * width / 2, y: tip.y - uy * head + py * width / 2))
    path.closeSubpath()
    return path
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.setShouldAntialias(true)

    let tile = tilePath()

    // Drop shadow under the tile, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(tile)
    context.setFillColor(color(0x0B3A6B))
    context.fillPath()
    context.restoreGState()

    // Tile: mint at the top, deep blue at the bottom.
    fill(tile, in: context, gradient: [color(0x3DE0C2), color(0x1C9ED6), color(0x1646B0)], locations: [0, 0.5, 1],
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // A picture frame, like the framed-picture emoji: a thick white frame with a thinner inner
    // mat, and a landscape (sun and two peaks) showing the tile through it.
    let frame = CGRect(x: 232, y: 282, width: 560, height: 460)
    let frameBorder: CGFloat = 54
    let matBorder: CGFloat = 0
    let picture = frame.insetBy(dx: frameBorder + matBorder, dy: frameBorder + matBorder)

    let framePath = CGMutablePath()
    framePath.addPath(CGPath(roundedRect: frame, cornerWidth: 30, cornerHeight: 30, transform: nil))
    framePath.addRect(frame.insetBy(dx: frameBorder, dy: frameBorder))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x082A5A, 0.45))
    context.addPath(framePath)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath(using: .evenOdd)
    context.restoreGState()
    fill(framePath, in: context, gradient: [color(0xFFFFFF), color(0xDDF3FF)], locations: [0, 1],
         from: CGPoint(x: 512, y: frame.maxY), to: CGPoint(x: 512, y: frame.minY), rule: .evenOdd)

    // A thin inner line on the frame, like the lip of a real one.
    context.saveGState()
    context.addRect(frame.insetBy(dx: frameBorder - 14, dy: frameBorder - 14))
    context.setStrokeColor(color(0x1C9ED6, 0.35))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    // The landscape inside: sun and two peaks in white, over the tile's gradient.
    context.saveGState()
    context.addRect(picture)
    context.clip()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x082A5A, 0.35))
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: picture.maxX - 118, y: picture.maxY - 112, width: 70, height: 70))
    let back = CGMutablePath()
    back.move(to: CGPoint(x: picture.minX - 20, y: picture.minY - 20))
    back.addLine(to: CGPoint(x: picture.minX + 118, y: picture.minY + 150))
    back.addLine(to: CGPoint(x: picture.minX + 214, y: picture.minY + 48))
    back.addLine(to: CGPoint(x: picture.minX + 214, y: picture.minY - 20))
    back.closeSubpath()
    context.addPath(back)
    context.setFillColor(color(0xFFFFFF, 0.72))
    context.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: picture.minX + 96, y: picture.minY - 20))
    front.addLine(to: CGPoint(x: picture.minX + 250, y: picture.minY + 128))
    front.addLine(to: CGPoint(x: picture.maxX + 20, y: picture.minY - 20))
    front.closeSubpath()
    context.addPath(front)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // Subtle inner rim on the tile.
    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size).write(to: output.appending(path: "icon_\(size).png"))
}
print("Wrote icons to \(output.path)")
