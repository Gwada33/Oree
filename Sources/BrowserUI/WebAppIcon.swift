import AppKit
import BrowserCore

/// L'icône d'une application : celle du site (ou une lettre sur fond coloré à défaut), posée sur un carré arrondi comme les icônes de macOS.
enum WebAppIcon {
    static func render(source: NSImage?, name: String, size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let margin = size * 0.1, rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let shape = NSBezierPath(roundedRect: rect, xRadius: size * 0.19, yRadius: size * 0.19)
        if let source, source.size.width > 0 {
            NSColor.white.setFill(); shape.fill()
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            let inner = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
            let scale = min(inner.width / source.size.width, inner.height / source.size.height)
            let drawn = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: inner.midX - drawn.width / 2, y: inner.midY - drawn.height / 2, width: drawn.width, height: drawn.height), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let hue = CGFloat(abs(name.hashValue) % 360) / 360
            NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).setFill(); shape.fill()
            let letter = String(name.trimmingCharacters(in: .whitespaces).first ?? "A").uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold), .foregroundColor: NSColor.white]
            let measured = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2), withAttributes: attributes)
        }
        image.unlockFocus()
        return image
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Fabrique le `.icns` (iconutil) à partir d'une icône de 1024 px.
    static func writeICNS(from image: NSImage, to destination: URL) -> Bool {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("oree-\(UUID().uuidString).iconset", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        do { try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { return false }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(base * scale)
                let small = NSImage(size: NSSize(width: pixels, height: pixels))
                small.lockFocus(); image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1); small.unlockFocus()
                guard let data = png(small) else { return false }
                try? data.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }
        return process.terminationStatus == 0
    }
}
