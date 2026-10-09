// Draws the Atoll logo with CoreGraphics so it stays razor sharp at every size.
// Usage: swift make_logo.swift <output-directory>
// Writes: AppIcon-1024.png (macOS app icon), atoll-mark.png (symbol only, transparent),
//         atoll-lockup-light.png / atoll-lockup-dark.png (symbol + name), preview sizes.
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

// Palette (matches the app: near-black surfaces, lime accent, plus the aqua of a lagoon)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let lime = rgb(198, 244, 50), aqua = rgb(64, 214, 190), deepAqua = rgb(18, 74, 84)
let ink = rgb(11, 12, 14), inkTop = rgb(28, 31, 37)

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ ctx: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

/// iOS/macOS-style "squircle" (superellipse), not a plain rounded rectangle.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, c = CGPoint(x: rect.midX, y: rect.midY)
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180
        let x = pow(abs(cos(t)), 2 / n) * a * (cos(t) < 0 ? -1 : 1)
        let y = pow(abs(sin(t)), 2 / n) * b * (sin(t) < 0 ? -1 : 1)
        let p = CGPoint(x: c.x + x, y: c.y + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// The atoll: a ring of islets around a lagoon, with a dot at the centre.
func drawMark(_ ctx: CGContext, center c: CGPoint, radius R: CGFloat, ringWidth w: CGFloat, background: Bool) {
    // Lagoon: a soft, deep-water disc inside the ring
    if background {
        ctx.saveGState()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(24, 96, 108, 0.55), rgb(11, 12, 14, 0)] as CFArray, locations: [0, 1])!
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)); ctx.clip()
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [])
        ctx.restoreGState()
    }

    // A ring of three islets (an atoll is a ring of reef broken by channels), filled by one lime -> aqua gradient.
    // Angles are the centre line of each islet, in degrees counter-clockwise from east; the round caps eat ~12 degrees each side.
    let islets: [(CGFloat, CGFloat)] = [(38, 140), (177, 230), (267, 366)]
    let ring = CGMutablePath()
    for (from, to) in islets {
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: R, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: false)
        ring.addPath(arc.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.10), blur: w * 0.45, color: rgb(0, 0, 0, background ? 0.45 : 0.0))
    ctx.addPath(ring); ctx.setFillColor(lime); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(ring); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [lime, rgb(150, 236, 120), aqua] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - R, y: c.y + R), end: CGPoint(x: c.x + R, y: c.y - R), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // soft light on the upper edge of the reef
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(255, 255, 255, 0.40), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: c.x, y: c.y + R + w / 2), end: CGPoint(x: c.x, y: c.y + R - w * 0.15), options: [])
    ctx.restoreGState()

    // The dot at the centre: "you are here"
    let r = w * 0.50
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 1.2, color: rgb(198, 244, 50, background ? 0.55 : 0.0))
    ctx.setFillColor(rgb(244, 248, 250))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
}

// ---- 1. macOS app icon (1024 canvas, 824 px body, as Apple's template)
do {
    let ctx = makeContext(1024, 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(shape); ctx.setFillColor(ink); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [inkTop, ink] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    drawMark(ctx, center: CGPoint(x: 512, y: 512), radius: 238, ringWidth: 104, background: true)
    ctx.restoreGState()
    // hairline highlight around the body, like system icons
    ctx.saveGState(); ctx.addPath(shape); ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()
    savePNG(ctx, "AppIcon-1024.png")
}

// ---- 2. symbol alone (transparent), for the web and ads
do {
    let ctx = makeContext(1024, 1024)
    drawMark(ctx, center: CGPoint(x: 512, y: 512), radius: 340, ringWidth: 150, background: false)
    savePNG(ctx, "atoll-mark.png")
}

// ---- 3. lockups: symbol + "atoll"
func lockup(textColor: NSColor, name: String) {
    let width = 1620, height = 800
    let ctx = makeContext(width, height)
    drawMark(ctx, center: CGPoint(x: 400, y: 400), radius: 250, ringWidth: 110, background: false)
    let descriptor = NSFont.systemFont(ofSize: 360, weight: .bold).fontDescriptor.withDesign(.rounded) ?? NSFont.systemFont(ofSize: 360, weight: .bold).fontDescriptor
    let font = NSFont(descriptor: descriptor, size: 400) ?? NSFont.systemFont(ofSize: 400, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: -8]
    let text = NSAttributedString(string: "atoll", attributes: attributes)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let size = text.size()
    text.draw(at: NSPoint(x: 740, y: 400 - size.height / 2 + 14))
    NSGraphicsContext.restoreGraphicsState()
    savePNG(ctx, name)
}
lockup(textColor: NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1), name: "atoll-lockup-light-text.png")
lockup(textColor: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1), name: "atoll-lockup-dark-text.png")
print("done")
