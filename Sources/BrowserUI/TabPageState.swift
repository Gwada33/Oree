import Foundation
import WebKit

/// Page-side helper that lets a tab be put to sleep without losing the user's work:
///  - tells the app when the user typed into a field / editor (`dirty`), so the tab is only ever
///    frozen, never torn down, while it holds unsaved input;
///  - can dump (`collect`) and put back (`restore`) field values and the playing position of a video
///    when a tab has to be torn down anyway.
/// Runs in its own content world so the page cannot see or spoof it. Password fields are never read.
@MainActor
enum TabPageState {
    static let handlerName = "oreeState"
    static let world = WKContentWorld.world(name: "oree-state")

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// `JSON.stringify(...)` of the page's state, or `null`.
    static let collectCall = "JSON.stringify(window.__oreeState ? window.__oreeState.collect() : null)"
    static func restoreCall(json: String) -> String {
        "window.__oreeState && window.__oreeState.restore(\(json)); true"
    }

    private static let source = """
    (function () {
      if (window.__oreeState) return;
      var dirty = false;
      function post(m) { try { window.webkit.messageHandlers.\(handlerName).postMessage(m); } catch (e) {} }
      function isSecret(el) { return el && el.type === 'password'; }
      addEventListener('input', function (e) {
        if (dirty || isSecret(e.target)) return;
        dirty = true; post({ dirty: true });
      }, true);
      function fields() {
        return Array.prototype.slice.call(document.querySelectorAll('input, textarea, select'))
          .filter(function (el) { return ['password', 'hidden', 'file', 'submit', 'button', 'image', 'reset'].indexOf(el.type) < 0; });
      }
      window.__oreeState = {
        collect: function () {
          var out = { fields: [], video: null };
          fields().forEach(function (el, i) {
            var v = (el.type === 'checkbox' || el.type === 'radio') ? el.checked : el.value;
            var base = (el.type === 'checkbox' || el.type === 'radio') ? el.defaultChecked : el.defaultValue;
            if (v === base || v === '' || v === false) return;
            out.fields.push({ i: i, id: el.id || null, name: el.name || null, tag: el.tagName, v: v });
          });
          var vid = document.querySelector('video');
          if (vid && !vid.ended && vid.currentTime > 5) out.video = vid.currentTime;
          return out;
        },
        restore: function (state) {
          if (!state) return;
          var list = fields();
          (state.fields || []).forEach(function (f) {
            var el = (f.id && document.getElementById(f.id)) ||
                     (f.name && document.getElementsByName(f.name)[0]) || list[f.i];
            if (!el || el.tagName !== f.tag || isSecret(el)) return;
            if (typeof f.v === 'boolean') el.checked = f.v; else if (!el.value) el.value = f.v;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          });
          if (state.video) {
            var vid = document.querySelector('video');
            var seek = function () { try { vid.currentTime = state.video; vid.pause(); } catch (e) {} };
            if (vid) { if (vid.readyState > 0) seek(); else vid.addEventListener('loadedmetadata', seek, { once: true }); }
          }
        }
      };
    })();
    """
}

/// Receives the page's "the user typed something" signal and flags the tab that owns that web view.
final class TabPageStateHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { Tab.tabsByWebView.object(forKey: message.webView)?.isDirty = true }
    }
}
