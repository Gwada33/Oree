import Foundation

/// Un sous-ensemble de Markdown, celui que Luciole écrit : titres, paragraphes, listes (à puces ou numérotées), citations, blocs de code, tableaux, filet.
/// Le texte reste du texte : rien n'est jamais interprété comme du HTML (tout est échappé), les liens ne sont que http(s).
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [String], ordered: Bool)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum Markdown {
    // MARK: Blocs

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {                                            // bloc de code, jusqu'à la clôture (ou la fin si le modèle l'oublie)
                flush(); var code: [String] = []; i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                blocks.append(.code(code.joined(separator: "\n"))); i += 1; continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let heading = headingLevel(trimmed) { flush(); blocks.append(.heading(level: heading.level, text: heading.text)); i += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                flush(); var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(quote.joined(separator: " "))); continue
            }
            if listItem(trimmed) != nil {
                flush(); var items: [String] = []; let ordered = listItem(trimmed)!.ordered
                while i < lines.count, let item = listItem(lines[i].trimmingCharacters(in: .whitespaces)), item.ordered == ordered { items.append(item.text); i += 1 }
                blocks.append(.list(items: items, ordered: ordered)); continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush(); let header = cells(trimmed); var rows: [[String]] = []; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                blocks.append(.table(header: header, rows: rows)); continue
            }
            paragraph.append(trimmed); i += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...4).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3 && (Set(stripped) == ["-"] || Set(stripped) == ["*"] || Set(stripped) == ["_"])
    }

    private static func listItem(_ line: String) -> (text: String, ordered: Bool)? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " ", !isRule(line) { return (line.dropFirst(2).trimmingCharacters(in: .whitespaces), false) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") ") {
            return (line.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces), true)
        }
        return nil
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { cell in !cell.isEmpty && cell.contains("-") && cell.allSatisfy { "-: ".contains($0) } }
    }

    // MARK: Inline

    public enum Span: Equatable, Sendable {
        case text(String), bold(String), italic(String), code(String), link(text: String, url: URL)
    }

    /// `**gras**`, `*italique*` / `_italique_`, `` `code` ``, `[texte](https://…)`. Ce qui n'est pas refermé reste du texte.
    public static func spans(_ text: String) -> [Span] {
        var result: [Span] = [], plain = ""
        let chars = Array(text)
        var i = 0
        func flush() { if !plain.isEmpty { result.append(.text(plain)); plain = "" } }
        func find(_ marker: [Character], from: Int) -> Int? {
            var j = from
            while j + marker.count <= chars.count { if Array(chars[j..<j + marker.count]) == marker { return j }; j += 1 }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "`", let end = find(["`"], from: i + 1), end > i + 1 { flush(); result.append(.code(String(chars[i + 1..<end]))); i = end + 1; continue }
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*", let end = find(["*", "*"], from: i + 2), end > i + 2 { flush(); result.append(.bold(String(chars[i + 2..<end]))); i = end + 2; continue }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != c,
               (c == "*" || i == 0 || !chars[i - 1].isLetter), let end = find([c], from: i + 1), end > i + 1, chars[end - 1] != " " {
                flush(); result.append(.italic(String(chars[i + 1..<end]))); i = end + 1; continue
            }
            if c == "[", let close = find(["]"], from: i + 1), close + 1 < chars.count, chars[close + 1] == "(", let end = find([")"], from: close + 2),
               let url = URL(string: String(chars[close + 2..<end])), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                flush(); result.append(.link(text: String(chars[i + 1..<close]), url: url)); i = end + 1; continue
            }
            plain.append(c); i += 1
        }
        flush()
        return result
    }

    /// Le texte sans marques, pour une lecture à voix haute ou une copie « propre ».
    public static func plainText(_ text: String) -> String {
        spans(text).map { span -> String in
            switch span { case .text(let t), .bold(let t), .italic(let t), .code(let t): return t; case .link(let t, _): return t }
        }.joined()
    }

    // MARK: HTML (page de réponse)

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inlineHTML(_ text: String) -> String {
        spans(text).map { span -> String in
            switch span {
            case .text(let t): return escape(t)
            case .bold(let t): return "<strong>\(escape(t))</strong>"
            case .italic(let t): return "<em>\(escape(t))</em>"
            case .code(let t): return "<code>\(escape(t))</code>"
            case .link(let t, let url): return "<a href=\"\(escape(url.absoluteString))\" rel=\"noopener noreferrer\">\(escape(t))</a>"
            }
        }.joined()
    }

    public static func bodyHTML(_ source: String) -> String {
        parse(source).map { block -> String in
            switch block {
            case .heading(let level, let text): return "<h\(level + 1)>\(inlineHTML(text))</h\(level + 1)>"
            case .paragraph(let text): return "<p>\(inlineHTML(text))</p>"
            case .list(let items, let ordered): return "<\(ordered ? "ol" : "ul")>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</\(ordered ? "ol" : "ul")>"
            case .quote(let text): return "<blockquote>\(inlineHTML(text))</blockquote>"
            case .code(let code): return "<pre><code>\(escape(code))</code></pre>"
            case .rule: return "<hr>"
            case .table(let header, let rows):
                return "<table><thead><tr>" + header.map { "<th>\(inlineHTML($0))</th>" }.joined() + "</tr></thead><tbody>"
                    + rows.map { row in "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
            }
        }.joined(separator: "\n")
    }

    /// Une page complète, claire ou sombre selon le système, sans script, qui ne charge rien (la politique de contenu l'interdit).
    public static func page(title: String, source: String) -> String {
        """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark;--bg:#FBFAF7;--fg:#1D1C1A;--muted:#5E5A53;--line:rgba(29,28,26,.12);--field:#E2DDD5;--accent:#2F7354}
        @media (prefers-color-scheme:dark){:root{--bg:#1E1D1B;--fg:#EEEAE3;--muted:#A8A299;--line:rgba(238,234,227,.11);--field:#272622;--accent:#7FCBA2}}
        body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 -apple-system,"Instrument Sans",sans-serif}
        main{max-width:44rem;margin:0 auto;padding:3rem 1.5rem 5rem}
        h1,h2,h3,h4,h5{font-family:"Instrument Serif",Georgia,serif;font-style:italic;font-weight:400;line-height:1.2;margin:2rem 0 .6rem}
        h2{font-size:2rem}h3{font-size:1.5rem}h4{font-size:1.25rem}
        a{color:var(--accent)}code{background:var(--field);padding:.1em .35em;border-radius:6px;font-size:.92em}
        pre{background:var(--field);padding:1rem;border-radius:10px;overflow:auto}pre code{background:none;padding:0}
        blockquote{margin:1rem 0;padding-left:1rem;border-left:3px solid var(--accent);color:var(--muted)}
        table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border-bottom:1px solid var(--line);padding:.55rem .7rem;text-align:left}th{color:var(--muted);font-weight:600}
        hr{border:0;border-top:1px solid var(--line);margin:2rem 0}
        </style></head><body><main>\(bodyHTML(source))</main></body></html>
        """
    }
}
