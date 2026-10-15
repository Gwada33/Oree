import WebKit
import BrowserCore

/// Night mode: darkens every site, including those with no dark theme of their own.
///
/// The page is inverted and turned back half a circle in hue (`invert(1) hue-rotate(180deg)`), so white becomes dark gray and
/// colors keep their hue; photos, videos, canvases and large background images are flipped back so they look as they should.
/// Small images stay inverted (icons and logos drawn for a light background read better that way). The filter sits on the root
/// element, which keeps `position: fixed` working.
///
/// A site that is already dark must not be inverted: after the page has loaded the script reads the real background color, and
/// if it is dark it switches itself off and tells the app, which remembers the site (so the next visit has no flash at all).
/// The very first visit to such a site can show a short light flash.
///
/// Runs in the main frame only (iframes are inverted along with their parent; known video players are flipped back), in its own
/// content world. The page cannot see it.
@MainActor
enum NightScript {
    static let world = WKContentWorld.world(name: "oree-night")
    static let handlerName = "oreeNight"

    struct Config: Encodable {
        var enabled: Bool
        var excluded: [String]
        var native: [String]
    }

    static func makeUserScript(_ config: Config) -> WKUserScript {
        WKUserScript(source: source(config), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// The script with `config` baked in. Evaluating it in a page that already has the script just hands it the new config.
    static func source(_ config: Config) -> String {
        let json = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"enabled\":false,\"excluded\":[],\"native\":[]}"
        return template.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    private static let template = #"""
    (() => {
      const incoming = __CONFIG__;
      if (window.__oreeNight) { window.__oreeNight.sync(incoming); return; }
      if (!/^https?:$/.test(location.protocol)) return;                           // Orée's own pages are already themed
      if (/^(image|video|audio)\//.test(document.contentType || '')) return;      // a picture on its own is not a page to invert

      let cfg = incoming, started = false, nativeDark = false, style = null, observer = null;
      const host = location.hostname.replace(/^www\./, '').toLowerCase();
      const inList = list => list.some(h => host === h || host.endsWith('.' + h));
      const FLIP = 'invert(1) hue-rotate(180deg)';
      const CSS = `
        html { filter: ${FLIP} contrast(.85) !important; }
        img, video, canvas, [data-oree-keep], iframe[src*="youtube"], iframe[src*="vimeo"], iframe[src*="twitch"], iframe[src*="dailymotion"] { filter: ${FLIP} !important; }
        img[data-oree-icon] { filter: none !important; }
        [data-oree-keep] img, [data-oree-keep] video, [data-oree-keep] canvas { filter: none !important; }`;

      const wanted = () => cfg.enabled && !nativeDark && !inList(cfg.excluded || []) && !inList(cfg.native || []);

      function apply() {
        if (wanted()) {
          if (!style) { style = document.createElement('style'); style.textContent = CSS; }
          if (!style.isConnected) (document.documentElement || document).appendChild(style);
          start();
        } else if (style && style.isConnected) style.remove();
      }

      // ---- already dark? ----
      function luminance(color) {
        const m = (color || '').match(/[\d.]+/g);
        if (!m || m.length < 3) return null;
        const alpha = m.length > 3 ? +m[3] : 1;
        return alpha < 0.1 ? null : (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255;
      }
      function pageIsDark() {
        for (const el of [document.body, document.documentElement]) {
          const l = el && luminance(getComputedStyle(el).backgroundColor);
          if (l !== null && l !== undefined) return l < 0.4;
        }
        return false;       // no background anywhere: the browser's white
      }
      function check() {
        if (nativeDark || !cfg.enabled || inList(cfg.native || [])) return;
        if (pageIsDark()) {
          nativeDark = true;
          apply();
          window.webkit.messageHandlers.oreeNight.postMessage(host);
        }
      }

      // ---- images and backgrounds: keep photos, let icons flip ----
      const queue = [];
      let scheduled = false;
      const idle = window.requestIdleCallback ? fn => requestIdleCallback(fn, { timeout: 500 }) : fn => setTimeout(() => fn({ timeRemaining: () => 8 }), 30);
      function classify(el) {
        if (el.tagName === 'IMG') {
          const small = el.complete && el.naturalWidth > 0 ? (el.clientWidth < 64 || el.clientHeight < 64) : false;
          if (el.complete) el.toggleAttribute('data-oree-icon', small);
          else el.addEventListener('load', () => classify(el), { once: true });
          return;
        }
        if (el.hasAttribute('data-oree-keep') || el.closest('[data-oree-keep]')) return;
        if (el.offsetWidth * el.offsetHeight < 6400) return;
        if (getComputedStyle(el).backgroundImage.includes('url(')) {
          el.querySelectorAll('[data-oree-keep]').forEach(c => c.removeAttribute('data-oree-keep'));    // never flip twice
          el.setAttribute('data-oree-keep', '');
        }
      }
      function work(deadline) {
        scheduled = false;
        while (queue.length && deadline.timeRemaining() > 2) { const el = queue.shift(); if (el.isConnected) classify(el); }
        if (queue.length) schedule();
      }
      function schedule() { if (!scheduled) { scheduled = true; idle(work); } }
      function enqueue(root) {
        if (root.nodeType !== 1) return;
        queue.push(root);
        for (const el of root.querySelectorAll('*')) { if (queue.length > 4000) break; queue.push(el); }
        schedule();
      }

      function start() {
        if (started) return;
        started = true;
        const begin = () => {
          if (document.documentElement) enqueue(document.documentElement);
          setTimeout(check, 250);
          observer = new MutationObserver(records => { if (wanted()) for (const r of records) r.addedNodes.forEach(enqueue); });
          observer.observe(document.documentElement, { childList: true, subtree: true });
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', begin, { once: true });
        else begin();
        window.addEventListener('load', () => { setTimeout(check, 400); if (document.documentElement) enqueue(document.documentElement); }, { once: true });
      }

      window.__oreeNight = { sync(next) { cfg = next; apply(); if (cfg.enabled && started) check(); } };
      apply();
    })();
    """#
}

/// Receives "this site is already dark" from the page script.
final class NightMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = message.body as? String else { return }
        MainActor.assumeIsolated { Tab.tabsByWebView.object(forKey: message.webView)?.owner?.nativeDarkDetected(host) }
    }
}
