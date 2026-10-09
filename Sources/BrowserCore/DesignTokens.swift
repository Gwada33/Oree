import Foundation

/// « Orée » design tokens — the single source of truth for colors, spacing,
/// radii, density and motion. Pure values (no AppKit) so they can be unit
/// tested, notably for text contrast. `Theme` in BrowserUI turns them into
/// dynamic NSColors that follow light/dark automatically.
public struct RGBA: Sendable, Equatable {
    public let r: Double, g: Double, b: Double, a: Double   // 0...1
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `0xRRGGBB` plus optional alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    /// Alpha-composite `self` over an opaque background.
    public func over(_ bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a))
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: RGBA) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A color with its light and dark variant.
public struct DualColor: Sendable, Equatable {
    public let light: RGBA, dark: RGBA
    public init(light: RGBA, dark: RGBA) { self.light = light; self.dark = dark }
    public init(_ light: UInt32, _ dark: UInt32) { self.init(light: RGBA(hex: light), dark: RGBA(hex: dark)) }
    public func resolved(dark isDark: Bool) -> RGBA { isDark ? dark : light }
}

public enum OreeTokens {
    // MARK: Surfaces
    public static let chrome  = DualColor(0xECE8E1, 0x161514)
    public static let page    = DualColor(0xFBFAF7, 0x1E1D1B)
    public static let raised  = DualColor(0xFFFFFF, 0x2A2926)
    public static let field   = DualColor(0xE2DDD5, 0x272622)
    public static let text    = DualColor(0x1D1C1A, 0xEEEAE3)
    public static let muted   = DualColor(0x5E5A53, 0xA8A299)
    public static let line = DualColor(light: RGBA(hex: 0x1D1C1A, alpha: 0.12), dark: RGBA(hex: 0xEEEAE3, alpha: 0.11))
    public static let hover = DualColor(light: RGBA(hex: 0x1D1C1A, alpha: 0.055), dark: RGBA(hex: 0xEEEAE3, alpha: 0.06))
    public static let press = DualColor(light: RGBA(hex: 0x1D1C1A, alpha: 0.10), dark: RGBA(hex: 0xEEEAE3, alpha: 0.11))

    // MARK: Hues (spaces and accent)
    public enum Hue: String, CaseIterable, Sendable, Codable {
        case mousse, brique, ocre, marine, prune, graphite

        public var solid: DualColor {
            switch self {
            case .mousse:   DualColor(0x2F7354, 0x7FCBA2)
            case .brique:   DualColor(0xB04A2A, 0xF0956F)
            case .ocre:     DualColor(0x8A5E0E, 0xE2B455)
            case .marine:   DualColor(0x2D5C9A, 0x91B5EA)
            case .prune:    DualColor(0x87406F, 0xDF98C7)
            case .graphite: DualColor(0x3A3936, 0xD9D4CC)
            }
        }
        /// ~12 % tint used for chips and the selected spine.
        public func soft(_ amount: Double = 0.12) -> DualColor {
            DualColor(light: solid.light.withAlpha(amount), dark: solid.dark.withAlpha(amount))
        }
        /// Text color on a soft tint. Slightly deeper than `solid` in light mode
        /// (lighter in dark) so labels keep ≥ 4.5:1 on their own tint — values from the mockup.
        public var ink: DualColor {
            switch self {
            case .mousse:   DualColor(0x285F46, 0x9ED8B8)
            case .brique:   DualColor(0x953C20, 0xF4AE90)
            case .ocre:     DualColor(0x74500B, 0xEDC676)
            case .marine:   DualColor(0x264F86, 0xADC8F0)
            case .prune:    DualColor(0x74365F, 0xE9B3D6)
            case .graphite: DualColor(0x3A3936, 0xE2DED7)
            }
        }
        /// Text drawn on a *solid* hue background.
        public var onSolid: DualColor { DualColor(0xFFFFFF, 0x161514) }

        public var label: String {
            switch self {
            case .mousse: "Mousse"; case .brique: "Brique"; case .ocre: "Ocre"
            case .marine: "Marine"; case .prune: "Prune"; case .graphite: "Graphite"
            }
        }
    }

    // MARK: Scale
    public static let spacing: [Double] = [2, 4, 6, 8, 12, 16, 24, 32, 48]
    /// Corner radius presets; `radius` (0–16, even) scales `sm/base/lg` in the app.
    public static let defaultRadius = 10.0
    public static func radii(base: Double) -> (sm: Double, base: Double, lg: Double) {
        let b = min(max(base, 0), 16)
        return (max(0, (b * 0.6).rounded()), b, min(b + 4, 20))
    }

    public enum Density: String, CaseIterable, Sendable, Codable {
        case aeree, standard, compacte
        public var rowHeight: Double { switch self { case .aeree: 34; case .standard: 30; case .compacte: 25 } }
        public var fontSize: Double { switch self { case .aeree: 13.5; case .standard: 13; case .compacte: 12.5 } }
        public var label: String { switch self { case .aeree: "Aérée"; case .standard: "Standard"; case .compacte: "Compacte" } }
    }

    public enum Motion {
        public static let fast = 0.12, base = 0.18, slow = 0.26
        /// cubic-bezier(.2,.8,.2,1)
        public static let curve: (Double, Double, Double, Double) = (0.2, 0.8, 0.2, 1)
    }

    // MARK: Layout metrics
    public enum Metrics {
        public static let sidebarWidth = 286.0
        public static let railWidth = 52.0
        public static let compactSidebarWidth = 56.0
        /// Height of the title/toolbar row. 52 pt is the unified macOS title bar, so the traffic lights are centered by the system.
        public static let toolbarHeight = 52.0
        /// Toolbar height when the tab strip sits above it (the strip carries the traffic lights).
        public static let stackedToolbarHeight = 44.0
        public static let addressMaxWidth = 660.0
        public static let lisiereWidth = 3.0
        public static let pageCornerRadius = 14.0
        public static let narrowWindow = 900.0
    }
}

extension RGBA {
    public func withAlpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
}
