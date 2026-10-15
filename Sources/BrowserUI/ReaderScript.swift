import WebKit
import BrowserCore

/// Finds the article of the page and rebuilds it from a short list of safe tags (no script, no style, no form, no frame), the way a reader
/// mode must. It scores the page's blocks by the paragraphs of real text they hold (long, few links), keeps the best, and walks it, dropping
/// what is hidden or looks like navigation, ads, comments or sharing. Everything it returns is made with `createElement` and `textContent`.
/// Runs on demand in its own content world; nothing stays in the page.
@MainActor
enum ReaderScript {
    static let world = WKContentWorld.world(name: "oree-reader")

    static let extract = #"""
    (() => {
      const KEEP = new Set(['P','H1','H2','H3','H4','UL','OL','LI','BLOCKQUOTE','PRE','CODE','FIGURE','FIGCAPTION','IMG','A','STRONG','B','EM','I','BR','TABLE','THEAD','TBODY','TR','TH','TD','SUP','SUB','HR']);
      const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','NAV','ASIDE','FORM','IFRAME','BUTTON','INPUT','SELECT','TEXTAREA','SVG','CANVAS','VIDEO','AUDIO','OBJECT','EMBED','HEADER','FOOTER','DIALOG']);
      const BAD = /(^|[\s_-])(comment|comments|share|sharing|social|footer|nav|navbar|menu|sidebar|promo|advert|ads?|cookie|newsletter|related|recommend|popup|modal|breadcrumb|subscribe|toolbar|paywall|outbrain|taboola)([\s_-]|$)/i;
      const len = e => (e.textContent || '').replace(/\s+/g, ' ').trim().length;
      const linkDensity = e => { let l = 0; e.querySelectorAll('a').forEach(a => { l += len(a); }); return l / (len(e) || 1); };
      const hidden = e => { const s = getComputedStyle(e); return s.display === 'none' || s.visibility === 'hidden' || e.hidden || e.getAttribute('aria-hidden') === 'true'; };
      const labelled = e => BAD.test((e.id || '') + ' ' + (typeof e.className === 'string' ? e.className : ''));

      function score(e) {
        let s = 0;
        e.querySelectorAll('p').forEach(p => { const t = len(p); if (t >= 60 && linkDensity(p) < 0.5) s += Math.min(t, 400) + (p.parentElement === e ? 25 : 0); });
        return s * (1 - Math.min(linkDensity(e), 0.9));
      }
      let best = null, bestScore = 0;
      for (const e of document.querySelectorAll('article, main, [role=main], section, div')) {
        if (labelled(e) && e.tagName !== 'ARTICLE') continue;
        const s = score(e);
        if (s > bestScore) { best = e; bestScore = s; }
      }
      const article = document.querySelector('article');
      if (article && best && article !== best && score(article) >= bestScore * 0.6 && article.contains(best) === false && best.contains(article) === false) best = article;
      if (!best) return JSON.stringify({ html: '', length: 0, title: document.title, byline: '', site: location.hostname });

      const safeURL = (value, base) => { try { const u = new URL(value, base || location.href); return /^https?:$/.test(u.protocol) ? u.href : null; } catch (_) { return null; } };
      let text = 0;
      function build(node, out) {
        for (const child of node.childNodes) {
          if (child.nodeType === 3) { if (child.nodeValue.trim() || out.lastChild) out.appendChild(document.createTextNode(child.nodeValue)); continue; }
          if (child.nodeType !== 1) continue;
          const tag = child.tagName;
          if (SKIP.has(tag) || hidden(child)) continue;
          if (labelled(child) && !KEEP.has(tag)) continue;
          if (labelled(child) && len(child) < 400) continue;
          if (!KEEP.has(tag)) { build(child, out); continue; }               // div, span, section…: keep the content, drop the box
          if (tag === 'IMG') {
            const src = safeURL(child.currentSrc || child.src);
            if (!src || (child.naturalWidth && child.naturalWidth < 180) || (child.width && child.width < 120)) continue;
            const img = document.createElement('img'); img.src = src; img.alt = child.alt || ''; out.appendChild(img); continue;
          }
          if (tag === 'A') {
            const href = safeURL(child.getAttribute('href'));
            const a = document.createElement(href ? 'a' : 'span'); if (href) { a.href = href; a.rel = 'noopener noreferrer'; }
            build(child, a); if (a.textContent.trim()) out.appendChild(a); continue;
          }
          if (tag === 'BR' || tag === 'HR') { out.appendChild(document.createElement(tag.toLowerCase())); continue; }
          const copy = document.createElement(tag.toLowerCase());
          build(child, copy);
          if (tag === 'FIGURE' ? copy.querySelector('img') : copy.textContent.trim()) {
            if (tag === 'P') text += copy.textContent.length;
            if (tag !== 'P' && !['FIGURE','FIGCAPTION','TABLE','THEAD','TBODY','TR','TH','TD','UL','OL'].includes(tag)) text += copy.textContent.length;
            out.appendChild(copy);
          }
        }
      }
      const root = document.createElement('div');
      build(best, root);

      const meta = n => (document.querySelector(`meta[property="${n}"], meta[name="${n}"]`) || {}).content || '';
      const h1 = best.querySelector('h1') || document.querySelector('h1');
      let title = (h1 && h1.textContent.trim()) || meta('og:title') || document.title || '';
      // The title is shown above the text: do not repeat it as the first heading.
      const first = root.querySelector('h1'); if (first && first.textContent.trim() === title) first.remove();
      const byline = meta('author') || ((document.querySelector('[rel=author], .byline, [itemprop=author]') || {}).textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
      return JSON.stringify({ title: title.slice(0, 300), byline: byline.slice(0, 100), site: meta('og:site_name') || location.hostname.replace(/^www\./, ''), html: root.innerHTML, length: text, text: root.textContent.replace(/\s+/g, ' ').trim().slice(0, 200000), lang: document.documentElement.lang || '' });
    })()
    """#
}
