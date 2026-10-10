import Foundation
import WebKit

/// JavaScript run inside a page (own content world, so the page cannot see or spoof it) to freeze it into a
/// "ghost": a self-contained copy of its DOM and styles that a JavaScript-less web view can show.
@MainActor
enum GhostScript {
    static let world = WKContentWorld.world(name: "oree-ghost")

    /// Returns `JSON.stringify({v, url, title, scrollX, scrollY, vw, vh, html})` or `{"error": …}`.
    ///
    /// What it does to the copy (the live page is never modified):
    ///  - drops `<script>`, `<noscript>` (with JS off its content would show up), `<meta http-equiv=refresh>`,
    ///    the existing `<base>` (replaced by one pointing at the page URL) and resource-hint links;
    ///  - writes the form state into attributes (value / checked / selected / textarea text), and NEVER the value of a
    ///    password, card or one-time-code field, nor hidden inputs (they often hold tokens);
    ///  - records the scroll offset of every scrollable element in `data-oree-scroll`;
    ///  - rebuilds `<style>` text from the live CSSOM (rules added with `insertRule` never reach the markup)
    ///    and adds adopted style sheets; cross-origin `<link>` sheets stay as links (their rules are unreadable,
    ///    but they reload from the shared HTTP cache);
    ///  - turns lazy images eager;
    ///  - CSS animations: in the ghost they would start again from zero (a banner that faded out ten seconds ago
    ///    would fade in again); an animation that ended without filling is simply switched off. An element whose animations are all finished gets their end values written inline and
    ///    `animation: none`; an element with exactly one running animation continues from the same moment
    ///    (negative `animation-delay`). Elements with several animations are left as they are (known limit).
    static let capture = """
    (function () {
      try {
        var doc = document, root = doc.documentElement;
        var live = root.querySelectorAll('*'), clone = root.cloneNode(true), copy = clone.querySelectorAll('*');
        if (live.length !== copy.length) return JSON.stringify({ error: 'clone mismatch' });
        var drop = [], hint = /(^|\\s)(preload|modulepreload|prefetch|dns-prefetch|preconnect|prerender)(\\s|$)/;
        var secret = /password|cc-|one-time-code/i;
        function rulesText(sheet) { var t = ''; for (var k = 0; k < sheet.cssRules.length; k++) t += sheet.cssRules[k].cssText + '\\n'; return t; }
        for (var i = 0; i < live.length; i++) {
          var e = live[i], c = copy[i], tag = e.tagName;
          if (tag === 'SCRIPT' || tag === 'NOSCRIPT' || tag === 'BASE') { drop.push(c); continue; }
          if (tag === 'META' && /refresh/i.test(e.getAttribute('http-equiv') || '')) { drop.push(c); continue; }
          if (tag === 'LINK') { if (hint.test((e.getAttribute('rel') || '').toLowerCase())) drop.push(c); continue; }
          if (e.scrollTop || e.scrollLeft) c.setAttribute('data-oree-scroll', Math.round(e.scrollLeft) + ',' + Math.round(e.scrollTop));
          if (tag === 'INPUT') {
            var t = (e.type || '').toLowerCase();
            if (t === 'password' || t === 'hidden' || secret.test(e.getAttribute('autocomplete') || '')) { c.setAttribute('value', ''); }
            else if (t === 'checkbox' || t === 'radio') { if (e.checked) c.setAttribute('checked', ''); else c.removeAttribute('checked'); }
            else if (t !== 'file') { c.setAttribute('value', e.value); }
          } else if (tag === 'TEXTAREA') {
            c.textContent = secret.test(e.getAttribute('autocomplete') || '') ? '' : e.value;
          } else if (tag === 'SELECT') {
            for (var j = 0; j < e.options.length; j++) { if (e.options[j].selected) c.options[j].setAttribute('selected', ''); else c.options[j].removeAttribute('selected'); }
          } else if (tag === 'IMG') {
            if (e.getAttribute('loading') === 'lazy') c.setAttribute('loading', 'eager');
          } else if (tag === 'STYLE') {
            try { if (e.sheet) c.textContent = rulesText(e.sheet); } catch (x) {}
          }
        }
        // CSS animations (see the header comment): freeze finished ones, resume running ones where they were.
        try {
          var index = new Map(); for (var q = 0; q < live.length; q++) index.set(live[q], q);
          var byElement = new Map();
          (doc.getAnimations ? doc.getAnimations() : []).forEach(function (a) {
            if (typeof CSSAnimation === 'undefined' || !(a instanceof CSSAnimation)) return;
            var t = a.effect && a.effect.target; if (!t || !index.has(t)) return;
            if (!byElement.has(t)) byElement.set(t, []); byElement.get(t).push(a);
          });
          byElement.forEach(function (list, el) {
            var c = copy[index.get(el)]; if (!c) return;
            if (list.every(function (a) { return a.playState === 'finished'; })) {
              var cs = getComputedStyle(el);
              list.forEach(function (a) {
                a.effect.getKeyframes().forEach(function (kf) {
                  Object.keys(kf).forEach(function (k) {
                    if (k === 'offset' || k === 'easing' || k === 'composite' || k === 'computedOffset') return;
                    try { c.style[k] = cs[k]; } catch (x) {}
                  });
                });
              });
              c.style.animation = 'none';
            } else if (list.length === 1 && list[0].playState === 'running' && list[0].currentTime != null) {
              var timing = list[0].effect.getTiming();
              c.style.animationDelay = (timing.delay - list[0].currentTime) + 'ms';
            }
          });
          // An animation that already ended *without* filling is no longer reported by getAnimations(), yet the
          // element still names it: the ghost would replay it from its first frame. Switch it off.
          var started = performance.now();     // big pages: stop early rather than blow the caller's deadline
          for (var w = 0; w < live.length; w++) {
            if ((w & 255) === 0 && performance.now() - started > 300) break;
            if (byElement.has(live[w])) continue;
            var an = getComputedStyle(live[w]).animationName;
            if (an && an !== 'none') copy[w].style.animation = 'none';
          }
        } catch (x) {}
        drop.forEach(function (n) { n.remove(); });
        var head = clone.querySelector('head');
        if (head) {
          var extra = '';
          (doc.adoptedStyleSheets || []).forEach(function (s) { try { extra += rulesText(s); } catch (x) {} });
          if (extra) { var st = doc.createElement('style'); st.setAttribute('data-oree-ghost', ''); st.textContent = extra; head.appendChild(st); }
          var base = doc.createElement('base'); base.href = doc.baseURI; head.insertBefore(base, head.firstChild);
          // While the ghost settles, style sheets arrive one after the other and each change would play as a visible
          // transition (a closed menu "closing" again on screen). Transitions are off until GhostView removes this.
          var boot = doc.createElement('style'); boot.setAttribute('data-oree-ghost-boot', '');
          boot.textContent = '*,*::before,*::after{transition:none!important}'; head.appendChild(boot);
        }
        var dt = doc.doctype ? new XMLSerializer().serializeToString(doc.doctype) : '';
        return JSON.stringify({
          v: 1, url: location.href, title: doc.title, scrollX: window.scrollX, scrollY: window.scrollY,
          vw: window.innerWidth, vh: window.innerHeight, html: dt + clone.outerHTML
        });
      } catch (err) { return JSON.stringify({ error: String(err) }); }
    })()
    """

