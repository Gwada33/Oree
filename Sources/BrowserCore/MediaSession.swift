import Foundation

/// What a page is playing, as reported by its media script (see `MediaScript`): enough to show a "now playing" card and drive it.
public struct MediaInfo: Equatable, Sendable, Codable {
    public var title: String
    public var artist: String
    /// Address of the cover picture given by the page (Media Session), if any.
    public var artwork: String?
    public var position: Double
    /// 0 or infinite for a live stream.
    public var duration: Double
    public var paused: Bool
    public var hasVideo: Bool
    public var pictureInPicture: Bool
    /// Playback speed (1 = normal).
    public var rate: Double

    public init(title: String = "", artist: String = "", artwork: String? = nil, position: Double = 0, duration: Double = 0,
                paused: Bool = false, hasVideo: Bool = false, pictureInPicture: Bool = false, rate: Double = 1) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.position = position; self.duration = duration
        self.paused = paused; self.hasVideo = hasVideo; self.pictureInPicture = pictureInPicture; self.rate = rate
    }

    public var isLive: Bool { !(duration.isFinite && duration > 0) }
    /// 0…1, or nil for a live stream.
    public var progress: Double? { isLive ? nil : min(max(position / duration, 0), 1) }

    /// Decodes the script's report; nil on anything that is not a media report (the script sends `{"none":true}` when nothing plays).
    public static func parse(_ json: String) -> MediaInfo? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["none"] == nil else { return nil }
        func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
        let artwork = (object["artwork"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MediaInfo(title: (object["title"] as? String) ?? "", artist: (object["artist"] as? String) ?? "", artwork: artwork,
                         position: number("position"), duration: number("duration"), paused: (object["paused"] as? Bool) ?? false,
                         hasVideo: (object["video"] as? Bool) ?? false, pictureInPicture: (object["pip"] as? Bool) ?? false,
                         rate: MediaPolicy.validRate((object["rate"] as? NSNumber)?.doubleValue))
    }
}

public enum MediaPolicy {
    /// The speeds the card steps through.
    public static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// A speed a page reports, kept inside what a player accepts (0.0625…16); anything else counts as normal speed.
    public static func validRate(_ value: Double?) -> Double {
        guard let value, value.isFinite, (0.0625...16).contains(value) else { return 1 }
        return value
    }

    /// The next speed in the cycle after `rate` (from an odd speed, the next one above; after the fastest, back to the slowest).
    public static func nextRate(after rate: Double) -> Double { rates.first { $0 > rate + 0.001 } ?? rates[0] }

    /// "1×", "1,25×", "0,5×" (French decimal comma).
    public static func rateLabel(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate).replacingOccurrences(of: ".", with: ",")
        return text + "×"
    }

    /// A card is worth showing for a real piece of media, not for a 2-second UI sound or a muted decorative loop.
    public static func isWorthShowing(_ info: MediaInfo, playing: Bool) -> Bool {
        if info.isLive { return playing }
        return info.duration >= 20 && (playing || info.position > 0)
    }

    /// "3:07", "1:02:03"; "direct" for a live stream.
    public static func clock(_ seconds: Double, live: Bool = false) -> String {
        guard !live, seconds.isFinite else { return "direct" }
        let total = max(Int(seconds.rounded()), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A Bluetooth audio device and its battery, read from `system_profiler SPBluetoothDataType -json`.
public struct BluetoothAudioDevice: Equatable, Sendable {
    public var name: String
    /// Headphones, Headset, Speaker… (the profiler's "minor type"), if known.
    public var kind: String?
    public var main: Int?, left: Int?, right: Int?, caseLevel: Int?

    public init(name: String, kind: String? = nil, main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.name = name; self.kind = kind; self.main = main; self.left = left; self.right = right; self.caseLevel = caseLevel
    }

    /// The number to show: the single battery, or the weaker earbud (the one that gives out first). nil if the device reports none.
    public var shownLevel: Int? { main ?? [left, right].compactMap { $0 }.min() }

    /// Connected devices with their battery. Anything unreadable gives an empty list.
    public static func parse(profilerJSON: Data) -> [BluetoothAudioDevice] {
        guard let root = (try? JSONSerialization.jsonObject(with: profilerJSON)) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothAudioDevice] = []
        for section in sections {
            for entry in (section["device_connected"] as? [[String: Any]]) ?? [] {
                for (name, rawProperties) in entry {
                    guard let properties = rawProperties as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        guard let text = properties[key] as? String else { return nil }
                        return Int(text.filter(\.isNumber))
                    }
                    devices.append(BluetoothAudioDevice(name: name, kind: properties["device_minorType"] as? String,
                                                        main: level("device_batteryLevelMain"), left: level("device_batteryLevelLeft"),
                                                        right: level("device_batteryLevelRight"), caseLevel: level("device_batteryLevelCase")))
                }
            }
        }
        return devices
    }
}
