import Foundation

/// Imports the CSV that Apple's Passwords app (File > Export All Passwords),
/// Chrome, Firefox and most password managers can produce.
///
/// Recognised columns (case-insensitive): `URL`/`Login URL`, `Username`/`Login`,
/// `Password`. Everything else (title, notes, one-time-code seed) is ignored.
public enum PasswordCSVImporter {
    public struct Entry: Equatable, Sendable {
        public let origin: String
        public let username: String
        public let password: String
    }

    public struct Result: Equatable, Sendable {
        public let entries: [Entry]
        /// Rows skipped: no usable URL, empty password, or an insecure http:// site.
        public let skipped: Int
    }

    public enum ImportError: Error, Equatable {
        case missingColumns
    }

    public static func parse(_ csv: String) throws -> Result {
        let rows = parseRows(csv)
        guard let header = rows.first else { throw ImportError.missingColumns }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ candidates: [String]) -> Int? { names.firstIndex { candidates.contains($0) } }
        guard let urlColumn = column(["url", "login url", "login_uri", "website", "web site"]),
              let userColumn = column(["username", "login", "login_username", "user name"]),
              let passwordColumn = column(["password", "login_password"]) else {
            throw ImportError.missingColumns
        }

        var entries: [Entry] = []
        var skipped = 0
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            guard row.indices.contains(urlColumn), row.indices.contains(passwordColumn),
                  let origin = secureOrigin(row[urlColumn]), !row[passwordColumn].isEmpty else { skipped += 1; continue }
            let username = row.indices.contains(userColumn) ? row[userColumn] : ""
            entries.append(Entry(origin: origin, username: username, password: row[passwordColumn]))
        }
        return Result(entries: entries, skipped: skipped)
    }

    /// `https://host[:port]`, or http only for local dev servers — the same rule autofill uses.
    static func secureOrigin(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "https://\(text)" }
        guard let url = URL(string: text), let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// RFC 4180: quoted fields may contain commas, quotes ("") and newlines.
    static func parseRows(_ input: String) -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); rows.append(row); row = []; field = ""
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { break }   // handled by the \n
                    row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

extension CredentialVault {
    /// Saves every entry (updating duplicates). Returns how many were stored.
    @discardableResult
    public func importEntries(_ entries: [PasswordCSVImporter.Entry]) throws -> Int {
        for entry in entries {
            try save(origin: entry.origin, username: entry.username, password: entry.password)
        }
        return entries.count
    }
}
