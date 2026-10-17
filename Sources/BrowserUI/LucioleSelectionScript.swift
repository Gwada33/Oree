import WebKit
import BrowserCore

/// Le script de LECTURE de Luciole dans la page : il ne change rien au site (aucun style, aucun nœud). Dans un monde isolé, il surveille la sélection et renvoie
/// les rectangles du texte sélectionné (coordonnées de la fenêtre d'affichage), pour que la couche native dessine l'éventail, le surlignage et le fil de lumière.
/// Après trois mots sélectionnés, 300 ms sans changement et hors champ de saisie, il envoie la sélection ; tant qu'une sélection (ou un suivi demandé par la couche)
/// existe, il renvoie aussi le défilement et la taille de la fenêtre, au plus une fois par image. Sans sélection ni suivi, il ne calcule rien.
@MainActor
enum LucioleSelectionScript {
    static let world = WKContentWorld.world(name: "oree-luciole")
    static let handlerName = "oreeLuciole"

    static func makeUserScript() -> WKUserScript { WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world) }

    /// Le suivi du défilement continue après que la sélection a disparu, tant que la réponse ancrée reste affichée.
    static func trackCall(_ on: Bool) -> (body: String, arguments: [String: Any]) {
        ("if (window.__oreeLuciole) window.__oreeLuciole.track(on); return 'ok';", ["on": on])
    }

    private static let source = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__oreeLuciole) return;
      const post = (o) => { try { window.webkit.messageHandlers.oreeLuciole.postMessage(JSON.stringify(o)); } catch (_) {} };
      let timer = 0, tracking = false, hasSel = false, frame = 0;
      const inField = () => {
        const a = document.activeElement;
        return !!a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName));
      };
      const view = () => ({ sx: window.scrollX, sy: window.scrollY, w: window.innerWidth, h: window.innerHeight });
      const rectsOf = (range) => Array.from(range.getClientRects()).filter(r => r.width > 1 && r.height > 1).slice(0, 80).map(r => ({ x: r.left, y: r.top, w: r.width, h: r.height }));
      const sendSelection = () => {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0 || inField()) { if (hasSel) { hasSel = false; post({ type: 'clear' }); } return; }
        const text = String(sel);
        if (text.trim().split(/\s+/).length < 3 || text.length > 3000) { if (hasSel) { hasSel = false; post({ type: 'clear' }); } return; }
        hasSel = true;
        post({ type: 'sel', text: text.slice(0, 3000), rects: rectsOf(sel.getRangeAt(0)), view: view() });
      };
      document.addEventListener('selectionchange', () => {
        clearTimeout(timer);
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed) { if (hasSel) { hasSel = false; post({ type: 'clear' }); } return; }
        timer = setTimeout(sendSelection, 300);          // fin de sélection + 300 ms
      }, { passive: true });
      const follow = () => {
        if (frame || !(tracking || hasSel)) return;
        frame = requestAnimationFrame(() => {
          frame = 0;
          if (hasSel) { const sel = window.getSelection(); if (sel && sel.rangeCount) { post({ type: 'sel', text: null, rects: rectsOf(sel.getRangeAt(0)), view: view() }); return; } }
          post({ type: 'view', view: view() });
        });
      };
      window.addEventListener('scroll', follow, { passive: true, capture: true });
      window.addEventListener('resize', follow, { passive: true });
      window.__oreeLuciole = { track(on) { tracking = !!on; if (tracking) post({ type: 'view', view: view() }); } };
    })();
    """#
}

/// Reçoit ce que le script voit (monde isolé, page principale seulement) et le confie à la fenêtre.
final class LucioleSelectionHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let json = message.body as? String else { return }
        MainActor.assumeIsolated { if let tab = Tab.tabsByWebView.object(forKey: message.webView) { tab.owner?.handleLucioleSelection(tab: tab, json: json) } }
    }
}
