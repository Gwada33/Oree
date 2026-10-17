import AppKit
import BrowserCore

/// Le Markdown de Luciole en texte mis en forme pour le panneau. Les liens restent soulignés mais ne s'ouvrent pas ici (un clic enverrait vers
/// le navigateur par défaut) : « Ouvrir en page » les rend cliquables dans Orée. Les tableaux s'alignent en chasse fixe.
@MainActor
enum MarkdownRenderer {
    static func attributed(_ source: String, size: CGFloat = 13) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = Markdown.parse(source)
        for (index, block) in blocks.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            switch block {
            case .heading(let level, let text):
                let font = Theme.serifItalic(level == 1 ? size + 5 : level == 2 ? size + 3 : size + 1)
                out.append(inline(text, font: font, style: paragraph(before: index == 0 ? 0 : 8, after: 2)))
            case .paragraph(let text):
                out.append(inline(text, font: Theme.sans(size), style: paragraph(after: 4)))
            case .list(let items, let ordered):
                for (i, item) in items.enumerated() {
                    let marker = ordered ? "\(i + 1).\t" : "•\t"
                    let style = paragraph(after: 2, indent: 18, first: 0)
                    let line = NSMutableAttributedString(string: marker, attributes: [.font: Theme.sans(size), .foregroundColor: Theme.muted, .paragraphStyle: style])
                    line.append(inline(item, font: Theme.sans(size), style: style))
                    if i < items.count - 1 { line.append(NSAttributedString(string: "\n")) }
                    out.append(line)
                }
            case .quote(let text):
                out.append(inline(text, font: Theme.sans(size), color: Theme.muted, style: paragraph(after: 4, indent: 12, first: 12)))
            case .code(let code):
                out.append(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), .foregroundColor: Theme.text,
                                                                         .backgroundColor: Theme.field, .paragraphStyle: paragraph(before: 2, after: 4, lineHeight: 1.25)]))
            case .rule:
                out.append(NSAttributedString(string: "────────────", attributes: [.font: Theme.sans(size), .foregroundColor: Theme.muted, .paragraphStyle: paragraph(before: 4, after: 4)]))
            case .table(let header, let rows):
                out.append(NSAttributedString(string: aligned(header: header, rows: rows), attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular),
                                                                                                        .foregroundColor: Theme.text, .paragraphStyle: paragraph(before: 2, after: 4, lineHeight: 1.2)]))
            }
        }
        return out
    }

    private static func paragraph(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, first: CGFloat? = nil, lineHeight: CGFloat = 1.5) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight; style.paragraphSpacingBefore = before; style.paragraphSpacing = after
        style.headIndent = indent; style.firstLineHeadIndent = first ?? indent
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    private static func inline(_ text: String, font: NSFont, color: NSColor = Theme.text, style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in Markdown.spans(text) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let string: String
            switch span {
            case .text(let t):
                out.append(autolinked(t, attributes: attributes)); continue
            case .bold(let t): string = t; attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            case .italic(let t): string = t; attributes[.obliqueness] = 0.2          // la police de l'interface n'a pas d'italique : on incline
            case .code(let t): string = t; attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular); attributes[.backgroundColor] = Theme.field
            case .link(let t, let url): string = t; attributes[.link] = url; attributes[.foregroundColor] = Theme.accent; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        return out
    }

    /// Une adresse écrite en toutes lettres devient un lien court (le site et le début du chemin) qui s'ouvre dans Orée.
    private static func autolinked(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return NSAttributedString(string: text, attributes: attributes) }
        let out = NSMutableAttributedString()
        var cursor = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            out.append(NSAttributedString(string: String(text[cursor..<range.lowerBound]), attributes: attributes))
            let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
            var shown = host + (url.path.count > 1 ? url.path : "")
            if shown.count > 38 { shown = String(shown.prefix(37)) + "…" }
            var linkAttributes = attributes; linkAttributes[.link] = url; linkAttributes[.foregroundColor] = Theme.accent; linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            out.append(NSAttributedString(string: shown, attributes: linkAttributes))
            cursor = range.upperBound
        }
        out.append(NSAttributedString(string: String(text[cursor...]), attributes: attributes))
        return out
    }

    private static func aligned(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in all.map { c < $0.count ? Markdown.plainText($0[c]).count : 0 }.max() ?? 0 }
        func line(_ row: [String]) -> String {
            (0..<columns).map { c in let cell = c < row.count ? Markdown.plainText(row[c]) : ""; return cell + String(repeating: " ", count: widths[c] - cell.count) }.joined(separator: "  │  ")
        }
        return ([line(header), widths.map { String(repeating: "─", count: $0) }.joined(separator: "──┼──")] + rows.map(line)).joined(separator: "\n")
    }

    /// La réponse gagne à être lue en page : tableau, titre, code, ou longue liste.
    static func deservesAPage(_ source: String) -> Bool {
        Markdown.parse(source).contains { block in
            switch block {
            case .table, .code, .heading: return true
            case .list(let items, _): return items.count >= 4
            default: return false
            }
        } || source.count > 700
    }
}
