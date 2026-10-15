import Foundation

/// Page zoom steps and the per-site memory ("this site is always at 125 %"), as every browser has.
public enum ZoomPolicy {
    public static let levels: [Double] = [0.3, 0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
    public static let maxRemembered = 500

    /// The next level above `zoom` (the largest one if there is none).
    public static func zoomedIn(from zoom: Double) -> Double { levels.first { $0 > zoom + 0.001 } ?? levels.last! }

    /// The next level below `zoom` (the smallest one if there is none).
    public static func zoomedOut(from zoom: Double) -> Double { levels.last { $0 < zoom - 0.001 } ?? levels.first! }

    /// "125 %"
    public static func label(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded())) %" }

    /// What the zoom memory is keyed by: the host without "www.", lowercase. nil for pages that are not sites.
    public static func key(for url: URL?) -> String? {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https", var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The memory after setting `zoom` for `key`: 100 % forgets the site, and the memory never grows past `maxRemembered`
    /// (the oldest entry — alphabetical order is as good as any here — makes room).
    public static func updated(_ memory: [String: Double], key: String, zoom: Double) -> [String: Double] {
        var result = memory
        if abs(zoom - 1) < 0.001 { result[key] = nil } else { result[key] = zoom }
        while result.count > maxRemembered, let first = result.keys.sorted().first(where: { $0 != key }) { result[first] = nil }
        return result
    }

    /// The zoom to show a page at: the remembered one, kept inside the supported range.
    public static func zoom(for url: URL?, memory: [String: Double]) -> Double {
        guard let key = key(for: url), let value = memory[key], value.isFinite else { return 1 }
        return min(max(value, levels.first!), levels.last!)
    }
}
