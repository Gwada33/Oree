/* chrome.declarativeContent : « montrer l'icône de l'extension seulement sur ces pages ». Règles gardées, évaluées à chaque navigation
   (conditions sur l'adresse ; PageStateMatcher + ShowAction / SetIcon / DisableAction). Les conditions `css` (sélecteurs) ne sont pas évaluées. */
(function () {
  const KEY = '__oree.declarativeContent';
  const rules = []; let loaded = false;
  async function load() { if (loaded) return; loaded = true; const a = storageArea(); if (!a) return; const r = await a.get(KEY); (r[KEY] || []).forEach((x) => rules.push(x)); }
  async function save() { const a = storageArea(); if (a) await a.set({ [KEY]: rules }); }
  function matchUrl(c, url) {
    if (!c) return true;
    let u; try { u = new URL(url); } catch (e) { return false; }
    const tests = {
      hostContains: (v) => u.hostname.includes(v), hostEquals: (v) => u.hostname === v, hostPrefix: (v) => u.hostname.startsWith(v), hostSuffix: (v) => u.hostname.endsWith(v),
      pathContains: (v) => u.pathname.includes(v), pathEquals: (v) => u.pathname === v, pathPrefix: (v) => u.pathname.startsWith(v), pathSuffix: (v) => u.pathname.endsWith(v),
      queryContains: (v) => u.search.slice(1).includes(v), queryEquals: (v) => u.search.slice(1) === v, queryPrefix: (v) => u.search.slice(1).startsWith(v), querySuffix: (v) => u.search.slice(1).endsWith(v),
      urlContains: (v) => url.includes(v), urlEquals: (v) => url === v, urlMatches: (v) => new RegExp(v).test(url), urlPrefix: (v) => url.startsWith(v), urlSuffix: (v) => url.endsWith(v),
      originAndPathMatches: (v) => new RegExp(v).test(u.origin + u.pathname), schemes: (v) => v.includes(u.protocol.slice(0, -1)), ports: (v) => v.some((p) => Array.isArray(p) ? (Number(u.port) >= p[0] && Number(u.port) <= p[1]) : Number(u.port || (u.protocol === 'https:' ? 443 : 80)) === p),
    };
    return Object.keys(c).every((k) => (k in tests ? tests[k](c[k]) : true));
  }
  const matches = (rule, url) => (rule.conditions || []).some((c) => matchUrl(c.pageUrl, url));
  async function evaluate(tabId, url) {
    await load(); if (!rules.length || !C.action) return;
    const hit = rules.filter((r) => matches(r, url));
    const show = hit.some((r) => (r.actions || []).some((a) => a.type === 'ShowAction' || a.instanceType === 'declarativeContent.ShowAction'));
    try { if (show) await C.action.enable(tabId); else await C.action.disable(tabId); } catch (e) {}
  }
  if (C.webNavigation && C.webNavigation.onCommitted) C.webNavigation.onCommitted.addListener((d) => { if (d.frameId === 0) evaluate(d.tabId, d.url); });
  const onPageChanged = Object.assign(makeEvent(), {
    addRules: (list, cb) => { const p = (async () => { await load(); const out = list.map((r, i) => ({ id: r.id || 'oree-rule-' + (rules.length + i + 1), priority: 100, ...r })); rules.push(...out); await save(); return out; })(); if (cb) p.then(cb); return p; },
    removeRules: (ids, cb) => { const p = (async () => { await load(); for (let i = rules.length - 1; i >= 0; i--) if (!ids || ids.includes(rules[i].id)) rules.splice(i, 1); await save(); })(); if (cb) p.then(() => cb()); return p; },
    getRules: (ids, cb) => { const p = (async () => { await load(); return rules.filter((r) => !ids || ids.includes(r.id)); })(); if (cb) p.then(cb); return p; },
  });
  const action = (type) => function (props) { return Object.assign(this, { type, instanceType: 'declarativeContent.' + type }, props || {}); };
  extend('declarativeContent', {
    onPageChanged,
    PageStateMatcher: function (o) { return Object.assign(this, o || {}, { instanceType: 'declarativeContent.PageStateMatcher' }); },
    ShowAction: action('ShowAction'), DisableAction: action('DisableAction'), SetIcon: action('SetIcon'), ShowPageAction: action('ShowAction'), RequestContentScript: action('RequestContentScript'),
  });
})();
