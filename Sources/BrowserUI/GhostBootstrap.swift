import Foundation
import WebKit

/// The page-side half of the ghost capture. It runs in the page's own world at document start, in every frame, because it
/// must see things an isolated script cannot: shadow roots created with `mode: "closed"`, and which elements have real
/// event listeners. It keeps those in WeakMaps/WeakSets (no change to the DOM) and exposes one entry point, `capture()`,
/// under a random per-launch name that a page cannot guess.
///
/// `capture()` copies the document into an *inert* document (no custom elements are constructed, no script can run),
/// then rewrites the copy for a JavaScript-less view:
///  - removes scripts, `<noscript>`, `meta refresh`, `<base>`, resource hints;
///  - form state into attributes (never passwords, card numbers, one-time codes or hidden inputs);
///  - scroll offsets in `data-oree-scroll`; interactive elements in `data-oree-live`;
///  - open AND closed shadow roots as declarative `<template shadowrootmode="open">`, nested ones too, with their
///    `<style>` text and adopted style sheets;
///  - `<style>` text from the live CSSOM (rules added with `insertRule`), adopted sheets, cross-origin `<link>` sheets kept;
///  - canvases and videos as `<img>` (data URL when the page can read the pixels; otherwise a numbered placeholder the
///    app fills with a snapshot of the element's rectangle); `blob:` images as data URLs;
///  - iframes as numbered placeholders (WebKit ignores `srcdoc` when scripting is off): the HTML of a same-origin frame
///    travels in its slot, a cross-origin frame is asked to capture itself by the app;
///  - lazy images in the viewport turned eager; CSS animations that already ended switched off, running ones resumed.
@MainActor
enum GhostBootstrap {
    /// Name under which the entry point lives on `window`. Random per launch.
    static let token = "oree_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static let frameHandler = "oreeGhostFrame"
    static let captureCall = "window['\(token)'] ? window['\(token)'].capture() : JSON.stringify({error: 'not installed'})"

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    static let source: String = script.replacingOccurrences(of: "__TOKEN__", with: token)
        .replacingOccurrences(of: "__FRAME_HANDLER__", with: frameHandler)

