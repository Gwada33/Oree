import Foundation

/// Pure rules for page translation (the DOM work and the Apple Translation session live in BrowserUI).
public enum TranslationPolicy {
    /// Only real web pages: the start page, settings and error pages are ours and already in the user's language.
    public static func canTranslate(url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// "fr-CA", "fr_CA", "zh-Hans-CN" → "fr", "fr", "zh". Empty for an unusable tag.
    public static func primary(_ tag: String) -> String {
        let first = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return first.lowercased()
    }

    /// Offer the button only when the page is clearly in another language than the one the user reads.
    public static func shouldOffer(pageLanguage: String?, targetLanguage: String) -> Bool {
        guard let pageLanguage else { return false }
        let page = primary(pageLanguage), target = primary(targetLanguage)
        // "und" = the recognizer could not tell; "mul" = declared multilingual.
        return !page.isEmpty && !target.isEmpty && page != target && page != "und" && page != "mul"
    }

    /// Whether `text` is worth translating: it has at least one letter (prices, dates and separators stay as they are).
    public static func isTranslatable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}

/// One piece of page text that the page-side script handed out. `id` is only meaningful to that script.
public struct TranslationSegment: Equatable, Sendable {
    public let id: Int
    public let text: String
    public init(id: Int, text: String) { self.id = id; self.text = text }
}

/// Translations already obtained, shared by every page of a tab: menus and buttons ("Sign in", "Read more") come
/// back on every page, and the system model takes ~0.3 s per segment, so asking twice would be the main cost.
public struct TranslationMemory: Sendable {
    private var entries: [String: String] = [:]
    private let limit: Int
    public init(limit: Int = 5000) { self.limit = limit }

    public var count: Int { entries.count }
    public subscript(text: String) -> String? { entries[text] }

    public mutating func store(_ translated: String, for text: String) {
        if entries.count >= limit, entries[text] == nil { entries.removeAll(keepingCapacity: true) }
        entries[text] = translated
    }
}

/// What to do with one round of segments: what is already known, and each text that still needs the model once.
public struct TranslationRound: Equatable, Sendable {
    /// Segments whose translation is already in memory.
    public let known: [(id: Int, text: String)]
    /// Texts to send to the model, in the order of first appearance (which is nearest-to-screen first), without repeats.
    public let pending: [String]
    /// Every segment id waiting for a given pending text.
    public let waiting: [String: [Int]]

    public init(segments: [TranslationSegment], memory: TranslationMemory) {
        var known: [(id: Int, text: String)] = []
        var pending: [String] = []
        var waiting: [String: [Int]] = [:]
        for segment in segments {
            if let done = memory[segment.text] {
                known.append((segment.id, done))
            } else if !TranslationPolicy.isTranslatable(segment.text) {
                known.append((segment.id, segment.text))   // nothing to translate: settle it so it is not asked again
            } else {
                if waiting[segment.text] == nil { pending.append(segment.text) }
                waiting[segment.text, default: []].append(segment.id)
            }
        }
        self.known = known
        self.pending = pending
        self.waiting = waiting
    }

    public static func == (lhs: TranslationRound, rhs: TranslationRound) -> Bool {
        lhs.pending == rhs.pending && lhs.waiting == rhs.waiting
            && lhs.known.map(\.id) == rhs.known.map(\.id) && lhs.known.map(\.text) == rhs.known.map(\.text)
    }
}
