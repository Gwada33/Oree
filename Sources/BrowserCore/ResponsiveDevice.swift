import Foundation

/// Mode responsive : la page s'affiche dans la taille (et, pour un téléphone ou une tablette, l'identité) d'un autre appareil, pour voir comment un site se comporte.
public struct ResponsiveDevice: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case phone, tablet, computer }
    public var id: String { name }
    public let name: String
    public let width: Int
    public let height: Int          // en portrait
    public let kind: Kind
    public var landscape = false

    public init(name: String, width: Int, height: Int, kind: Kind, landscape: Bool = false) { self.name = name; self.width = width; self.height = height; self.kind = kind; self.landscape = landscape }

    public static let presets: [ResponsiveDevice] = [
        .init(name: "iPhone SE", width: 375, height: 667, kind: .phone),
        .init(name: "iPhone 15", width: 393, height: 852, kind: .phone),
        .init(name: "iPhone 15 Pro Max", width: 430, height: 932, kind: .phone),
        .init(name: "iPad mini", width: 744, height: 1133, kind: .tablet),
        .init(name: "iPad Pro 11\"", width: 834, height: 1194, kind: .tablet),
        .init(name: "Portable", width: 1280, height: 800, kind: .computer),
        .init(name: "Écran large", width: 1920, height: 1080, kind: .computer),
    ]

    /// Largeur et hauteur affichées, selon l'orientation (un ordinateur reste en paysage).
    public var size: (width: Int, height: Int) {
        kind == .computer ? (width, height) : (landscape ? (height, width) : (width, height))
    }

    public var rotated: ResponsiveDevice { var copy = self; if kind != .computer { copy.landscape.toggle() }; return copy }

    /// L'identité annoncée aux sites : un téléphone ou une tablette se présente comme tel ; un ordinateur garde celle d'Orée.
    public var userAgent: String? {
        switch kind {
        case .phone: return UserAgent.iphoneString
        case .tablet: return "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .computer: return nil
        }
    }

    /// Ce que l'on peut montrer dans la place disponible (marge de 16 pt de chaque côté) : jamais plus grand que la fenêtre. `shrunk` si l'appareil ne tient pas.
    public func fit(in available: (width: Double, height: Double), margin: Double = 16) -> (width: Double, height: Double, shrunk: Bool) {
        let want = size
        let w = min(Double(want.width), max(200, available.width - 2 * margin)), h = min(Double(want.height), max(200, available.height - 2 * margin))
        return (w, h, w < Double(want.width) || h < Double(want.height))
    }

    public var label: String { "\(name) · \(size.width) × \(size.height)" }
}
