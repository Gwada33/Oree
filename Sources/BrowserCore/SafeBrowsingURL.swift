import Foundation
import CryptoKit

/// URL canonicalization and lookup-expression generation exactly as specified
/// by Google Safe Browsing v4 ("URLs and Hashing"). Everything is done on raw
/// bytes: after repeated percent-unescaping a URL can contain byte sequences
/// that aren't valid UTF-8, and the spec's result must still be byte-exact.
public enum SafeBrowsingURL {
    public struct Canonical: Equatable, Sendable {
        public let host: String
        public let path: String
        public let query: String?

        /// Canonical URL form used in the spec's examples.
        public var urlString: String {
            "http://" + host + path + (query.map { "?" + $0 } ?? "")
        }
    }

    public static func canonicalize(_ raw: String) -> Canonical? {
        canonicalize(bytes: Array(raw.utf8))
    }

    /// Byte-level entry point; the spec's test vectors include sequences
    /// (e.g. a lone 0x80) that can't be held in a Swift `String`.
    public static func canonicalize(bytes input: [UInt8]) -> Canonical? {
        var bytes = input

        // Trim surrounding whitespace, drop tab/CR/LF anywhere.
        while let first = bytes.first, isWhitespace(first) { bytes.removeFirst() }
        while let last = bytes.last, isWhitespace(last) { bytes.removeLast() }
        bytes.removeAll { $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }

        if let hash = bytes.firstIndex(of: UInt8(ascii: "#")) { bytes.removeSubrange(hash...) }

        bytes = stripScheme(bytes)

        // Percent-unescape until nothing changes.
        while true {
            let next = unescapeOnce(bytes)
            if next == bytes { break }
            bytes = next
        }

        // authority | path | query
        let delimiter = bytes.firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") }
        var authority = delimiter.map { Array(bytes[..<$0]) } ?? bytes
        let rest = delimiter.map { Array(bytes[$0...]) } ?? []

        var pathBytes = rest
        var queryBytes: [UInt8]?
        if let q = rest.firstIndex(of: UInt8(ascii: "?")) {
            pathBytes = Array(rest[..<q])
            queryBytes = Array(rest[rest.index(after: q)...])
        }

        // Strip userinfo and port.
        if let at = authority.lastIndex(of: UInt8(ascii: "@")) { authority.removeSubrange(...at) }
        if let colon = authority.lastIndex(of: UInt8(ascii: ":")),
           authority[authority.index(after: colon)...].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            authority.removeSubrange(colon...)
        }

        guard let host = canonicalHost(authority), !host.isEmpty else { return nil }
        let path = canonicalPath(pathBytes)