    /// Lets transitions run again (hover effects) once the ghost has settled.
    static let endBoot = "document.querySelectorAll('style[data-oree-ghost-boot]').forEach(function (n) { n.remove(); })"

    /// Puts the recorded scroll offsets back in the ghost (page scroll + every `data-oree-scroll` container).
    static func restoreScroll(x: Double, y: Double) -> String {
        """
        (function () {
          document.querySelectorAll('[data-oree-scroll]').forEach(function (e) {
            var p = e.getAttribute('data-oree-scroll').split(','); e.scrollLeft = +p[0]; e.scrollTop = +p[1];
          });
          window.scrollTo(\(x), \(y));
        })()
        """
    }

    // MARK: Hydration (phase 2): is the real page ready, and what does it show?

    /// Body for `callAsyncJavaScript` on the REAL page. Resolves "ready" once the document is complete, fonts are
    /// loaded, the images in the viewport are loaded and nothing visible changed for 150 ms; "timeout" after
    /// `timeoutMs`. Always ends with two animation frames, so the page has painted what it shows when this returns.
    static let ready = """
    const deadline = performance.now() + timeoutMs;
    let last = performance.now();
    const inView = (n) => {
      const e = n.nodeType === 1 ? n : n.parentElement;
      if (!e || !e.getBoundingClientRect) return false;
      const r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
    };
    const observer = new MutationObserver((list) => {
      for (const m of list) { if (inView(m.target)) { last = performance.now(); break; } }
    });
    observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    const fontsLoaded = () => !document.fonts || document.fonts.status === 'loaded';
    const imagesLoaded = () => Array.prototype.every.call(document.images, (img) => img.complete || !inView(img));
    let reason = 'timeout';
    while (performance.now() < deadline) {
      if (document.readyState === 'complete' && fontsLoaded() && imagesLoaded() && performance.now() - last >= 150) { reason = 'ready'; break; }
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    observer.disconnect();
    // Two animation frames mean the page has painted what it shows. A page that is not being drawn never gets them:
    // do not wait for ever, and say so.
    const painted = await Promise.race([
      new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve('painted')))),
      new Promise((resolve) => setTimeout(() => resolve('no-frames'), 400)),
    ]);
    return reason + '/' + painted + '/' + document.readyState + '/' + (document.fonts ? document.fonts.status : 'nofonts') + '/' + document.visibilityState;
    """

    /// Body for `callAsyncJavaScript`: "painted" once two animation frames went by, "no-frames" if none came within 400 ms
    /// (the page is not being drawn: window hidden, tab not shown).
    static let painted = """
    return await Promise.race([
      new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve('painted')))),
      new Promise((resolve) => setTimeout(() => resolve('no-frames'), 400)),
    ]);
    """

    /// JSON array of `GhostItem` for the text blocks visible in the viewport (same script for ghost and real page).
    static let visibleItems = """
    (function () {
      function hash(text) {
        var s = text.replace(/\\s+/g, ' ').trim().slice(0, 120), x = 5381;
        for (var i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) >>> 0;
        return x;
      }
      var out = [], all = document.body ? document.body.querySelectorAll('*') : [], vh = innerHeight, vw = innerWidth;
      for (var i = 0; i < all.length && out.length < 400; i++) {
        var e = all[i], t = '';
        for (var n = e.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) t += n.nodeValue;
        t = t.replace(/\\s+/g, ' ').trim();
        if (t.length < 8) continue;
        var r = e.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0 || r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) continue;
        var cs = getComputedStyle(e);
        if (cs.visibility !== 'visible' || +cs.opacity < 0.05) continue;
        out.push({ t: e.tagName, h: hash(t), x: Math.round(r.left), y: Math.round(r.top) });
      }
      return JSON.stringify(out);
    })()
    """
}
