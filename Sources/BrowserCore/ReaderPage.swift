import Foundation

/// The article the reader mode shows, as extracted from a page by `ReaderScript` (the content is already rebuilt from a short list of safe tags).
public struct ReaderArticle: Equatable, Sendable {
    public var title: String
    public var byline: String
    public var site: String
    public var contentHTML: String
    public var textLength: Int
    public var originalURL: String

    public init(title: String, byline: String, site: String, contentHTML: String, textLength: Int, originalURL: String) {
        self.title = title; self.byline = byline; self.site = site; self.contentHTML = contentHTML; self.textLength = textLength; self.originalURL = originalURL
    }

    /// Decodes the script's answer; nil if it is not one.
    public static func parse(_ json: String, originalURL: String) -> ReaderArticle? {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let html = object["html"] as? String else { return nil }
        return ReaderArticle(title: (object["title"] as? String) ?? "", byline: (object["byline"] as? String) ?? "", site: (object["site"] as? String) ?? "",
                             contentHTML: html, textLength: (object["length"] as? NSNumber)?.intValue ?? 0, originalURL: originalURL)
    }

    /// Short pages (menus, login forms, search results) are not articles: below this, the reader mode says so instead of showing a page of crumbs.
    public static let minimumTextLength = 600
    public var isReadable: Bool { textLength >= Self.minimumTextLength }

    /// Reading time at 220 words a minute (≈ 6 characters a word with the space).
    public var minutes: Int { max(1, Int((Double(textLength) / 6.0 / 220.0).rounded())) }
}

public enum ReaderPage {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The reader's page. A strict Content-Security-Policy forbids every script and every connection but images: the extracted content is
    /// already built from safe tags, and this is the second lock.
    public static func html(_ article: ReaderArticle) -> String {
        let meta = [article.site, article.byline.isEmpty ? nil : article.byline, "\(article.minutes) min de lecture"].compactMap { $0 }.filter { !$0.isEmpty }
        let source = URL(string: article.originalURL).flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0.absoluteString : nil }
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">
        <meta name="oree-reader" content="1"><title>\(escape(article.title.isEmpty ? article.site : article.title))</title>
        <style>
        :root{color-scheme:light dark;--paper:#FBFAF7;--ink:#1D1C1A;--muted:#6B665E;--line:rgba(29,28,26,.14);--link:#2F7354}
        @media (prefers-color-scheme:dark){:root{--paper:#1E1D1B;--ink:#EEEAE3;--muted:#A8A299;--line:rgba(238,234,227,.14);--link:#7FCBA2}}
        html{background:var(--paper)}body{margin:0;color:var(--ink);font:20px/1.7 "Iowan Old Style","Charter",Georgia,serif;-webkit-font-smoothing:antialiased}
        main{max-width:680px;margin:0 auto;padding:72px 24px 120px}
        h1.title{font:italic 400 clamp(34px,5vw,48px)/1.12 "Iowan Old Style","Charter",Georgia,serif;margin:0 0 14px;letter-spacing:-.01em}
        .meta{font:14px/1.4 -apple-system,system-ui,sans-serif;color:var(--muted);margin:0 0 40px;padding-bottom:20px;border-bottom:1px solid var(--line)}
        .meta a{color:inherit}
        p{margin:0 0 1.1em}h2,h3,h4{font-family:-apple-system,system-ui,sans-serif;line-height:1.25;margin:1.8em 0 .5em}h2{font-size:1.4em}h3{font-size:1.15em}h4{font-size:1em}
        a{color:var(--link)}img{max-width:100%;height:auto;border-radius:6px;display:block;margin:1.4em auto}figure{margin:1.6em 0}figcaption{font:13px/1.4 -apple-system,sans-serif;color:var(--muted);text-align:center}
        blockquote{margin:1.4em 0;padding-left:1.1em;border-left:3px solid var(--line);color:var(--muted)}
        pre{overflow:auto;padding:14px 16px;border-radius:8px;background:rgba(128,128,128,.12);font:14px/1.5 ui-monospace,Menlo,monospace}code{font:.9em ui-monospace,Menlo,monospace}
        table{border-collapse:collapse;font:15px/1.4 -apple-system,sans-serif;margin:1.4em 0}td,th{border:1px solid var(--line);padding:6px 10px}
        hr{border:0;border-top:1px solid var(--line);margin:2em 0}
        </style></head><body><main>
        <h1 class="title">\(escape(article.title))</h1>
        <p class="meta">\(escape(meta.joined(separator: " · ")))\(source.map { " · <a href=\"\(escape($0))\">Page d’origine</a>" } ?? "")</p>
        \(article.contentHTML)
        </main></body></html>
        """
    }

    /// The page shown when there is nothing to read.
    public static func notReadableMessage() -> String { "Cette page ne contient pas d’article à lire." }
}