    private static let script = #"""
    (function () {
      'use strict';
      var TOKEN = '__TOKEN__';
      if (window[TOKEN]) return;
      var closedRoots = new WeakMap(), liveSet = new WeakSet(), canvasKind = new WeakMap();

      // ---- hooks: same behaviour as the originals, plus a note for the capture ----
      var attach = Element.prototype.attachShadow;
      if (attach) Element.prototype.attachShadow = function (init) {
        var root = attach.apply(this, arguments);
        try { if (init && init.mode === 'closed') closedRoots.set(this, root); } catch (e) {}
        return root;
      };
      var LIVE = { click: 1, mousedown: 1, mouseup: 1, pointerdown: 1, pointerup: 1, touchstart: 1, keydown: 1, keyup: 1, input: 1, change: 1, submit: 1, dblclick: 1, contextmenu: 1 };
      var add = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type, listener) {
        try { if (listener && LIVE[type] && this.nodeType === 1) liveSet.add(this); } catch (e) {}
        return add.apply(this, arguments);
      };
      var getContext = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (kind) {
        try { if (!canvasKind.has(this)) canvasKind.set(this, String(kind)); } catch (e) {}
        return getContext.apply(this, arguments);
      };

      // A frame announces itself so the app can ask it to capture itself (cross-origin frames cannot be read from outside).
      if (window !== window.top) {
        try { window.webkit.messageHandlers.__FRAME_HANDLER__.postMessage({ url: location.href }); } catch (e) {}
      }

      var HINT = /(^|\s)(preload|modulepreload|prefetch|dns-prefetch|preconnect|prerender)(\s|$)/;
      var SECRET = /password|cc-|one-time-code/i;
      var MAX_DATA = 1500000;       // an inline image above this is not worth keeping
      var ROLES = /^(button|link|tab|checkbox|radio|switch|menuitem|option|combobox|slider)$/;

      function rulesText(sheet) { var t = ''; for (var k = 0; k < sheet.cssRules.length; k++) t += sheet.cssRules[k].cssText + '\n'; return t; }
      function inView(r, vw, vh) { return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw; }
      function isInteractive(e) {
        var t = e.tagName;
        if (t === 'BUTTON' || t === 'SELECT' || t === 'SUMMARY' || t === 'TEXTAREA') return true;
        if (t === 'INPUT' && e.type !== 'hidden') return true;
        if (typeof e.onclick === 'function') return true;
        var role = e.getAttribute('role');
        return !!(role && ROLES.test(role)) || liveSet.has(e);
      }

      // Replaces `c` (the copy of a canvas/video) with an <img>: inline data when we have it, else a numbered placeholder.
      function mediaImage(e, c, ctx, src, visible, rect) {
        var img = ctx.inert.createElement('img');
        if (!src && visible) {
          var n = ctx.media.length;
          img.setAttribute('data-oree-media', String(n));       // marker first: the app fills it by text replacement
          ctx.media.push({ n: n, x: ctx.ox + rect.left, y: ctx.oy + rect.top, w: rect.width, h: rect.height });
        } else if (src) {
          img.setAttribute('src', src);
        }
        ['id', 'class', 'style'].forEach(function (a) { if (e.hasAttribute(a)) img.setAttribute(a, e.getAttribute(a)); });
        img.setAttribute('width', String(Math.round(rect.width))); img.setAttribute('height', String(Math.round(rect.height)));
        img.setAttribute('alt', '');
        c.replaceWith(img);
      }

      function canvasData(e) {
        try {
          var big = e.width * e.height > 4000000;
          var url = big ? e.toDataURL('image/jpeg', 0.7) : e.toDataURL('image/png');
          return url.length <= MAX_DATA ? url : null;
        } catch (x) { return null; }          // tainted canvas
      }
      function videoData(e, doc) {
        try {
          if (!e.videoWidth || e.readyState < 2) return null;
          var w = Math.min(e.videoWidth, 1280), h = Math.round(w * e.videoHeight / e.videoWidth);
          var cv = doc.createElement('canvas'); cv.width = w; cv.height = h;
          cv.getContext('2d').drawImage(e, 0, 0, w, h);
          var url = cv.toDataURL('image/jpeg', 0.8);
          return url.length <= MAX_DATA ? url : null;
        } catch (x) { return null; }          // cross-origin or protected video
      }
      function blobData(e) {
        try {
          var cv = document.createElement('canvas'); cv.width = e.naturalWidth; cv.height = e.naturalHeight;
          cv.getContext('2d').drawImage(e, 0, 0);
          var url = cv.toDataURL('image/png');
          return url.length <= MAX_DATA ? url : null;
        } catch (x) { return null; }
      }

      // Walks a live element list and its (index-aligned) copy; recurses into shadow roots and same-origin iframes.
      function processTree(liveList, copyList, ctx) {
        var drop = [], vw = ctx.win.innerWidth, vh = ctx.win.innerHeight;
        for (var i = 0; i < liveList.length; i++) {
          var e = liveList[i], c = copyList[i], tag = e.tagName;
          if (tag === 'SCRIPT' || tag === 'NOSCRIPT' || tag === 'BASE') { drop.push(c); continue; }
          if (tag === 'META' && /refresh/i.test(e.getAttribute('http-equiv') || '')) { drop.push(c); continue; }
          if (tag === 'LINK') { if (HINT.test((e.getAttribute('rel') || '').toLowerCase())) drop.push(c); continue; }

          var root = null;
          try { root = e.shadowRoot || closedRoots.get(e) || null; } catch (x) {}
          if (root) addShadow(c, root, ctx);

          if (e.scrollTop || e.scrollLeft) c.setAttribute('data-oree-scroll', Math.round(e.scrollLeft) + ',' + Math.round(e.scrollTop));
          if (isInteractive(e)) c.setAttribute('data-oree-live', '');

          if (tag === 'INPUT') {
            var t = (e.type || '').toLowerCase();
            if (t === 'password' || t === 'hidden' || SECRET.test(e.getAttribute('autocomplete') || '')) { c.setAttribute('value', ''); }
            else if (t === 'checkbox' || t === 'radio') { if (e.checked) c.setAttribute('checked', ''); else c.removeAttribute('checked'); }
            else if (t !== 'file') { c.setAttribute('value', e.value); }
          } else if (tag === 'TEXTAREA') {
            c.textContent = SECRET.test(e.getAttribute('autocomplete') || '') ? '' : e.value;
          } else if (tag === 'SELECT') {
            for (var j = 0; j < e.options.length; j++) { if (e.options[j].selected) c.options[j].setAttribute('selected', ''); else c.options[j].removeAttribute('selected'); }
          } else if (tag === 'IMG') {
            if (e.getAttribute('loading') === 'lazy' && inView(e.getBoundingClientRect(), vw, vh)) c.setAttribute('loading', 'eager');
            var cs = e.currentSrc || e.src || '';
            if (/^blob:/i.test(cs)) { var d = blobData(e); if (d) { c.setAttribute('src', d); c.removeAttribute('srcset'); } }
          } else if (tag === 'STYLE') {
            try { if (e.sheet) c.textContent = rulesText(e.sheet); } catch (x) {}
          } else if (tag === 'CANVAS') {
            var r = e.getBoundingClientRect(), kind = canvasKind.get(e) || '2d', gpu = /webgl|bitmaprenderer|webgpu/i.test(kind);
            mediaImage(e, c, ctx, gpu ? null : canvasData(e), inView(r, vw, vh), r);
          } else if (tag === 'VIDEO') {
            var rv = e.getBoundingClientRect(), vis = inView(rv, vw, vh), data = videoData(e, ctx.doc);
            if (!data && !vis && e.poster) data = e.poster;        // off screen and unreadable: the poster image will do
            mediaImage(e, c, ctx, data, vis, rv);
          } else if (tag === 'IFRAME') {
            frameCopy(e, c, ctx);
          }
        }
        animations(liveList, copyList, ctx);
        drop.forEach(function (n) { n.remove(); });
      }

      function addShadow(host, root, ctx) {
        var t = ctx.inert.createElement('template');
        t.setAttribute('shadowrootmode', 'open');                // closed roots become open in the copy: nobody scripts it
        if (root.delegatesFocus) t.setAttribute('shadowrootdelegatesfocus', '');
        var frag = t.content;
        for (var n = root.firstChild; n; n = n.nextSibling) frag.appendChild(ctx.inert.importNode(n, true));
        processTree(root.querySelectorAll('*'), frag.querySelectorAll('*'), ctx);
        var extra = '';
        try { (root.adoptedStyleSheets || []).forEach(function (s) { extra += rulesText(s); }); } catch (x) {}
        if (extra) { var st = ctx.inert.createElement('style'); st.setAttribute('data-oree-ghost', ''); st.textContent = extra; frag.insertBefore(st, frag.firstChild); }
        host.insertBefore(t, host.firstChild);
      }

      // An iframe becomes a numbered placeholder. WebKit drops `srcdoc` when scripting is off, so the document is not put
      // in the markup: a same-origin frame's HTML travels in its slot, a cross-origin frame is captured by the app asking
      // the frame itself; the app then serves each document through a custom URL scheme.
      function frameCopy(e, c, ctx) {
        var f = ctx.inert.createElement('iframe');
        var n = ctx.frames.length, r = e.getBoundingClientRect();
        f.setAttribute('data-oree-frame', String(n));            // marker first: the app sets `src` by text replacement
        for (var a = 0; a < e.attributes.length; a++) {
          var at = e.attributes[a];
          if (!/^(src|srcdoc|loading|data-oree-frame)$/i.test(at.name) && !/^on/i.test(at.name)) f.setAttribute(at.name, at.value);
        }
        var slot = { n: n, src: e.src || e.getAttribute('src') || '', name: e.name || null, ox: ctx.ox + r.left, oy: ctx.oy + r.top, w: r.width, h: r.height };
        ctx.frames.push(slot);                                    // reserve the number before recursing
        try {
          var d = e.contentDocument;
          if (d && d.documentElement && ctx.depth < 3) {
            var saved = { ox: ctx.ox, oy: ctx.oy };
            ctx.ox += r.left; ctx.oy += r.top; ctx.depth++;
            slot.html = docToHtml(d, ctx);
            ctx.depth--; ctx.ox = saved.ox; ctx.oy = saved.oy;
          }
        } catch (x) { delete slot.html; }
        c.replaceWith(f);
      }

      // CSS animations: finished ones are frozen at their end values, a lone running one resumes where it was.
      function animations(liveList, copyList, ctx) {
        try {
          if (!ctx.anim) {
            ctx.anim = new Map();
            (ctx.doc.getAnimations ? ctx.doc.getAnimations() : []).forEach(function (a) {
              if (typeof CSSAnimation === 'undefined' || !(a instanceof CSSAnimation)) return;
              var t = a.effect && a.effect.target; if (!t) return;
              if (!ctx.anim.has(t)) ctx.anim.set(t, []); ctx.anim.get(t).push(a);
            });
            ctx.animStart = performance.now(); ctx.animOver = false;
          }
          for (var i = 0; i < liveList.length; i++) {
            var el = liveList[i], list = ctx.anim.get(el), c = copyList[i];
            if (!c || !c.style) continue;
            if (list) {
              if (list.every(function (a) { return a.playState === 'finished'; })) {
                var cs = ctx.win.getComputedStyle(el);
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
                c.style.animationDelay = (list[0].effect.getTiming().delay - list[0].currentTime) + 'ms';
              }
            } else {
              // An animation that ended without filling is no longer reported; the element still names it: switch it off.
              // Reading every element's style is the slow part on big pages: stop after 300 ms.
              if ((i & 255) === 0 && performance.now() - ctx.animStart > 300) ctx.animOver = true;
              if (ctx.animOver) continue;
              var an = ctx.win.getComputedStyle(el).animationName;
              if (an && an !== 'none') c.style.animation = 'none';
            }
          }
        } catch (x) {}
      }

      function docToHtml(doc, ctx) {
        var win = doc.defaultView, root = doc.documentElement;
        var inert = doc.implementation.createHTMLDocument('');
        var clone = inert.importNode(root, true);
        var saved = { win: ctx.win, inert: ctx.inert, doc: ctx.doc, anim: ctx.anim };
        ctx.win = win; ctx.inert = inert; ctx.doc = doc; ctx.anim = null;
        processTree(root.querySelectorAll('*'), clone.querySelectorAll('*'), ctx);
        var head = clone.querySelector('head');
        if (head) {
          var extra = '';
          (doc.adoptedStyleSheets || []).forEach(function (s) { try { extra += rulesText(s); } catch (x) {} });
          if (extra) { var st = inert.createElement('style'); st.setAttribute('data-oree-ghost', ''); st.textContent = extra; head.appendChild(st); }
          var base = inert.createElement('base'); base.href = doc.baseURI; head.insertBefore(base, head.firstChild);
          // Style sheets arrive one after the other in the ghost and each change would play as a visible transition.
          var boot = inert.createElement('style'); boot.setAttribute('data-oree-ghost-boot', '');
          boot.textContent = '*,*::before,*::after{transition:none!important}'; head.appendChild(boot);
        }
        var dt = doc.doctype ? new XMLSerializer().serializeToString(doc.doctype) : '';
        var html = dt + clone.outerHTML;
        ctx.win = saved.win; ctx.inert = saved.inert; ctx.doc = saved.doc; ctx.anim = saved.anim;
        return html;
      }

      function capture() {
        try {
          var ctx = { win: window, doc: document, inert: null, anim: null, media: [], frames: [], depth: 0, ox: 0, oy: 0 };
          var html = docToHtml(document, ctx);
          return JSON.stringify({
            v: 2, url: location.href, title: document.title, scrollX: window.scrollX, scrollY: window.scrollY,
            vw: window.innerWidth, vh: window.innerHeight, html: html,
            media: ctx.media, frames: ctx.frames
          });
        } catch (err) { return JSON.stringify({ error: String(err) }); }
      }

      Object.defineProperty(window, TOKEN, { value: { capture: capture }, enumerable: false });
    })();
    """#
}
