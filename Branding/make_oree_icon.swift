// Draws the Orée icon: the browser's own layout in miniature — a thin "lisière" line and the
// page sheet (rounded top-left corner) on a mousse-green squircle. Flat colors, no gradient.
// Usage: swift make_oree_icon.swift <output-directory>   → AppIcon-1024.png, oree-mark.png
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let mousse = rgb(0x2F, 0x73, 0x54), paper = rgb(0xFB, 0xFA, 0xF7), deep = rgb(0x24, 0x5A, 0x42)

func context(_ size: Int) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true); c.setShouldAntialias(true); c.interpolationQuality = .high
    return c
}
func save(_ c: CGContext, _ name: String) {
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(); let a = rect.width / 2, b = rect.height / 2, c = CGPoint(x: rect.midX, y: rect.midY)
    for i in 0...360 {
        let t = CGFloat(i) * .pi / 180
        let x = c.x + a * pow(abs(cos(t)), 2 / n) * (cos(t) < 0 ? -1 : 1)
        let y = c.y + b * pow(abs(sin(t)), 2 / n) * (sin(t) < 0 ? -1 : 1)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}
/// The two shapes of the mark, centered in `box`.
func drawMark(_ c: CGContext, in box: CGRect, lisiere: CGColor, sheet: CGColor) {
    let u = box.width / 100
    // lisière: thin vertical rounded bar on the left
    let bar = CGRect(x: box.minX + 14 * u, y: box.minY + 14 * u, width: 8 * u, height: 72 * u)
    c.setFillColor(lisiere); c.addPath(CGPath(roundedRect: bar, cornerWidth: 4 * u, cornerHeight: 4 * u, transform: nil)); c.fillPath()
    // page sheet: flush right/bottom, top-left corner very round (CG origin is bottom-left → top-left is maxY)
    let r = 26 * u
    let x0 = box.minX + 30 * u, x1 = box.maxX - 14 * u, y0 = box.minY + 14 * u, y1 = box.maxY - 14 * u
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: y0))
    path.addLine(to: CGPoint(x: x1, y: y0))
    path.addLine(to: CGPoint(x: x1, y: y1))
    path.addLine(to: CGPoint(x: x0 + r, y: y1))
    path.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    path.closeSubpath()
    c.setFillColor(sheet); c.addPath(path); c.fillPath()
}

let size = 1024
let icon = context(size)
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
icon.saveGState()
icon.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.28))
icon.setFillColor(mousse); icon.addPath(squircle(rect)); icon.fillPath()
icon.restoreGState()
drawMark(icon, in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1), lisiere: paper.copy(alpha: 0.55)!, sheet: paper)
save(icon, "AppIcon-1024.png")

let mark = context(512)
drawMark(mark, in: CGRect(x: 0, y: 0, width: 512, height: 512), lisiere: mousse.copy(alpha: 0.55)!, sheet: mousse)
save(mark, "oree-mark.png")
print("ok")
