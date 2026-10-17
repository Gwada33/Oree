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

    /// `auto` : l'éventail apparaît tout seul à la fin d'une sélection. Sinon (le défaut) le script se tait : il ne répond que quand le clic droit lui demande la sélection.
    static func makeUserScript(auto: Bool) -> WKUserScript {
        WKUserScript(source: "window.__oreeLucioleAuto = \(auto);\n" + source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    /// Le passage sélectionné et ses rectangles, à la demande (clic droit › Expliquer avec Luciole).
    static let readCall: (body: String, arguments: [String: Any]) = ("return window.__oreeLuciole ? window.__oreeLuciole.read() : null;", [:])

    /// Le suivi du défilement continue après que la sélection a disparu, tant que la réponse ancrée reste affichée.
    static func trackCall(_ on: Bool) -> (body: String, arguments: [String: Any]) {
        ("if (window.__oreeLuciole) window.__oreeLuciole.track(on); return 'ok';", ["on": on])
    }

    /// Les morceaux de page à ne pas recouvrir (médias, boutons, champs : poids 3 ; texte : poids 1), en pixels CSS de la fenêtre d'affichage. Lecture seule.
    static let occupiedCall: (body: String, arguments: [String: Any]) = ("return window.__oreeLuciole ? window.__oreeLuciole.occupied() : null;", [:])

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
      const readNow = () => {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0 || inField()) return null;
        const text = String(sel);
        if (text.trim().split(/\s+/).length < 3 || text.length > 3000) return null;
        hasSel = true;
        return JSON.stringify({ type: 'sel', text: text.slice(0, 3000), rects: rectsOf(sel.getRangeAt(0)), view: view() });
      };
      if (window.__oreeLucioleAuto) document.addEventListener('selectionchange', () => {
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
      const occupied = () => {
        const out = [], vw = window.innerWidth, vh = window.innerHeight;
        const add = (el, w) => {
          const r = el.getBoundingClientRect();
          if (r.width < 8 || r.height < 8 || r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) return;
          const s = getComputedStyle(el); if (s.visibility === 'hidden' || s.display === 'none' || +s.opacity === 0) return;
          out.push({ x: Math.max(r.left, 0), y: Math.max(r.top, 0), w: Math.min(r.right, vw) - Math.max(r.left, 0), h: Math.min(r.bottom, vh) - Math.max(r.top, 0), k: w });
        };
        document.querySelectorAll('img, video, canvas, iframe, audio, picture, svg[width], button, input, select, textarea, [role=button], [role=dialog]').forEach(el => { if (out.length < 300) add(el, 3); });
        document.querySelectorAll('p, li, h1, h2, h3, h4, blockquote, pre, td, figcaption').forEach(el => { if (out.length < 500 && el.children.length < 6) add(el, 1); });
        return JSON.stringify(out);
      };
      window.__oreeLuciole = { read: readNow, occupied, track(on) { tracking = !!on; if (tracking) post({ type: 'view', view: view() }); } };
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
