import WebKit
import BrowserCore

/// Page-side half of boosts: puts the user's per-site stylesheet in the page, runs calm mode, and surveys a page for the local model.
/// Everything it applies is CSS that `BoostPolicy` already checked. Main frame only, own content world (the page cannot see it).
@MainActor
enum BoostScript {
    static let world = WKContentWorld.world(name: "oree-boost")

    struct Entry: Encodable { var host: String; var css: String; var calm: Bool; var enabled: Bool }
    struct Config: Encodable {
        var boosts: [Entry]
        var calmAll: Bool
        var calmCSS = BoostPolicy.calmCSS
    }

    static func config(boosts: [Boost], calmAll: Bool) -> Config {
        .init(boosts: boosts.map { .init(host: $0.host, css: BoostPolicy.css(for: $0.rules), calm: $0.calm, enabled: $0.enabled) }, calmAll: calmAll)
    }

    static func makeUserScript(_ config: Config) -> WKUserScript {
        WKUserScript(source: source(config), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// The script with `config` baked in. Evaluated in a page that already has it, it just hands over the new config.
    static func source(_ config: Config) -> String {
        let json = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"boosts\":[],\"calmAll\":false,\"calmCSS\":\"\"}"
        return template.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    /// `{candidates: [{s, n, t}], elements}`: the selectors a boost could use on this page, each with how many elements it matches and
    /// the start of its text, biggest on screen first. This is what lets the model name real things ("Shorts") instead of guessing.
    static let survey = """
    const found = new Map();
    const all = document.body ? document.body.querySelectorAll('*') : [];
    const clean = c => c.length <= 40 && !/^[a-z0-9_-]{9,}$/i.test(c) || /^[a-z]+(-[a-z]+)+$/i.test(c);
    const note = (key, el) => { const e = found.get(key); if (e) e.n++; else found.set(key, { s: key, n: 1, el }); };
    let seen = 0;
    for (const el of all) {
      if (++seen > 6000) break;
      const tag = el.tagName.toLowerCase();
      if (tag.includes('-')) note(tag, el);
      if (el.id && el.id.length <= 40 && !/\\d{4,}/.test(el.id)) note('#' + CSS.escape(el.id), el);
      for (const c of el.classList) if (clean(c) && !/\\d{3,}/.test(c)) note('.' + CSS.escape(c), el);
    }
    const out = [];
    for (const e of found.values()) {
      if (e.n > 80) continue;
      const r = e.el.getBoundingClientRect();
      const area = Math.min(r.width * r.height, 4e6);
      const t = (e.el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
      if (area > 0 || e.n > 0) out.push({ s: e.s, n: e.n, t, a: area });
    }
    out.sort((x, y) => y.a - x.a);
    return { candidates: out.slice(0, 110).map(({ s, n, t }) => ({ s, n, t })), elements: all.length };
    """

    /// For each selector: how many elements it matches on this page (an invalid selector counts 0) and how much text they hold; plus how many
    /// elements and how much text the page has. Lets the app drop a rule that matches nothing, nearly everything, or the article itself.
    static func countCall(selectors: [String]) -> (body: String, arguments: [String: Any]) {
        ("""
         const counts = [], texts = [];
         for (const s of selectors) {
           try {
             const found = document.querySelectorAll(s);
             counts.push(found.length);
             let n = 0; for (const el of found) n += (el.innerText || '').length;
             texts.push(n);
           } catch (_) { counts.push(0); texts.push(0); }
         }
         return { counts, texts, elements: document.querySelectorAll('*').length, pageText: (document.body ? document.body.innerText : '').length };
         """, ["selectors": selectors])
    }

    private static let template = #"""
    (() => {
      const incoming = __CONFIG__;
      if (window.__oreeBoost) { window.__oreeBoost.sync(incoming); return; }
      if (!/^https?:$/.test(location.protocol)) return;
      const host = location.hostname.replace(/^www\./, '').toLowerCase();
      let cfg = incoming, calmOn = false, observer = null;
      const styles = {};
      const mine = () => cfg.boosts.find(b => host === b.host || host.endsWith('.' + b.host));

      function setStyle(id, css) {
        let el = styles[id];
        if (!css) { if (el) el.remove(); delete styles[id]; return; }
        if (!el) { el = document.createElement('style'); el.setAttribute('data-oree', id); styles[id] = el; }
        if (el.textContent !== css) el.textContent = css;
        if (!el.isConnected) (document.documentElement || document).appendChild(el);
      }

      // ---- calm mode: no autoplay until the user touches the page, no "(3)" counters in the title ----
      const quiet = e => { const t = e.target; if (t instanceof HTMLMediaElement && !(navigator.userActivation && navigator.userActivation.hasBeenActive)) t.pause(); };
      function stripTitle() {
        const t = document.title, clean = t.replace(/^\s*\(\d+\+?\)\s*/, '');
        if (clean !== t) document.title = clean;
      }
      function calmStart() {
        if (calmOn) return;
        calmOn = true;
        document.addEventListener('play', quiet, true);
        document.querySelectorAll('video[autoplay], audio[autoplay]').forEach(m => { m.removeAttribute('autoplay'); m.pause(); });
        const watch = () => {
          observer = new MutationObserver(() => {
            stripTitle();
            document.querySelectorAll('video[autoplay], audio[autoplay]').forEach(m => { m.removeAttribute('autoplay'); if (!(navigator.userActivation && navigator.userActivation.hasBeenActive)) m.pause(); });
          });
          observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
          stripTitle();
        };
        document.documentElement ? watch() : document.addEventListener('readystatechange', watch, { once: true });
      }
      function calmStop() {
        if (!calmOn) return;
        calmOn = false;
        document.removeEventListener('play', quiet, true);
        if (observer) { observer.disconnect(); observer = null; }
      }

      function apply() {
        const b = mine();
        setStyle('boost', b && b.enabled ? b.css : '');
        const calm = (b && b.enabled && b.calm) || cfg.calmAll;
        setStyle('boost-calm', calm ? cfg.calmCSS : '');
        calm ? calmStart() : calmStop();
      }

      window.__oreeBoost = { sync(next) { cfg = next; apply(); } };
      apply();
    })();
    """#
}
