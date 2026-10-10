import WebKit

/// Page-side half of "reprendre où tu en étais": it only measures and reports, the app decides (see `ResumePolicy`).
///
/// - Video: the video being watched (any site, any player that uses a `<video>`) reports its position at most every 5 s and when
///   it pauses, ends or the page is left. The same `<video>` is used for ads, but those are short and ignored by the app.
/// - Reading: on a page at least three screens long, the scroll position is reported (1.5 s after scrolling stops), with the start
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

      // ---- video ----
      let video = null, lastVideo = 0;
      function reportVideo(force) {
        const v = video;
        if (!v || !isFinite(v.duration) || v.duration < 180) return;
        const now = Date.now();
        if (!force && now - lastVideo < 5000) return;
        lastVideo = now;
        if (v.ended || v.currentTime > v.duration - 20) post({ video: { done: true } });
        else post({ video: { t: v.currentTime, d: v.duration } });
      }
      // Media events do not bubble: listen in the capture phase on the document.
      document.addEventListener('timeupdate', e => {
        const v = e.target;
        if (!(v instanceof HTMLVideoElement)) return;
        if (!video || (v !== video && !v.paused && v.duration >= 180)) video = v;
        if (v === video) reportVideo(false);
      }, true);
      for (const type of ['pause', 'ended']) document.addEventListener(type, e => { if (e.target === video) reportVideo(true); }, true);

      // ---- reading ----
      let timer = 0;
      function reportReading() {
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
      addEventListener('pagehide', () => { reportVideo(true); clearTimeout(timer); reportReading(); });

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
