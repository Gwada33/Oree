import WebKit

/// Page-side half of page translation. It runs in its own isolated content world: it sees the same DOM as the page, but the
/// page's scripts cannot see it, call it or tamper with the text it hands out.
///
/// The model translates ~3 segments per second, so the script never hands out the whole page: `collect` returns the segments
/// closest to the screen, and the app asks again after a scroll, a click or a DOM change (`watch` posts a debounced "more").
@MainActor
enum TranslationScript {
    static let world = WKContentWorld.world(name: "oree-translate")
    /// Message handler the page-side `ping` posts to (registered in this world only).
    static let handlerName = "oreeTranslate"

    /// Defines `window.__oreeTr` in the world (once); every call prepends it, so no separate install step can be forgotten.
    static let source = #"""
    if (!window.__oreeTr) window.__oreeTr = (() => {
      const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEXTAREA','CODE','PRE','KBD','SAMP','VAR','SVG','MATH','IFRAME','CANVAS','TEMPLATE','HEAD','OBJECT','EMBED']);
      const ATTRS = ['placeholder', 'title', 'alt', 'aria-label'];
      const LETTER = /\p{L}/u;
      const MAX_LENGTH = 4000;
      let slots = new Map();          // id → slot {id, kind: 't' text | 'a' attribute | 'd' document title, node, attr, orig, applied, lead, trail, state}
      let byText = new WeakMap();     // text node → slot
      let byAttr = new WeakMap();     // element → {attribute → slot}
      let nextId = 1, observer = null, timer = 0, watching = false;

      const read = s => s.kind === 't' ? s.node.nodeValue : s.kind === 'a' ? s.node.getAttribute(s.attr) : document.title;
      const write = (s, v) => { if (s.kind === 't') s.node.nodeValue = v; else if (s.kind === 'a') s.node.setAttribute(s.attr, v); else document.title = v; };

      // Calls onText for every text node worth a look, onElement for every element. Skips code, editable areas and
      // anything marked translate="no" / .notranslate. A callback returning true stops the walk.
      function walk(root, onText, onElement) {
        for (let n = root.firstChild; n; n = n.nextSibling) {
          if (n.nodeType === 3) { if (onText(n) === true) return true; continue; }
          if (n.nodeType !== 1) continue;
          if (SKIP.has(n.tagName.toUpperCase()) || n.getAttribute('translate') === 'no' || n.classList.contains('notranslate')) continue;
          const editable = n.getAttribute('contenteditable');
          if (editable === '' || editable === 'true') continue;
          if (onElement) onElement(n);
          if (n.shadowRoot && walk(n.shadowRoot, onText, onElement)) return true;
          if (walk(n, onText, onElement)) return true;
        }
        return false;
      }

      function track(s) { slots.set(s.id, s); return s; }

      // The page rewrote a text we already know (or one we gave up on): it is a new text.
      function refresh(s, value) {
        if (s.state === 'pending') return;
        if (s.state === 'done' ? value !== s.applied : value !== s.orig) { s.orig = value; s.state = 'new'; }
      }

      function textSlot(node) {
        const value = node.nodeValue;
        let s = byText.get(node);
        if (s) { refresh(s, value); return; }
        if (!LETTER.test(value)) return;
        s = track({ id: nextId++, kind: 't', node, attr: null, orig: value, applied: null, state: 'new' });
        byText.set(node, s);
      }

      function attributeSlots(el) {
        const names = ATTRS.slice();
        if (el.tagName === 'INPUT' && /^(submit|button|reset)$/i.test(el.type)) names.push('value');
        for (const attr of names) {
          const value = el.getAttribute(attr);
          if (!value) continue;
          let known = byAttr.get(el);
          if (!known) byAttr.set(el, known = {});
          const s = known[attr];
          if (s) { refresh(s, value); continue; }
          if (!LETTER.test(value)) continue;
          known[attr] = track({ id: nextId++, kind: 'a', node: el, attr, orig: value, applied: null, state: 'new' });
        }
      }

      function titleSlot() {
        for (const s of slots.values()) if (s.kind === 'd') { refresh(s, document.title); return; }
        if (LETTER.test(document.title)) track({ id: nextId++, kind: 'd', node: null, attr: null, orig: document.title, applied: null, state: 'new' });
      }

      function prune() { for (const [id, s] of slots) if (s.kind !== 'd' && !s.node.isConnected) slots.delete(id); }

      function ping() {
        clearTimeout(timer);
        timer = setTimeout(() => window.webkit.messageHandlers.oreeTranslate.postMessage('more'), 400);
      }

      return {
        // {lang, text}: what the page declares and a sample of its visible text, to recognize the language.
        sample() {
          let text = '';
          walk(document.body || document.documentElement, n => {
            const v = n.nodeValue.trim();
            if (v.length > 20) text += v + '\n';
            return text.length > 2500;
          });
          return { lang: document.documentElement.lang || '', text };
        },

        // At most `limit` untranslated segments nearest to the screen, no further than `reach` screens away.
        collect(limit, reach) {
          prune();
          walk(document.body || document.documentElement, textSlot, attributeSlots);
          titleSlot();
          const height = Math.max(innerHeight, 1), rects = new Map(), found = [];
          for (const s of slots.values()) {
            if (s.state !== 'new') continue;
            const value = read(s);
            const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(value);
            if (!m[2] || m[2].length > MAX_LENGTH) { s.state = 'skip'; continue; }
            s.lead = m[1]; s.trail = m[3];
            let distance = 0;
            if (s.kind !== 'd') {
              const el = s.kind === 't' ? s.node.parentElement : s.node;
              let r = el && rects.get(el);
              if (el && !r) { r = el.getBoundingClientRect(); rects.set(el, r); }
              if (!r || (r.width === 0 && r.height === 0)) continue;                       // hidden: picked up when it shows (click / DOM change)
              distance = r.bottom < 0 ? -r.bottom : r.top > height ? r.top - height : 0;
            }
            if (distance <= reach * height) found.push([distance, s]);
          }
          found.sort((a, b) => a[0] - b[0]);
          return found.slice(0, limit).map(([, s]) => { s.state = 'pending'; return { id: s.id, text: s.orig.trim().replace(/\s+/g, ' ') }; });
        },

        // Puts the translations in. A text the page changed meanwhile is left alone and offered again.
        apply(items) {
          for (const { id, text } of items) {
            const s = slots.get(id);
            if (!s || s.state !== 'pending') continue;
            if (read(s) !== s.orig) { s.state = 'new'; continue; }
            write(s, s.lead + text + s.trail);
            s.applied = read(s);
            s.state = 'done';
          }
          if (observer) observer.takeRecords();      // our own writes are not page changes
          return true;
        },

        // Segments that could not be translated go back to the queue.
        release(ids) { for (const id of ids) { const s = slots.get(id); if (s && s.state === 'pending') s.state = 'new'; } return true; },

        // Tells the app when the page changes in a way that may bring new text: DOM edits, scrolling, clicks, resizing.
        watch() {
          if (watching) return true;
          watching = true;
          observer = new MutationObserver(ping);
          observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
          for (const type of ['scroll', 'click', 'resize']) addEventListener(type, ping, { capture: true, passive: true });
          return true;
        },

        // Puts every original text back and removes everything this script installed.
        restore() {
          for (const s of slots.values()) if (s.state === 'done' && read(s) === s.applied) write(s, s.orig);
          if (observer) observer.disconnect();
          clearTimeout(timer);
          for (const type of ['scroll', 'click', 'resize']) removeEventListener(type, ping, { capture: true });
          const count = slots.size;
          slots = new Map(); byText = new WeakMap(); byAttr = new WeakMap(); watching = false;
          delete window.__oreeTr;
          return count;
        },
      };
    })();
    """#

    static func call(_ expression: String) -> String { source + "\nreturn __oreeTr." + expression + ";" }
}
