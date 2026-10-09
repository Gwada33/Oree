import Foundation

/// Small, pure parsers for the HTTP details a downloader depends on.
public enum HTTPParsing {
    /// `Content-Range: bytes 0-0/12345` → 12345 (nil for `*` or garbage).
    public static func totalFromContentRange(_ header: String?) -> Int64? {
        guard let header else { return nil }
        guard let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// `Retry-After: 120` or an HTTP date → seconds to wait (never negative).
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// File name from `Content-Disposition` (RFC 6266: `filename*=UTF-8''…` wins over `filename="…"`), else the URL.
    public static func fileName(contentDisposition: String?, url: URL, suggested: String? = nil) -> String {
        if let disposition = contentDisposition {
            if let star = parameter("filename*", in: disposition) {
                let parts = star.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let decoded = String(parts[2]).removingPercentEncoding, !decoded.isEmpty {
                    return sanitize(decoded)
                }
            }
            if let plain = parameter("filename", in: disposition), !plain.isEmpty { return sanitize(plain) }
        }
        if let suggested, !suggested.isEmpty { return sanitize(suggested) }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return sanitize(last.removingPercentEncoding ?? last) }
        return "téléchargement"
    }

    /// Never trust a server-supplied name to stay inside the destination folder, or to be unreadable.
    public static func sanitize(_ name: String) -> String {
        var cleaned = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "téléchargement" }
        return String(cleaned.prefix(200))
    }

    /// Strong validators only: a weak ETag (`W/"…"`) cannot guarantee byte-identical ranges.
    public static func strongETag(_ header: String?) -> String? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty, !header.hasPrefix("W/") else { return nil }
        return header
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == name else { continue }
            var value = pair[1]
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return value
        }
        return nil
    }
}

/// Exponential backoff with jitter, honoring a server's `Retry-After`.
public enum Backoff {
    public static func delay(attempt: Int, retryAfter: TimeInterval? = nil, base: TimeInterval = 1, cap: TimeInterval = 60,
                             jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0), 600) }
        let exponential = min(cap, base * pow(2, Double(max(0, attempt))))
        return exponential * jitter
    }
}

/// RFC 8288 `Link` headers, as used by Metalink/HTTP (RFC 6249): `<url>; rel=duplicate; pri=1`.
public struct HTTPLink: Sendable, Equatable {
    public var url: URL
    public var rel: String
    public var type: String?
    public var priority: Int
}

extension HTTPParsing {
    /// All links of a (possibly folded) `Link` header, resolved against `base`.
    public static func links(_ header: String?, base: URL) -> [HTTPLink] {
        guard let header, !header.isEmpty else { return [] }
        var result: [HTTPLink] = []
        var depth = 0, start = header.startIndex
        var pieces: [Substring] = []
        for index in header.indices {
            switch header[index] {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            case "," where depth == 0:
                pieces.append(header[start..<index]); start = header.index(after: index)
            default: break
            }
        }
        pieces.append(header[start...])
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") else { continue }
            let target = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard let url = URL(string: target, relativeTo: base)?.absoluteURL else { continue }
            var rel = "", type: String?, priority = 999_999
            for parameter in trimmed[trimmed.index(after: close)...].split(separator: ";") {
                let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch pair[0].lowercased() {
                case "rel": rel = value.lowercased()
                case "type": type = value.lowercased()
                case "pri": priority = Int(value) ?? priority
                default: break
                }
            }
            result.append(HTTPLink(url: url, rel: rel, type: type, priority: priority))
        }
        return result
    }
}

/// Minimal Metalink 4 (RFC 5854) reader: size, hashes and mirror URLs by priority.
public struct Metalink: Sendable, Equatable {
    public var size: Int64?
    public var sha256: String?
    public var urls: [(url: URL, priority: Int)]

    public static func == (a: Metalink, b: Metalink) -> Bool {
        a.size == b.size && a.sha256 == b.sha256 && a.urls.map(\.url) == b.urls.map(\.url) && a.urls.map(\.priority) == b.urls.map(\.priority)
    }

    public static func parse(_ data: Data) -> Metalink? {
        final class Delegate: NSObject, XMLParserDelegate {
            var size: Int64?, sha256: String?
            var urls: [(URL, Int)] = []
            private var text = "", priority = 999_999, hashType = "", inFile = false
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                text = ""
                switch name {
                case "file": inFile = true
                case "url": priority = Int(attributes["priority"] ?? "") ?? 999_999
                case "hash": hashType = attributes["type"]?.lowercased() ?? ""
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch name {
                case "size": if inFile { size = Int64(value) }
                case "url": if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { urls.append((url, priority)) }
                case "hash": if hashType == "sha-256" || hashType == "sha256" { sha256 = value.lowercased() }
                default: break
                }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.urls.isEmpty else { return nil }
        return Metalink(size: delegate.size, sha256: delegate.sha256, urls: delegate.urls.sorted { $0.1 < $1.1 }.map { (url: $0.0, priority: $0.1) })
    }
}