        return Canonical(
            host: escape(latin1Bytes(host)),
            path: escape(latin1Bytes(path)),
            query: queryBytes.map { escape($0) }
        )
    }

    /// Every host-suffix × path-prefix combination the spec says to look up.
    public static func expressions(for canonical: Canonical) -> [String] {
        var result: [String] = []
        for host in hostSuffixes(canonical.host) {
            for path in pathExpressions(path: canonical.path, query: canonical.query) {
                result.append(host + path)
            }
        }
        return result
    }

    public static func hashedExpressions(for url: URL) -> [(expression: String, hash: Data)] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let canonical = canonicalize(url.absoluteString) else { return [] }
        return expressions(for: canonical).map { ($0, Data(SHA256.hash(data: Data($0.utf8)))) }
    }

    // MARK: - Canonicalization pieces

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func stripScheme(_ bytes: [UInt8]) -> [UInt8] {
        // [A-Za-z][A-Za-z0-9+.-]*://
        guard let first = bytes.first, (first | 0x20) >= 0x61, (first | 0x20) <= 0x7A else { return bytes }
        var index = 1
        while index < bytes.count {
            let b = bytes[index]
            let isSchemeChar = ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2E || b == 0x2D
            if !isSchemeChar { break }
            index += 1
        }
        if bytes[index...].starts(with: Array("://".utf8)) {
            return Array(bytes[(index + 3)...])
        }
        return bytes
    }

    /// Decodes valid `%XX` sequences only; anything else (a stray `%`) is kept.
    private static func unescapeOnce(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo))
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }

    /// Re-escapes bytes <= 0x20, >= 0x7F, '#' and '%' (and nothing else).
    private static func escape(_ bytes: [UInt8]) -> String {
        var out = ""
        for byte in bytes {
            if byte <= 0x20 || byte >= 0x7F || byte == UInt8(ascii: "#") || byte == UInt8(ascii: "%") {
                out += String(format: "%%%02X", byte)
            } else {
                out.append(Character(UnicodeScalar(byte)))
            }
        }
        return out
    }

    private static func canonicalHost(_ authority: [UInt8]) -> String? {
        var host = authority.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 }
        while host.first == UInt8(ascii: ".") { host.removeFirst() }
        while host.last == UInt8(ascii: ".") { host.removeLast() }

        var collapsed: [UInt8] = []
        for byte in host {
            if byte == UInt8(ascii: "."), collapsed.last == UInt8(ascii: ".") { continue }
            collapsed.append(byte)
        }
        let text = latin1String(collapsed)
        return normalizedIPv4(text) ?? text
    }

    /// Spec: decimal, octal (leading 0) and hex (0x) IPv4 forms, with 1–4 parts,
    /// are rewritten as dotted decimal.
    static func normalizedIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }

        var values: [UInt64] = []
        for part in parts {
            let text = String(part)
            guard !text.isEmpty else { return nil }
            let value: UInt64?
            if text.hasPrefix("0x") || text.hasPrefix("0X") {
                value = UInt64(text.dropFirst(2), radix: 16)
            } else if text.count > 1, text.hasPrefix("0") {
                value = UInt64(text, radix: 8)
            } else {
                value = UInt64(text, radix: 10)
            }
            guard let value else { return nil }
            values.append(value)
        }

        for value in values.dropLast() where value > 255 { return nil }
        let remainingBytes = 5 - values.count
        guard let last = values.last, last < (UInt64(1) << (8 * UInt64(remainingBytes))) else { return nil }

        var address: UInt64 = 0
        for value in values.dropLast() { address = (address << 8) | value }
        address = (address << (8 * UInt64(remainingBytes))) | last
        return "\((address >> 24) & 0xFF).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }

    /// ISO-Latin-1 maps every byte to exactly one scalar, so arbitrary bytes
    /// (including invalid UTF-8) survive being held in a `String` and back.
    private static func latin1String(_ bytes: [UInt8]) -> String {
        String(bytes.map { Character(UnicodeScalar($0)) })
    }

    private static func latin1Bytes(_ string: String) -> [UInt8] {
        string.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    private static func canonicalPath(_ pathBytes: [UInt8]) -> String {
        let text = latin1String(pathBytes)
        guard !text.isEmpty else { return "/" }

        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        var output: [Substring] = []
        for component in components {
            if component.isEmpty || component == "." { continue }
            if component == ".." { if !output.isEmpty { output.removeLast() }; continue }
            output.append(component)
        }
        let lastComponent = components.last.map(String.init) ?? ""
        let wantsTrailingSlash = text.hasSuffix("/") || lastComponent == "." || lastComponent == ".."
        var result = "/" + output.joined(separator: "/")
        if wantsTrailingSlash && !output.isEmpty { result += "/" }
        return result
    }

    // MARK: - Expression generation

    private static func hostSuffixes(_ host: String) -> [String] {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        if isIPv4 { return [host] }
        let components = host.split(separator: ".").map(String.init)
        var result = [host]
        if components.count > 2 {
            let start = max(1, components.count - 5)
            for index in start..<(components.count - 1) {
                result.append(components[index...].joined(separator: "."))
            }
        }
        return result
    }

    private static func pathExpressions(path: String, query: String?) -> [String] {
        var result: [String] = []
        func add(_ value: String) { if !result.contains(value) { result.append(value) } }

        if let query { add(path + "?" + query) }
        add(path)
        add("/")

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let directories = path.hasSuffix("/") ? components : Array(components.dropLast())
        var prefix = "/"
        for directory in directories.prefix(3) {
            prefix += directory + "/"
            add(prefix)
        }
        return result
    }
}
