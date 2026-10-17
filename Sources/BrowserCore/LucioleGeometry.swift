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
        let radius = 88.0, spread = 0.58                                    // rayon et ouverture (radians) entre deux gestes
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


public extension LucioleGeometry {
    /// Un morceau de la page qu'une carte ne doit pas recouvrir : `weight` 3 pour un média, un bouton ou un champ, 1 pour du texte.
    struct Occupied: Equatable, Sendable {
        public var rect: CGRect; public var weight: Double
        public init(rect: CGRect, weight: Double) { self.rect = rect; self.weight = weight }
    }

    /// Les emplacements où poser une carte de `size` : au-dessus de la capsule (à gauche, puis à droite), puis dans les colonnes de gauche et de droite.
    static func bubbleSpots(size: CGSize, page: CGSize, capsule: CGRect) -> [CGRect] {
        let top = 70.0, bottom = capsule.minY - 12 - size.height
        func clamp(_ y: Double) -> Double { min(max(y, 16), max(page.height - size.height - 16, 16)) }
        return [
            CGRect(x: capsule.minX, y: max(bottom, 16), width: size.width, height: size.height),
            CGRect(x: capsule.maxX - size.width, y: max(bottom, 16), width: size.width, height: size.height),
            CGRect(x: page.width - size.width - 20, y: clamp(top), width: size.width, height: size.height),
            CGRect(x: 20, y: clamp(top), width: size.width, height: size.height),
            CGRect(x: page.width - size.width - 20, y: clamp((page.height - size.height) / 2), width: size.width, height: size.height),
            CGRect(x: 20, y: clamp((page.height - size.height) / 2), width: size.width, height: size.height),
        ]
    }

    /// L'emplacement qui recouvre le moins de page (surface pondérée) ; le premier si plusieurs sont aussi bons (la carte garde sa place habituelle quand rien ne la gêne).
    /// La capsule compte comme un obstacle très lourd : une carte ne la couvre jamais.
    static func leastCovering(spots: [CGRect], occupied: [Occupied], capsule: CGRect?, tolerance: Double = 0.15) -> Int {
        func cost(_ spot: CGRect) -> Double {
            var total = 0.0
            for item in occupied { let overlap = spot.intersection(item.rect); if !overlap.isNull { total += Double(overlap.width * overlap.height) * item.weight } }
            if let capsule { let overlap = spot.intersection(capsule); if !overlap.isNull { total += Double(overlap.width * overlap.height) * 100 } }
            return total
        }
        let costs = spots.map(cost)
        guard let best = costs.min(), let first = costs.first else { return 0 }
        // Le premier emplacement garde la place s'il est presque aussi bon que le meilleur (pas de saut pour un gain minime).
        let spotArea = Double(spots.first.map { $0.width * $0.height } ?? 1)
        if first - best <= spotArea * tolerance * 0.2 { return 0 }
        return costs.firstIndex(of: best) ?? 0
    }
}
