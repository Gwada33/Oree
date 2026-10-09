import Foundation
import WebKit
import BrowserCore
import BrowserStorage

/// What the home page needs to draw itself.
struct HomeInput {
    struct SpaceChip { let index: Int; let name: String; let hue: OreeTokens.Hue; let icon: SpaceIcon; let tabCount: Int }
    var hue: OreeTokens.Hue
    var favorites: [Bookmark]
    var recent: [HistoryEntry]
    var spaces: [SpaceChip]
    var now = Date()
}

/// The « Orée » new-tab page: serif italic date, big search field, favorites as a numbered
/// table of contents (⌥1–⌥8), "Reprendre" and "Espaces" on the right. One HTML document built
/// from the design tokens; fonts and the optional photo come from the app via the `oree://` scheme
/// (no network). Light/dark follows the window through `prefers-color-scheme`.
enum StartPage {
    /// Base URL of the page: makes `oree://home/fonts/...` same-origin for the HTML.
    static let baseURL = URL(string: "oree://home/")!
    /// Links with this scheme are handled by the app (never loaded).
    static let actionScheme = "oree-action"

    static func render(_ input: HomeInput) -> String {
        let settings = SettingsStore.shared
        let engine = settings.searchEngine
        let engineName = engine == .google ? "Google" : "DuckDuckGo"
        let (weekday, dayMonth) = HomeFormatting.frenchDate(input.now)
        let background = settings.homeBackground

        let favorites = settings.homeShowsFavorites ? favoritesHTML(input.favorites) : ""
        let recent = settings.startPageShowsRecent ? recentHTML(input.recent, now: input.now) : ""
        let spaces = settings.homeShowsSpaces ? spacesHTML(input.spaces) : ""
        let calm = settings.calmMotion ? " calm" : ""

        return """
        <!DOCTYPE html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>Nouvel onglet</title>
        <link rel="icon" href="data:image/svg+xml,\(markFavicon)">
        <style>\(css(hue: input.hue))</style>
        </head>
        <body class="bg-\(background.rawValue)\(calm)">
          <main class="home">
            <div class="col">
              <header>
                <span class="wd">\(escape(weekday))</span>
                <h1>\(escape(dayMonth))</h1>
              </header>
              <form id="f" action="\(escape(engine.queryURL))" method="GET" class="search">
                <svg class="ic" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
                <input id="q" type="text" name="q" placeholder="Rechercher ou saisir une adresse" autocomplete="off" aria-label="Rechercher ou saisir une adresse">
                <span class="chip">\(engineName)</span>
              </form>
              \(favorites)
            </div>
            <div class="col side">
              \(recent)
              \(spaces)
            </div>
          </main>
          <a class="custom" href="\(actionScheme)://customize">Personnaliser la page</a>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    // MARK: Sections

    private static func favoritesHTML(_ favorites: [Bookmark]) -> String {
        guard !favorites.isEmpty else { return "" }
        let items = favorites.prefix(8).enumerated().map { index, bookmark -> String in
            let host = HomeFormatting.displayHost(bookmark.url)
            let title = bookmark.title.isEmpty || bookmark.title == bookmark.url ? host : bookmark.title
            let letter = host.first.map { String($0).uppercased() } ?? "?"
            return """
            <li><a class="fav-row \(hueClass(host))" href="\(escape(bookmark.url))">
              <span class="n">\(String(format: "%02d", index + 1))</span>
              <span class="tile">\(escape(letter))</span>
              <span class="meta"><b>\(escape(title))</b><i>\(escape(host))</i></span>
              <span class="kbd">⌥\(index + 1)</span>
            </a></li>
            """
        }.joined()
        return "<section aria-label=\"Favoris\"><div class=\"sh\"><h2>Favoris</h2></div><ol class=\"favs\">\(items)</ol></section>"
    }

    private static func recentHTML(_ recent: [HistoryEntry], now: Date) -> String {
        guard !recent.isEmpty else { return "" }
        let rows = recent.prefix(4).map { entry -> String in
            let host = HomeFormatting.displayHost(entry.url)
            let title = entry.title.isEmpty ? host : entry.title
            return """
            <a class="resume \(hueClass(host))" href="\(escape(entry.url))"><span class="dot"></span>
              <span class="meta"><b>\(escape(title))</b><i>\(escape(host)) · \(HomeFormatting.relative(entry.lastVisitedAt, now: now))</i></span></a>
            """
        }.joined()
        return "<section aria-label=\"Reprendre\"><h2>Reprendre</h2>\(rows)</section>"
    }

    private static func spacesHTML(_ spaces: [HomeInput.SpaceChip]) -> String {
        guard !spaces.isEmpty else { return "" }
        let chips = spaces.map { space in
            """
            <a class="space h-\(space.hue.rawValue)" href="\(actionScheme)://space/\(space.index)">\(icon(space.icon))\(escape(space.name))<span class="count">\(space.tabCount)</span></a>
            """
        }.joined()
        return "<section aria-label=\"Espaces\"><h2>Espaces</h2><div class=\"chips\">\(chips)</div></section>"
    }

    private static func hueClass(_ host: String) -> String { "h-\(HomeFormatting.hue(forHost: host).rawValue)" }

    /// The 4-bar Orée mark as an SVG favicon (URL-encoded for a data: URI).
    private static let markFavicon = "%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='6 6 52 52'%3E%3Cdefs%3E%3ClinearGradient id='g' gradientUnits='userSpaceOnUse' x1='8' y1='0' x2='56' y2='0'%3E%3Cstop offset='0' stop-color='%232F7354'/%3E%3Cstop offset='1' stop-color='%23D9A441'/%3E%3C/linearGradient%3E%3CclipPath id='c'%3E%3Ccircle cx='32' cy='32' r='24'/%3E%3C/clipPath%3E%3C/defs%3E%3Cpath d='M8 7H21V57H8ZM25.93 7H33.47V57H25.93ZM40.11 7H44.49V57H40.11ZM53.46 7H56V57H53.46Z' fill='url(%23g)' clip-path='url(%23c)'/%3E%3C/svg%3E"

    /// 24-grid stroke icons for the space chips.
    private static func icon(_ icon: SpaceIcon) -> String {
        let path: String
        switch icon {
        case .leaf: path = "M5 19c0-9 5-14 14-14 0 9-5 14-14 14zM5 19l7-7"
        case .code: path = "m8 8-5 4 5 4M16 8l5 4-5 4M14 5l-4 14"
        case .plane: path = "M3 13l18-8-6 16-3-7-9-1z"
        case .book: path = "M5 4h10a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3zM5 17a3 3 0 0 1 3-3h10"
        case .home: path = "M4 11l8-7 8 7v9h-5v-6H9v6H4z"
        case .briefcase: path = "M4 8h16v11H4zM9 8V5h6v3M4 13h16"
        case .heart: path = "M12 20S4 15 4 9a4 4 0 0 1 8-1 4 4 0 0 1 8 1c0 6-8 11-8 11z"
        case .star: path = "m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z"
        }
        return "<svg class=\"ic s\" viewBox=\"0 0 24 24\"><path d=\"\(path)\"/></svg>"
    }

    // MARK: CSS from tokens

    private static func rgba(_ c: RGBA) -> String {
        let r = Int((c.r * 255).rounded()), g = Int((c.g * 255).rounded()), b = Int((c.b * 255).rounded())
        return c.a >= 1 ? String(format: "#%02X%02X%02X", r, g, b) : "rgba(\(r),\(g),\(b),\(String(format: "%.3f", c.a)))"
    }

    private static func vars(dark: Bool, hue: OreeTokens.Hue) -> String {
        let T = OreeTokens.self
        let entries: [(String, RGBA)] = [
            ("chrome", T.chrome.resolved(dark: dark)), ("page", T.page.resolved(dark: dark)),
            ("raised", T.raised.resolved(dark: dark)), ("field", T.field.resolved(dark: dark)),
            ("text", T.text.resolved(dark: dark)), ("muted", T.muted.resolved(dark: dark)),
            ("line", T.line.resolved(dark: dark)), ("hover", T.hover.resolved(dark: dark)),
            ("h", hue.solid.resolved(dark: dark)), ("h-soft", hue.soft().resolved(dark: dark)),
            ("h-ink", hue.ink.resolved(dark: dark)),
        ]
        return entries.map { "--\($0.0):\(rgba($0.1));" }.joined()
    }

    private static func hueRules() -> String {
        OreeTokens.Hue.allCases.map { hue in
            func rule(_ dark: Bool) -> String {
                ".h-\(hue.rawValue){--h:\(rgba(hue.solid.resolved(dark: dark)));--h-soft:\(rgba(hue.soft().resolved(dark: dark)));--h-ink:\(rgba(hue.ink.resolved(dark: dark)));--on:\(rgba(hue.onSolid.resolved(dark: dark)));}"
            }
            return rule(false) + "@media (prefers-color-scheme: dark){" + rule(true) + "}"
        }.joined()
    }

    private static func css(hue: OreeTokens.Hue) -> String {
        let radius = OreeTokens.radii(base: SettingsStore.shared.cornerRadius)
        let fontFace = """
        @font-face{font-family:"Instrument Sans";src:url("oree://home/fonts/InstrumentSans.ttf") format("truetype");font-weight:400 700;}
        @font-face{font-family:"Instrument Serif";font-style:italic;src:url("oree://home/fonts/InstrumentSerif-Italic.ttf") format("truetype");}
        """
        return """
        \(fontFace)
        :root{\(vars(dark: false, hue: hue))--sans:"Instrument Sans",-apple-system,"SF Pro Text",sans-serif;--serif:"Instrument Serif",Georgia,serif;--r:\(Int(radius.base))px;--r-sm:\(Int(radius.sm))px;--r-lg:\(Int(radius.lg))px;--s2:0 2px 8px -2px rgba(0,0,0,.14),0 1px 2px rgba(0,0,0,.06);}
        @media (prefers-color-scheme: dark){:root{\(vars(dark: true, hue: hue))--s2:0 2px 10px -2px rgba(0,0,0,.5),0 1px 2px rgba(0,0,0,.3);}}
        \(hueRules())
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;background:var(--page);color:var(--text);font:400 13px/1.4 var(--sans);position:relative}
        .bg-papier{background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 .5 0 0 0 0 .45 0 0 0 0 .4 0 0 0 .09 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")}
        .bg-horizon{background:linear-gradient(180deg,var(--page) 0%,var(--page) 45%,var(--h-soft) 100%) fixed}
        .bg-photo{background:#222 url("oree://home/photo") center/cover fixed}
        .bg-photo section,.bg-photo header,.bg-photo .search{background:color-mix(in srgb,var(--page) 78%,transparent);backdrop-filter:blur(14px);border-radius:var(--r-lg);padding:12px}
        .home{max-width:1120px;margin:0 auto;padding:56px clamp(20px,5vw,72px) 72px;display:grid;grid-template-columns:1.45fr .85fr;gap:40px 64px;align-items:start}
        .col{display:flex;flex-direction:column;gap:32px;min-width:0}
        .side{padding-top:18px;gap:28px}
        header{display:flex;flex-direction:column;gap:6px}
        .wd{font-size:13px;font-weight:600;color:var(--muted);text-transform:capitalize}
        h1{margin:0;font:italic 400 clamp(48px,6.4vw,84px)/.92 var(--serif);letter-spacing:-.015em}
        h2{margin:0;font-size:13px;font-weight:600;color:var(--muted)}
        .search{display:flex;align-items:center;gap:12px;height:54px;padding:0 12px 0 18px;border-radius:var(--r-lg);background:var(--raised);box-shadow:var(--s2);transition:box-shadow .18s cubic-bezier(.2,.8,.2,1)}
        .search:focus-within{box-shadow:0 0 0 2px var(--h),var(--s2)}
        .search .ic{width:20px;height:20px;stroke:var(--h);fill:none;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round;flex:none}
        .search input{flex:1;min-width:0;border:0;outline:0;background:transparent;color:var(--text);font:inherit;font-size:15px}
        .search input::placeholder{color:var(--muted)}
        .chip{font-size:12px;font-weight:500;padding:5px 9px;border-radius:999px;background:var(--hover);color:var(--muted)}
        section{display:flex;flex-direction:column;gap:6px}
        .sh{padding:0 6px}
        .favs{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:1fr 1fr;column-gap:28px}
        .favs li{border-top:1px solid var(--line)}
        .fav-row{display:grid;grid-template-columns:28px 36px 1fr auto;gap:10px;align-items:center;padding:9px 6px;border-radius:var(--r-sm);text-decoration:none;color:inherit;transition:background .12s cubic-bezier(.2,.8,.2,1)}
        .fav-row:hover{background:var(--hover)}
        .n{font:italic 400 20px var(--serif);color:var(--muted);text-align:right}
        .tile{width:36px;height:36px;border-radius:var(--r-sm);background:var(--h);color:var(--on);display:grid;place-items:center;font-weight:600;font-size:15px}
        .meta{display:flex;flex-direction:column;gap:1px;min-width:0}
        .meta b{font-weight:600;font-size:14.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .meta i{font-style:normal;font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .kbd{font-size:11px;font-weight:500;color:var(--muted);background:var(--hover);padding:2px 6px;border-radius:5px;opacity:0;transition:opacity .12s cubic-bezier(.2,.8,.2,1)}
        .fav-row:hover .kbd{opacity:1}
        .resume{display:flex;gap:12px;align-items:flex-start;padding:10px 8px;border-radius:var(--r-sm);text-decoration:none;color:inherit}
        .resume:hover{background:var(--hover)}
        .resume .meta b{line-height:1.3;white-space:normal}
        .dot{width:8px;height:8px;border-radius:50%;background:var(--h);margin-top:6px;flex:none}
        .chips{display:flex;flex-wrap:wrap;gap:8px}
        .space{display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 12px 0 10px;border-radius:999px;background:var(--h-soft);color:var(--h-ink);text-decoration:none;font-weight:600}
        .space .ic{width:15px;height:15px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
        .space .count{opacity:.7;font-weight:500}
        .custom{position:fixed;left:20px;bottom:16px;height:30px;padding:0 12px;border-radius:var(--r-sm);background:var(--raised);box-shadow:var(--s2);color:var(--text);font-size:12px;font-weight:500;display:inline-flex;align-items:center;text-decoration:none}
        a:focus-visible{outline:2px solid var(--h);outline-offset:2px}
        body.anim .home>.col{animation:up .26s cubic-bezier(.2,.8,.2,1) both}body.anim .home>.col+.col{animation-delay:.04s}
        @keyframes up{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
        @media (max-width:900px){.home{grid-template-columns:1fr}.side{padding-top:0}}
        @media (max-width:640px){.favs{grid-template-columns:1fr}}
        @media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
        body.calm *{transition:none!important;animation:none!important}
        """
    }

    private static let script = """
    // Entry animation only if the page is actually on screen (a hidden page would freeze at its first frame).
    if(document.visibilityState==='visible'&&!document.body.classList.contains('calm'))document.body.classList.add('anim');
    document.addEventListener('keydown',function(e){
      if(e.altKey&&/^Digit[1-8]$/.test(e.code)){
        var a=document.querySelectorAll('.fav-row')[Number(e.code.slice(5))-1];
        if(a){e.preventDefault();location.href=a.href;}
      }
    });
    document.getElementById('f').addEventListener('submit',function(e){
      var v=document.getElementById('q').value.trim();
      if(/^https?:\\/\\//i.test(v)||/^[^\\s\\/]+\\.[a-z]{2,}(\\/\\S*)?$/i.test(v)){
        e.preventDefault();location.href=/^https?:/i.test(v)?v:'https://'+v;
      }
    });
    """

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Serves the app's own fonts and the optional home photo to the new-tab page
/// (`oree://home/fonts/<file>.ttf`, `oree://home/photo`). Nothing else is reachable.
final class OreeSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let (data, mime) = resolve(url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "max-age=86400"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func resolve(_ url: URL) -> (Data, String)? {
        let components = url.pathComponents.filter { $0 != "/" }
        if components.first == "fonts", components.count == 2 {
            let name = (components[1] as NSString).lastPathComponent   // no path tricks
            guard name.hasSuffix(".ttf"),
                  let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return (data, "font/ttf")
        }
        if components == ["photo"] {
            let path = SettingsStore.shared.homePhotoPath
            let ext = (path as NSString).pathExtension.lowercased()
            let mimes = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "heic": "image/heic", "webp": "image/webp"]
            guard !path.isEmpty, let mime = mimes[ext], let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return (data, mime)
        }
        return nil
    }
}
