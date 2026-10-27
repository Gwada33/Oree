import WebKit
import BrowserCore

/// Survol d'un lien → préconnexion. La page n'envoie que l'adresse du lien survolé, après le délai propre à son genre (nav / contenu / bouton) ; l'app revérifie tout (`HoverPreconnect`).
/// Jamais dans un onglet privé. Monde de contenu à part.
@MainActor
enum HoverPreconnectScript {
    static let world = WKContentWorld.world(name: "oree-preconnect")
    static let handlerName = "oreePreconnect"

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static var source: String { template.replacingOccurrences(of: "__DELAYS__", with: "{" + ["nav", "other", "button", "content"].map { "\($0): \(HoverPreconnect.delay(kind: $0))" }.joined(separator: ",") + "}") }

    private static let template = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__oreePreconnect) return;
      window.__oreePreconnect = true;
      const delays = __DELAYS__;
      const kindOf = a => a.closest('nav,header,footer,aside,[role=navigation]') ? 'nav' : (a.closest('article,main,p,li,[role=main]') ? 'content' : ((a.getAttribute('role') === 'button' || a.className && /btn|button/i.test(a.className)) ? 'button' : 'other'));
      let timer = 0, cur = null;
      const stop = () => { if (timer) clearTimeout(timer); timer = 0; cur = null; };
      addEventListener('mouseover', e => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) { stop(); return; }
        if (a === cur) return;
        stop(); cur = a;
        timer = setTimeout(() => { try { const u = new URL(a.href, location.href); if (/^https?:$/.test(u.protocol)) webkit.messageHandlers.oreePreconnect.postMessage(u.href); } catch (_) {} timer = 0; }, delays[kindOf(a)] || 350);
      }, { passive: true, capture: true });
      addEventListener('mouseout', e => { if (cur && !(e.relatedTarget && cur.contains(e.relatedTarget))) stop(); }, { passive: true, capture: true });
    })();
    """#
}

final class HoverPreconnectHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let href = message.body as? String, href.count < 2048, let url = URL(string: href) else { return }
        mainActorNow {
            guard let tab = Tab.tabsByWebView.object(forKey: message.webView), let pool = message.webView?.configuration.processPool,
                  HoverPreconnect.allows(url, isPrivate: tab.isPrivate, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled),
                  Self.recent.shouldConnect(host: url.host ?? "") else { return }
            WebKitTuning.preconnect(to: url, using: pool)
        }
    }
    @MainActor private static var recent = HoverPreconnect.Recent()
}
