import WebKit
import BrowserCore

/// Les yeux de l'IA : relève les éléments utiles d'une page et son texte, dans le monde isolé `oree-ai` (la page ne peut pas le voir ni
/// lui parler). Chaque élément reçoit une référence `@eN` gardée dans une table du monde `oree-ai` : le même élément garde sa référence
/// d'une carte à l'autre, tant qu'il reste dans la page. Le tri, le budget et le format sont dans `PageMap` (BrowserCore).
@MainActor
enum PageMapScript {
    static let world = WKContentWorld.world(name: "oree-ai")

    static let survey = """
    const S = window.__oreeAI || (window.__oreeAI = { next: 1, ids: new WeakMap(), refs: new Map(), resolve(n) { const r = this.refs.get(n); return r ? r.deref() || null : null; } });
    const PICK = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch], [contenteditable=""], [contenteditable=true]';
    const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
    const vw = window.innerWidth, vh = window.innerHeight;
    const out = [];
    for (const el of document.querySelectorAll(PICK)) {
      if (out.length >= 400) break;
      if (el.closest('[aria-hidden=true], [hidden]')) continue;
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      const tag = el.tagName.toLowerCase();
      const inputType = tag === 'input' ? (el.type || 'text').toLowerCase() : null;
      const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? (['checkbox', 'radio'].includes(inputType) ? inputType : ['submit', 'button', 'reset', 'image'].includes(inputType) ? 'button' : 'input') : tag === 'summary' ? 'button' : tag);
      let label = el.getAttribute('aria-label');
      if (!label && el.getAttribute('aria-labelledby')) label = el.getAttribute('aria-labelledby').split(' ').map(id => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' ');
      if (!label && el.labels && el.labels.length) label = el.labels[0].textContent;
      if (!label && ['submit', 'button', 'reset'].includes(inputType)) label = el.value;
      if (!label && !['input', 'textarea', 'select'].includes(tag)) label = el.innerText || el.textContent;
      if (!label) label = el.getAttribute('placeholder') || el.getAttribute('title') || (el.querySelector('img[alt]') || {}).alt || el.getAttribute('name') || '';
      let ref = S.ids.get(el);
      if (!ref) { ref = S.next++; S.ids.set(el, ref); S.refs.set(ref, new WeakRef(el)); }
      const attributes = {};
      if (tag === 'a') { try { const u = new URL(el.href, location.href); attributes.href = (u.origin === location.origin ? u.pathname + u.search : u.origin + u.pathname).slice(0, 60); } catch (e) {} }
      if (el.getAttribute('placeholder') && label !== el.getAttribute('placeholder')) attributes.placeholder = el.getAttribute('placeholder');
      if (el.required) attributes.required = '';
      if (el.disabled) attributes.disabled = '';
      if (el.checked) attributes.checked = '';
      if (tag === 'select' && el.selectedOptions[0]) attributes.value = clean(el.selectedOptions[0].textContent);
      else if (['input', 'textarea'].includes(tag) && el.value && !['checkbox', 'radio', 'submit', 'button', 'reset', 'image', 'file'].includes(inputType)) attributes.value = el.value.slice(0, 80);
      out.push({
        ref, role, type: inputType && inputType !== role ? inputType : null, label: clean(label).slice(0, 120),
        visible: r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw && style.opacity !== '0',
        inForm: !!el.closest('form') || ['input', 'select', 'textarea'].includes(tag),
        inNav: !!el.closest('nav, header, footer, [role=navigation]'),
        attributes, hints: [inputType, el.getAttribute('autocomplete'), el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].filter(Boolean),
      });
    }
    const SKIP = 'script, style, noscript, nav, header, footer, aside, form, iframe, svg, button, [role=navigation], [aria-hidden=true], [hidden]';
    const BLOCKS = 'h1, h2, h3, h4, p, li, td, th, figcaption, blockquote, dt, dd, pre';
    const root = document.querySelector('article') || document.querySelector('main, [role=main]') || document.body;
    const blocks = [];
    if (root) for (const el of root.querySelectorAll(BLOCKS)) {
      if (blocks.length >= 200) break;
      if (el.closest(SKIP) || el.querySelector(BLOCKS)) continue;
      const t = clean(el.innerText);
      if (t.length > 2) blocks.push({ tag: el.tagName.toLowerCase(), text: t.slice(0, 400) });
    }
    return { url: location.href, title: document.title, elements: out, blocks };
    """

    /// La carte de la page affichée, ou nil si la page ne répond pas dans les 8 s.
    static func capture(_ web: WKWebView) async -> PageMap? {
        guard let raw = await web.callJSON(survey, world: world, seconds: 8),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return PageMap.decode(data)
    }
}
