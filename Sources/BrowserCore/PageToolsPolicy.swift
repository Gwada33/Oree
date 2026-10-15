import Foundation

/// Pure helpers behind the page commands (print, PDF, view source), kept out of the UI so they can be tested.
public enum PageToolsPolicy {
    /// "Titre de la page.pdf": the title with the characters a file name cannot hold removed, the host if there is no title.
    public static func pdfFileName(title: String?, host: String?) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        func clean(_ text: String?) -> String {
            (text ?? "").components(separatedBy: forbidden).joined(separator: " ")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        var name = clean(title)
        if name.isEmpty { name = clean(host) }
        if name.isEmpty { name = "Page" }
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return name + ".pdf"
    }

    /// Escapes text for HTML so a page's source is shown, not run.
    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The HTML page that shows `html` as text with line numbers, under a title naming `address`.
    public static func sourcePage(html: String, address: String) -> String {
        let lines = html.components(separatedBy: "\n")
        let numbered = lines.enumerated().map { index, line in
            "<span class=n>\(index + 1)</span>\(escapeHTML(line))"
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Source : \(escapeHTML(address))</title>
        <meta name="color-scheme" content="light dark">
        <style>body{margin:0;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}header{padding:10px 16px;font:600 13px -apple-system,sans-serif;border-bottom:1px solid rgba(128,128,128,.3);position:sticky;top:0;background:Canvas}
        pre{margin:0;padding:12px 0;overflow:auto;white-space:pre}.n{display:inline-block;width:52px;padding-right:14px;text-align:right;opacity:.45;user-select:none}</style></head>
        <body><header>Source de \(escapeHTML(address)) <span style="font-weight:400;opacity:.6">· document tel que la page l’a maintenant</span></header><pre>\(numbered)</pre></body></html>
        """
    }

    /// The slices to ask for when cutting a tall page into PDF pages: `[(origin, height)]` from the top, at most `maxSlices` (a page of
    /// 100 000 points is cut short rather than filling the disk). An empty or invalid page gives one slice, so the caller still has a PDF.
    public static func pdfSlices(contentHeight: Double, sliceHeight: Double, maxSlices: Int) -> [(origin: Double, height: Double)] {
        guard contentHeight.isFinite, contentHeight > 0, sliceHeight > 0, maxSlices > 0 else { return [(0, max(sliceHeight, 1))] }
        var slices: [(origin: Double, height: Double)] = []
        var origin = 0.0
        while origin < contentHeight, slices.count < maxSlices {
            slices.append((origin, min(sliceHeight, contentHeight - origin)))
            origin += sliceHeight
        }
        return slices
    }
}
