import Foundation

/// Small pure helpers for the home page (kept out of the UI so they can be tested).
public enum HomeFormatting {
    /// "à l'instant", "il y a 5 min", "il y a 3 h", "hier", "il y a 4 j".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "à l'instant"
        case ..<3600: return "il y a \(seconds / 60) min"
        case ..<86_400: return "il y a \(seconds / 3600) h"
        case ..<172_800: return "hier"
        default: return "il y a \(seconds / 86_400) j"
        }
    }

    /// ("jeudi", "8 octobre") in French, independent of the system language.
    public static func frenchDate(_ date: Date, calendar: Calendar = .current) -> (weekday: String, dayMonth: String) {
        let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
        let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        return (weekdays[(c.weekday ?? 1) - 1], "\(c.day ?? 1) \(months[(c.month ?? 1) - 1])")
    }

    /// A stable hue per site, so a favorite keeps one color everywhere.
    public static func hue(forHost host: String) -> OreeTokens.Hue {
        let palette: [OreeTokens.Hue] = [.marine, .mousse, .prune, .ocre, .graphite, .brique]
        let hash = host.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    /// Host without "www." for display.
    public static func displayHost(_ urlString: String) -> String {
        let host = URL(string: urlString)?.host ?? urlString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Where the new-tab page gets its backdrop from.
public enum HomeBackground: String, CaseIterable, Sendable, Codable {
    case uni, papier, horizon, photo
    public var label: String {
        switch self { case .uni: "Uni"; case .papier: "Papier"; case .horizon: "Horizon"; case .photo: "Photo" }
    }
}
