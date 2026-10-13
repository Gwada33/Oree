import Foundation
import WebKit

/// Small scripts used around the ghost (the capture itself lives in `GhostBootstrap`): scroll restoration, the end of the
/// start-up transition freeze, and the readiness / comparison probes of the hand-over. They run in the isolated
/// `oree-ghost` world.
@MainActor
enum GhostScript {
    static let world = WKContentWorld.world(name: "oree-ghost")

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

    // MARK: User state (phase 4): what the user did in the ghost before the swap

    /// Read in the GHOST: what the user changed since it was shown (typed text, ticked boxes), the focused field with its
    /// caret, and the selected text. Fields are matched by id, then name, then position among the form controls; passwords
    /// are never read. Returns JSON.
    static let readUserState = """
    (function () {
      function controls() { return Array.prototype.slice.call(document.querySelectorAll('input,textarea,select')); }
      function key(e, i) { return e.id ? '#' + e.id : (e.name ? e.tagName + '[name=' + e.name + ']:' + i : e.tagName + ':' + i); }
      var out = { fields: [], focus: null, selection: '' };
      controls().forEach(function (e, i) {
        if (e.type === 'password' || e.type === 'file' || e.type === 'hidden') return;
        var isBox = e.type === 'checkbox' || e.type === 'radio';
        var changed = isBox ? e.checked !== e.defaultChecked : (e.tagName === 'SELECT' ? e.selectedIndex !== -1 && !e.options[e.selectedIndex].defaultSelected : e.value !== e.defaultValue);
        if (changed) out.fields.push({ k: key(e, i), tag: e.tagName, type: e.type, v: isBox ? e.checked : e.value });
      });
      var a = document.activeElement;
      if (a && a !== document.body && /^(INPUT|TEXTAREA)$/.test(a.tagName) && a.type !== 'password') {
        out.focus = { k: key(a, controls().indexOf(a)), s: a.selectionStart, e: a.selectionEnd };
      }
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) out.selection = sel.toString().slice(0, 500);
      return JSON.stringify(out);
    })()
    """

    /// Run in the REAL page: puts that state back. Values go through the native setter and fire `input` / `change`, so
    /// frameworks that track their own value (React, Vue) notice. A field the page no longer has is skipped.
    static func applyUserState(_ json: String) -> String {
        let literal = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "\"{}\""
        return """
        (function () {
          var st = JSON.parse(\(literal));
          var list = Array.prototype.slice.call(document.querySelectorAll('input,textarea,select'));
          function key(e, i) { return e.id ? '#' + e.id : (e.name ? e.tagName + '[name=' + e.name + ']:' + i : e.tagName + ':' + i); }
          function find(k) { for (var i = 0; i < list.length; i++) if (key(list[i], i) === k) return list[i]; return null; }
          function native(e, prop, v) {
            var proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : e.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
            var d = Object.getOwnPropertyDescriptor(proto, prop); if (d && d.set) d.set.call(e, v); else e[prop] = v;
          }
          st.fields.forEach(function (f) {
            var e = find(f.k); if (!e || e.tagName !== f.tag || e.type !== f.type) return;
            var box = f.type === 'checkbox' || f.type === 'radio';
            if (box ? e.checked === f.v : e.value === f.v) return;
            native(e, box ? 'checked' : 'value', f.v);
            e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true }));
          });
          if (st.focus) {
            var e = find(st.focus.k);
            if (e) { e.focus({ preventScroll: true }); try { e.setSelectionRange(st.focus.s, st.focus.e); } catch (x) {} }
          } else if (st.selection && window.find) {
            window.getSelection().removeAllRanges(); window.find(st.selection, true, false, false);
          }
          return 'ok';
        })()
        """
    }
}
