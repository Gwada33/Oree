import WebKit

/// Page-side half of "reprendre où tu en étais": it only measures and reports, the app decides (see `ResumePolicy`).
///
/// - Reading: on an article (see `isArticle`) at least three screens long, the scroll position is reported (1.5 s after scrolling stops), with the start
///   of the paragraph at the top of the screen, to find the place again if the page changed a little.
/// - `go` jumps back: seeks the video, or scrolls to the paragraph (else to the same fraction of the page).
///
/// Main frame only, own content world.
@MainActor
enum ResumeScript {
    static let world = WKContentWorld.world(name: "oree-resume")
    static let handlerName = "oreeResume"

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// Runs `go` for an offer: `seconds` for a video, else `fraction` (+ the paragraph start).
    static func goCall(seconds: Double?, fraction: Double?, anchor: String?) -> (body: String, arguments: [String: Any]) {
        ("return window.__oreeResume ? window.__oreeResume.go(seconds, fraction, anchor) : false;",
         ["seconds": seconds as Any? ?? NSNull(), "fraction": fraction as Any? ?? NSNull(), "anchor": anchor as Any? ?? NSNull()])
    }

    private static let source = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__oreeResume) return;
      // Each report says which page it is about: one can arrive after the tab already moved on (pagehide, throttled timers).
      const post = o => { try { o.u = location.href; o.ti = document.title; window.webkit.messageHandlers.oreeResume.postMessage(JSON.stringify(o)); } catch (_) {} };
      const BLOCKS = 'p, h1, h2, h3, h4, li, blockquote';
      const norm = s => (s || '').replace(/\s+/g, ' ').trim().slice(0, 60);

      // ---- reading ----
      let timer = 0, article = false;
      // Only real articles: a long page is not enough (feeds, shops, forums, search results are long too). An article
      // declares itself (og:type, JSON-LD) or is a page whose <article>/<main> holds a lot of paragraph text.
      function isArticle() {
        if (article) return true;
        if (location.pathname.length <= 1) return false;
        const og = document.querySelector('meta[property="og:type"]');
        let declared = !!og && /article/i.test(og.content);
        if (!declared) declared = [...document.querySelectorAll('script[type="application/ld+json"]')].some(n => /"@type"\s*:\s*\[?\s*"(News|Blog|Tech|Scholarly)?Article"/.test(n.textContent));
        const root = document.querySelector('article') || (declared ? document.querySelector('main') || document.body : null);
        if (!root) return false;
        let chars = 0;
        for (const p of root.querySelectorAll('p')) chars += p.textContent.length;
        article = chars >= (declared ? 1500 : 3000);
        return article;
      }
      function reportReading() {
        if (!isArticle()) return;
        const de = document.documentElement, vh = innerHeight || 1;
        const total = Math.max(de.scrollHeight, document.body ? document.body.scrollHeight : 0);
        const screens = total / vh;
        if (screens < 3) return;
        const max = total - vh;
        const el = document.elementFromPoint(innerWidth / 2, Math.min(80, vh / 4));
        const block = el && el.closest ? el.closest(BLOCKS) : null;
        post({ reading: { f: max > 0 ? scrollY / max : 0, screens, a: block ? norm(block.textContent) : '' } });
      }
      addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(reportReading, 1500); }, { passive: true, capture: true });
      addEventListener('pagehide', () => { clearTimeout(timer); reportReading(); });

      // ---- jump back ----
      window.__oreeResume = {
        go(seconds, fraction, anchor) {
          if (seconds !== null) {
            let best = null, area = 0;
            for (const v of document.querySelectorAll('video')) { const a = v.clientWidth * v.clientHeight; if (a >= area) { best = v; area = a; } }
            if (!best) return false;
            best.currentTime = seconds;
            best.play().catch(() => {});
            best.scrollIntoView({ block: 'center', behavior: 'smooth' });
            return true;
          }
          const target = anchor ? [...document.querySelectorAll(BLOCKS)].find(e => norm(e.textContent) === anchor) : null;
          if (target) target.scrollIntoView({ block: 'start' });
          else { const de = document.documentElement; scrollTo(0, (fraction || 0) * Math.max(de.scrollHeight - innerHeight, 0)); }
          return true;
        },
      };
    })();
    """#
}

/// Receives the page script's reports and hands them to the tab's window.
final class ResumeMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let json = message.body as? String else { return }
        MainActor.assumeIsolated { if let tab = Tab.tabsByWebView.object(forKey: message.webView) { Tab.resumeReported?(tab, json) } }
    }
}
