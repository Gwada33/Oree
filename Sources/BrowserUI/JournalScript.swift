import WebKit
import BrowserCore

/// La moitié « page » du journal d'événements : elle résume, par petites fenêtres, la façon dont on se sert de la page (déplacements du pointeur, défilement, survol et clic
/// des liens, nombre de touches, forme de la page, temps de chargement). Elle n'envoie JAMAIS de texte de la page, de titre, d'adresse complète ni de touche : un nom de domaine (pour
/// que l'app en fasse une empreinte), des nombres et des mots d'une liste fermée. Tout ce qu'elle envoie est de toute façon reconstruit par l'app (`JournalIngest`).
/// Elle ne tourne ni dans les onglets privés, ni sur les pages protégées, et se tait sur une page qui contient un champ de mot de passe. Monde de contenu à part.
@MainActor
enum JournalScript {
    static let world = WKContentWorld.world(name: "oree-journal")
    static let handlerName = "oreeJournal"

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static let source = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__oreeJournal) return;
      window.__oreeJournal = true;
      const now = () => performance.now();
      let queue = [], timer = 0, muted = false;
      const emit = (e, d) => { if (muted && e !== 'page.shape') return; queue.push({ e, d }); if (queue.length >= 25) flush(); else if (!timer) timer = setTimeout(flush, 2500); };
      function flush() {
        timer = 0;
        if (!queue.length) return;
        const ev = queue; queue = [];
        try { window.webkit.messageHandlers.oreeJournal.postMessage({ ev }); } catch (_) {}
      }
      const vw = () => Math.max(innerWidth, 1), vh = () => Math.max(innerHeight, 1);
      const cell = (v, extent) => Math.max(0, Math.min(9, Math.floor(v / extent * 10)));
      const sinceStart = () => Math.round(now());
      let moves = 0, clicks = 0, keys = 0, maxDepth = 0, visibleSince = document.hidden ? 0 : now(), visibleMs = 0;

      // Pointeur : une fenêtre de 2 s à partir du premier mouvement, jamais la trajectoire.
      let win = null, lastMove = 0, lastX = 0, lastY = 0, lastAngle = null;
      function closePointer() {
        if (!win) return;
        const w = win; win = null;
        if (w.dist < 3) return;                                  // un seul mouvement : rien à résumer
        emit('ptr.window', { dur: Math.round(now() - w.t0), dist: Math.round(w.dist), vmean: w.n ? Math.round(w.vsum / w.n) : 0, vmax: Math.round(w.vmax), pauses: w.pauses, turns: w.turns, dx: Math.round(w.dx), dy: Math.round(w.dy) });
      }
      addEventListener('mousemove', e => {
        const t = now(); moves++;
        if (!win) { win = { t0: t, dist: 0, vsum: 0, n: 0, vmax: 0, pauses: 0, turns: 0, dx: 0, dy: 0 }; lastX = e.clientX; lastY = e.clientY; lastMove = t; lastAngle = null; setTimeout(closePointer, 2000); return; }
        const dx = e.clientX - lastX, dy = e.clientY - lastY, dt = t - lastMove, d = Math.hypot(dx, dy);
        if (dt > 160) win.pauses++;
        if (d >= 3 && dt > 4) {
          const v = d / dt * 1000; win.dist += d; win.vsum += v; win.n++; win.vmax = Math.max(win.vmax, v); win.dx += dx; win.dy += dy;
          if (d >= 12) { const a = Math.atan2(dy, dx); if (lastAngle !== null) { let diff = Math.abs(a - lastAngle); if (diff > Math.PI) diff = 2 * Math.PI - diff; if (diff > Math.PI / 3) win.turns++; } lastAngle = a; }
          lastX = e.clientX; lastY = e.clientY; lastMove = t;
        } else lastMove = t;
      }, { passive: true, capture: true });

      // Liens : survol (durée, si on a cliqué), clic. Le nom d'hôte part pour devenir une empreinte ; rien d'autre du lien.
      const kindOf = a => a.closest('nav,header,footer,aside,[role=navigation]') ? 'nav' : (a.closest('article,main,p,li,[role=main]') ? 'content' : ((a.getAttribute('role') === 'button' || a.className && /btn|button/i.test(String(a.className))) ? 'button' : 'other'));
      let hover = null;
      const hostOf = a => { try { return new URL(a.href, location.href).hostname; } catch (_) { return ''; } };
      function endHover(clicked, e) {
        if (!hover) return;
        const h = hover; hover = null;
        const dwell = Math.round(now() - h.t0);
        if (dwell < 90 && !clicked) return;
        emit('link.hover', { host: h.host, dwell, clicked: !!clicked, gx: h.gx, gy: h.gy, y: Math.min(400, Math.round((h.docY) / 250)), kind: h.kind });
      }
      addEventListener('mouseover', e => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) { if (hover) endHover(false, e); return; }
        if (hover && hover.a === a) return;
        endHover(false, e);
        const host = hostOf(a); if (!host) return;
        hover = { a, host, t0: now(), gx: cell(e.clientX, vw()), gy: cell(e.clientY, vh()), docY: e.clientY + scrollY, kind: kindOf(a) };
      }, { passive: true, capture: true });
      addEventListener('mouseout', e => { if (hover && !(e.relatedTarget && hover.a.contains(e.relatedTarget))) endHover(false, e); }, { passive: true, capture: true });
      addEventListener('click', e => {
        clicks++;
        const t = e.target && e.target.closest ? e.target : null;
        const a = t && t.closest ? t.closest('a[href]') : null;
        const tag = t ? (['a', 'button', 'input', 'select', 'textarea', 'video', 'img'].includes(t.tagName.toLowerCase()) ? t.tagName.toLowerCase() : (a ? 'a' : (t.closest('button') ? 'button' : 'other'))) : 'other';
        emit('ptr.click', { tag, gx: cell(e.clientX, vw()), gy: cell(e.clientY, vh()), since: Math.min(60000, Math.round(now() - lastMove)) });
        if (a) {
          const dwell = hover && hover.a === a ? Math.round(now() - hover.t0) : 0;
          emit('link.click', { host: hostOf(a), dwell, new: !!(e.metaKey || e.ctrlKey || e.shiftKey), via: e.button === 1 ? 'middle' : ((e.metaKey || e.ctrlKey || e.shiftKey) ? 'modifier' : 'mouse'), gx: cell(e.clientX, vw()), gy: cell(e.clientY, vh()) });
          endHover(true, e);
        }
      }, { passive: true, capture: true });

      // Défilement : fenêtres de 1,5 s (déplacement net, vitesse maximale, changements de sens, profondeur atteinte).
      let sc = null, lastY2 = scrollY;
      function closeScroll() {
        if (!sc) return; const s = sc; sc = null;
        emit('scroll.window', { dur: Math.round(now() - s.t0), dy: Math.round(s.dy), vmax: Math.round(s.vmax), turns: s.turns, depth: maxDepth });
      }
      addEventListener('scroll', () => {
        const t = now(), y = scrollY, d = y - lastY2; lastY2 = y;
        const total = Math.max(document.documentElement.scrollHeight, 1);
        maxDepth = Math.max(maxDepth, Math.min(100, Math.round((y + vh()) / total * 100)));
        if (!sc) { sc = { t0: t, dy: 0, vmax: 0, turns: 0, last: t, dir: 0 }; setTimeout(closeScroll, 1500); }
        const dt = Math.max(t - sc.last, 1); sc.vmax = Math.max(sc.vmax, Math.abs(d) / dt * 1000); sc.dy += d; sc.last = t;
        const dir = Math.sign(d); if (dir && sc.dir && dir !== sc.dir) sc.turns++; if (dir) sc.dir = dir;
      }, { passive: true, capture: true });

      // Clavier : seulement un compte, par fenêtres de 3 s ; jamais quelle touche.
      let kw = null;
      function closeKeys() { if (!kw) return; const k = kw; kw = null; emit('key.window', { n: k.n, dur: Math.round(now() - k.t0), in: k.field ? 'field' : 'page' }); }
      addEventListener('keydown', e => {
        keys++;
        const el = document.activeElement, field = !!(el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable));
        if (!kw) { kw = { n: 0, t0: now(), field }; setTimeout(closeKeys, 3000); }
        kw.n++; if (field) kw.field = true;
      }, { passive: true, capture: true });
      addEventListener('focusin', e => {
        const el = e.target; if (!el || el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return;
        const t = (el.type || 'text').toLowerCase();
        if (t === 'password') { muted = true; queue = []; return; }
        emit('field.focus', { kind: ['text', 'search', 'email', 'number'].includes(t) ? t : 'other' });
      }, { passive: true, capture: true });
      document.addEventListener('selectionchange', (() => { let wait = 0; return () => { clearTimeout(wait); wait = setTimeout(() => { const n = String(getSelection() || '').length; if (n > 0) emit('text.select', { len: Math.min(12, 1 + Math.floor(Math.log2(n))), copy: false }); }, 600); }; })());
      document.addEventListener('copy', () => { const n = String(getSelection() || '').length; emit('text.select', { len: n ? Math.min(12, 1 + Math.floor(Math.log2(n))) : 0, copy: true }); }, true);

      // Forme et vitesse de la page, une fois chargée.
      function shape() {
        const q = s => document.querySelectorAll(s).length;
        const password = !!document.querySelector('input[type=password]');
        if (password) { muted = true; queue = []; }
        const len = (document.body && document.body.innerText || '').length;
        const article = !!document.querySelector('article, [itemtype*="Article"]');
        const video = !!document.querySelector('video'), audio = !!document.querySelector('audio');
        const forms = q('form'), links = document.links.length;
        const kind = password || (forms > 0 && q('input:not([type=hidden])') > 3) ? 'form' : (video ? 'video' : (location.pathname === '/' && links > 5 ? 'home' : (/[?&](q|query|search)=/.test(location.search) ? 'search' : (article || len > 3000 ? 'article' : (q('button') > 8 ? 'app' : 'other')))));
        emit('page.shape', { links, buttons: q('button,[role=button]'), inputs: q('input,textarea,select'), forms, images: q('img'), video, audio, tlen: len ? Math.min(12, 1 + Math.floor(Math.log2(len))) : 0, article, password, h: Math.min(600, Math.round(document.documentElement.scrollHeight / 100)), kind });
      }
      let lcp = 0;
      try { new PerformanceObserver(list => { for (const en of list.getEntries()) lcp = Math.round(en.startTime); }).observe({ type: 'largest-contentful-paint', buffered: true }); } catch (_) {}
      function perf() {
        const n = performance.getEntriesByType('navigation')[0]; if (!n) return;
        emit('page.perf', { ttfb: Math.round(n.responseStart), dcl: Math.round(n.domContentLoadedEventEnd), load: Math.round(n.loadEventEnd || n.duration), lcp });
      }
      const onLoaded = () => { shape(); setTimeout(perf, 1500); };
      if (document.readyState === 'complete') onLoaded(); else addEventListener('load', onLoaded, { once: true });

      // Départ de la page : ce qu'on y a fait en résumé.
      let left = false;
      function leave() {
        if (left) return; left = true;
        closePointer(); closeScroll(); closeKeys(); endHover(false);
        if (visibleSince) visibleMs += now() - visibleSince;
        emit('page.leave', { dwell: Math.round(visibleMs / 1000), scroll: maxDepth, clicks, keys, moves });
        flush();
      }
      addEventListener('pagehide', leave);
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) { if (visibleSince) { visibleMs += now() - visibleSince; visibleSince = 0; } closePointer(); closeScroll(); closeKeys(); flush(); }
        else visibleSince = now();
      });
    })();
    """#
}

/// Reçoit les résumés de la page et les confie à l'app (qui les reconstruit : la page n'est pas digne de confiance).
final class JournalMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let body = message.body
        MainActor.assumeIsolated { if let tab = Tab.tabsByWebView.object(forKey: message.webView) { tab.owner?.handleJournal(tab: tab, body: body) } }
    }
}
