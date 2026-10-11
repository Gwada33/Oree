import WebKit
import BrowserCore

/// L'onglet de recherche caché : une WebView hors fenêtre, sans cookies ni historique (stockage non persistant), qui charge la page de
/// résultats de DuckDuckGo (version HTML, sans JavaScript) et en relève les cinq premiers résultats. La personne ne la voit jamais ;
/// le texte de la requête est la seule chose qui quitte le Mac, et seulement quand l'IA décide de chercher.
@MainActor
final class SearchTab: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var waiting: CheckedContinuation<Bool, Never>?
    private static let world = WKContentWorld.world(name: "oree-ai-search")

    static let extract = """
    const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
    const real = href => { try { const u = new URL(href, location.href); return u.searchParams.get('uddg') || u.href; } catch (e) { return href; } };
    return [...document.querySelectorAll('.result')].slice(0, 5).map(r => {
      const a = r.querySelector('.result__a');
      const s = r.querySelector('.result__snippet');
      return a ? { title: clean(a.textContent), url: real(a.getAttribute('href')), snippet: clean(s && s.textContent).slice(0, 220) } : null;
    }).filter(Boolean);
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    private func finish(_ ok: Bool) { waiting?.resume(returning: ok); waiting = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

    /// Formate des résultats pour le modèle : « 1. Titre / adresse / extrait ».
    static func format(_ results: [[String: Any]]) -> (text: String, sources: [String]) {
        var lines: [String] = [], sources: [String] = []
        for (i, r) in results.enumerated() {
            let url = r["url"] as? String ?? ""
            lines.append("\(i + 1). \(r["title"] as? String ?? "")\n   \(url)\n   \(r["snippet"] as? String ?? "")")
            if i < 3, !url.isEmpty { sources.append(url) }
        }
        return (lines.joined(separator: "\n"), sources)
    }

    func search(_ query: String) async -> AgentToolResult {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return AgentToolResult(ok: false, text: "Requête invalide.") }
        let loaded: Bool = await withCheckedContinuation { continuation in
            waiting = continuation
            web.load(URLRequest(url: url, timeoutInterval: 12))
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(14)); self?.finish(false) }
        }
        guard loaded, let raw = await web.callJSON(Self.extract, world: Self.world, seconds: 6) as? [[String: Any]], !raw.isEmpty else {
            return AgentToolResult(ok: false, text: "La recherche n'a rien renvoyé (pas de réseau, ou le moteur a refusé).", summary: "Recherche sans résultat")
        }
        let formatted = Self.format(raw)
        return AgentToolResult(ok: true, text: formatted.text, summary: "Recherche : \(query) (\(raw.count) résultats)", sources: formatted.sources)
    }
}
