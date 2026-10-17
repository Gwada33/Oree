import Foundation

/// Les positions des surfaces de Luciole dans la page (pur : toutes les mesures sont en points, repère de la page, y vers le bas).
public enum LucioleGeometry {
    public static let capsuleHeight = 66.0
    public static let bubbleWidth = 380.0
    public static let pillHeight = 38.0
    public static let margin = 20.0

    /// La capsule : min(620, 70 % de la page) de large, centrée, en bas.
    public static func capsule(in page: CGSize) -> CGRect {
        let width = min(620, page.width * 0.7)
        return CGRect(x: (page.width - width) / 2, y: page.height - capsuleHeight - margin - 14, width: width, height: capsuleHeight)
    }

    /// Les suggestions, au-dessus de la capsule, en colonne centrée sur elle.
    public static func suggestions(widths: [Double], above capsule: CGRect, gap: Double = 8) -> [CGRect] {
        var frames: [CGRect] = []
        var y = capsule.minY - 14 - pillHeight
        for width in widths.reversed() {
            frames.append(CGRect(x: capsule.midX - width / 2, y: y, width: width, height: pillHeight)); y -= pillHeight + gap
        }
        return frames.reversed()
    }

    public enum Side: Equatable, Sendable { case right, left, below, above, corner }

    /// La bulle de réponse, posée à côté du passage `anchor` sans jamais le cacher : à droite si la place suffit, sinon à gauche, sinon dessous, sinon dessus.
    /// Sans passage (question posée depuis la capsule) : en bas à droite de la page, au-dessus de la capsule, sans fil.
    public static func bubble(height: Double, anchor: CGRect?, page: CGSize, avoiding capsule: CGRect?) -> (frame: CGRect, side: Side) {
        let width = bubbleWidth
        let maxY = (capsule?.minY ?? page.height) - margin
        func clamped(_ rect: CGRect) -> CGRect {
            var r = rect
            r.origin.x = min(max(r.origin.x, margin), max(page.width - r.width - margin, margin))
            r.origin.y = min(max(r.origin.y, margin), max(maxY - r.height, margin))
            return r
        }
        guard let anchor else {
            return (clamped(CGRect(x: page.width - width - margin, y: maxY - height, width: width, height: height)), .corner)
        }
        let gap = 18.0
        let candidates: [(CGRect, Side)] = [
            (CGRect(x: anchor.maxX + gap, y: anchor.minY, width: width, height: height), .right),
            (CGRect(x: anchor.minX - gap - width, y: anchor.minY, width: width, height: height), .left),
            (CGRect(x: anchor.midX - width / 2, y: anchor.maxY + gap, width: width, height: height), .below),
            (CGRect(x: anchor.midX - width / 2, y: anchor.minY - gap - height, width: width, height: height), .above),
        ]
        let room = CGRect(x: margin, y: margin, width: page.width - 2 * margin, height: maxY - margin)
        for (rect, side) in candidates where room.contains(rect) && !rect.intersects(anchor) { return (rect, side) }
        // Aucune place nette : le côté le plus dégagé, décalé pour ne pas recouvrir le passage.
        let (rect, side) = candidates.first { !clamped($0.0).intersects(anchor) } ?? candidates[0]
        return (clamped(rect), side)
    }

    /// Trois gestes en éventail (Expliquer, Traduire, Garder) à droite du point `tip` (le bout de la dernière ligne sélectionnée), à gauche si la place manque.
    public static func fan(tip: CGPoint, count: Int, size: CGSize, page: CGSize) -> (frames: [CGRect], onRight: Bool) {
        let radius = 64.0, spread = 0.55                                    // rayon et ouverture (radians) entre deux gestes
        let onRight = tip.x + radius + size.width + margin < page.width
        let direction = onRight ? 1.0 : -1.0
        let frames = (0..<count).map { i -> CGRect in
            let angle = (Double(i) - Double(count - 1) / 2) * spread
            let x = tip.x + direction * radius * cos(angle) - (onRight ? 0 : size.width)
            let y = tip.y + radius * sin(angle) - size.height / 2
            var rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            rect.origin.x = min(max(rect.origin.x, margin), page.width - size.width - margin)
            rect.origin.y = min(max(rect.origin.y, margin), page.height - size.height - margin)
            return rect
        }
        return (frames, onRight)
    }
}
