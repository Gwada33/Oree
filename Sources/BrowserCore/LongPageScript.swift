import WebKit

/// Experimental: on very long pages made of many similar blocks (feeds, result lists, comment
/// threads), tells WebKit not to lay out or paint the blocks that are far off-screen
/// (`content-visibility: auto`). Measured on a 6 000-item list: about 45 % less page memory
/// and about 58 % faster full relayout.
///
/// It is conservative on purpose: only repeated siblings (30+), tall enough (100 px+), in normal
/// flow, on a page several screens high. It adds one CSS rule per list; blocks keep a typical
/// height until first shown and their real height afterwards (`contain-intrinsic-size: auto`).
/// Known trade-off: the browser also clips anything that overflows a block (e.g. a menu that pops
/// out of a list item), which is why this is opt-in.
public enum LongPageScript {
    @MainActor
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    nonisolated public static let source = """
    (function () {
      'use strict';
      if (window.__hbLongPages) { return; }
      window.__hbLongPages = true;
      const MIN_SIBLINGS = 30, MIN_HEIGHT = 100, MIN_SCREENS = 3, MAX_VISITED = 6000, SAMPLE = 40;
      const handled = new WeakSet();
      let counter = 0;

      function contentHeight(element) {
        const style = getComputedStyle(element);
        if (style.position !== 'static' && style.position !== 'relative') { return 0; }
        if (style.boxSizing === 'border-box') { return element.offsetHeight; }
        // contain-intrinsic-size is the content box: remove padding so the block keeps its height
        return element.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
      }

      // One CSS rule for the whole list (also covers blocks added later by infinite scroll):
      // no per-element work, no observers.
      function process(container) {
        const groups = new Map();
        for (const child of container.children) {
          const key = child.tagName + '|' + child.className;
          if (!groups.has(key)) { groups.set(key, []); }
          groups.get(key).push(child);
        }
        let best = null;
        for (const group of groups.values()) { if (!best || group.length > best.length) { best = group; } }
        if (!best || best.length < MIN_SIBLINGS || handled.has(container)) { return false; }

        const heights = best.slice(0, SAMPLE).map(contentHeight);
        const tall = heights.filter(function (h) { return h >= MIN_HEIGHT; });
        if (tall.length < heights.length * 0.8) { return false; }       // not a list of substantial blocks
        tall.sort(function (a, b) { return a - b; });
        const typical = Math.round(tall[Math.floor(tall.length / 2)]);

        handled.add(container);
        const id = 'l' + (++counter);
        container.setAttribute('data-hb-list', id);
        const first = best[0];
        const classes = Array.prototype.map.call(first.classList, function (c) { return '.' + CSS.escape(c); }).join('');
        const rule = '[data-hb-list="' + id + '"] > ' + first.tagName.toLowerCase() + classes +
          ' { content-visibility: auto; contain-intrinsic-size: auto ' + typical + 'px; }';
        const sheet = document.createElement('style');
        sheet.textContent = rule;
        (document.head || document.documentElement).appendChild(sheet);
        return true;
      }

      function scan() {
        const root = document.body;
        if (!root || document.documentElement.scrollHeight < window.innerHeight * MIN_SCREENS) { return; }
        const queue = [root];
        let visited = 0;
        while (queue.length && visited < MAX_VISITED) {
          const element = queue.shift();
          visited++;
          if (element.children.length >= MIN_SIBLINGS && process(element)) { continue; }   // a list: don't dig inside it
          for (const child of element.children) { queue.push(child); }
        }
      }

      // Pages build their lists after load: look again a few times.
      [300, 2500, 8000].forEach(function (delay) { setTimeout(scan, delay); });
    })();
    """
}
