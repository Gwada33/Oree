import WebKit

/// Clean copy: what a page puts on the clipboard (its fonts, colors, links, hidden junk) is replaced by the text as it reads.
/// Plain text only, on purpose: WebKit rewrites any HTML given to the clipboard and adds explicit default fonts and colors to it,
/// which would override the destination's own style (Notes, Mail, Pages) instead of matching it.
///
/// - A selection that spans several table cells becomes tab-separated text: Numbers and Excel paste it as a real table.
/// - Optionally a quotation gets its source, with a text-fragment link (`#:~:text=`) that Safari-family browsers scroll to and
///   highlight.
/// - A short copy that looks like one postal address is reported to the app, which offers "Ouvrir dans Plans".
///
/// It runs in its own content world, in every frame, and leaves alone anything it cannot do better than the page: copies from
/// fields and editors, pages that handled the copy themselves, selections inside Shadow DOM.
@MainActor
enum CleanCopyScript {
    static let world = WKContentWorld.world(name: "oree-copy")
    static let handlerName = "oreeCopy"

    static func makeUserScript(addSource: Bool) -> WKUserScript {
        WKUserScript(source: source.replacingOccurrences(of: "__ADD_SOURCE__", with: addSource ? "true" : "false"),
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    private static let source = #"""
    (() => {
      const ADD_SOURCE = __ADD_SOURCE__;
      const isMain = window.top === window;
      const oneLine = s => s.replace(/\s+/g, ' ').trim();

      // The cells the selection covers, row by row, when it is a real table selection (two cells or more); else null.
      function tableRows(sel, range, text) {
        const root = range.commonAncestorContainer;
        const el = root.nodeType === 1 ? root : root.parentElement;
        let table = el && el.closest('table');
        if (!table) {
          const found = el ? [...el.querySelectorAll('table')].filter(t => sel.containsNode(t, true)) : [];
          if (found.length !== 1 || oneLine(found[0].innerText || '').length < 0.6 * oneLine(text).length) return null;
          table = found[0];
        }
        const rows = [];
        for (const tr of table.rows) {
          const cells = [];
          for (const cell of tr.cells) {
            const cr = document.createRange(); cr.selectNodeContents(cell);
            let value = null;
            if (cr.collapsed) { if (sel.containsNode(cell, false)) value = ''; }     // an empty cell inside the selection keeps its column
            else {
              const part = range.cloneRange();
              if (part.compareBoundaryPoints(Range.START_TO_START, cr) < 0) part.setStart(cr.startContainer, cr.startOffset);
              if (part.compareBoundaryPoints(Range.END_TO_END, cr) > 0) part.setEnd(cr.endContainer, cr.endOffset);
              if (!part.collapsed) value = oneLine(part.toString());
            }
            if (value !== null) cells.push(value);
          }
          if (cells.length) rows.push(cells);
        }
        return rows.reduce((n, r) => n + r.length, 0) >= 2 ? rows : null;
      }

      // #:~:text=… : the whole quotation if short, else its first and last words.
      function link(text) {
        const enc = s => encodeURIComponent(s).replace(/[-!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
        const t = text.trim(), words = t.split(/\s+/);
        const part = t.length <= 100 && !/\n/.test(t) ? enc(t) : (words.length > 8 ? enc(words.slice(0, 4).join(' ')) + ',' + enc(words.slice(-4).join(' ')) : enc(oneLine(t)));
        return location.href.split('#')[0] + '#:~:text=' + part;
      }

      window.addEventListener('copy', e => {
        try {
          if (e.defaultPrevented || !e.clipboardData) return;                 // the page handled the copy itself
          const a = document.activeElement;
          if (a && (/^(INPUT|TEXTAREA)$/.test(a.tagName) || a.isContentEditable)) return;
          const sel = getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return;
          let text = sel.toString();
          if (!text.trim()) return;
          const range = sel.getRangeAt(0);
          const rows = tableRows(sel, range, text);
          if (rows) text = rows.map(r => r.join('\t')).join('\n');
          const copied = text;
          if (ADD_SOURCE && isMain && !rows && text.trim().length >= 25) {
            text = text.replace(/\s+$/, '') + '\n\n— ' + oneLine(document.title || location.hostname) + ' (' + link(text) + ')';
          }
          e.clipboardData.setData('text/plain', text);
          e.preventDefault();
          if (isMain && !rows && copied.length <= 200 && copied.split('\n').length <= 3) window.webkit.messageHandlers.oreeCopy.postMessage(copied);
        } catch (_) { /* never get in the way of a copy */ }
      }, false);
    })();
    """#
}

/// Receives short copied texts (to spot an address) and tells the tab that owns the web view.
final class CleanCopyMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        MainActor.assumeIsolated { Tab.tabsByWebView.object(forKey: message.webView)?.copiedText(text) }
    }
}
