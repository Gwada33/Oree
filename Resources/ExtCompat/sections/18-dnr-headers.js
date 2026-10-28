/* declarativeNetRequest « modifyHeaders » : WebKit refuse les règles qui modifient des en-têtes inconnus ("The header `x-…` is not recognized").
   Ces règles sont retirées de l'appel et appliquées ici, sur les requêtes que l'extension fait elle-même (fetch, XMLHttpRequest) : c'est ce que font
   presque toutes les extensions qui s'en servent (ajouter un en-tête à leurs appels d'API). Les requêtes des pages web ne sont PAS modifiées. */
(function () {
  const dnr = C.declarativeNetRequest;
  if (!dnr || typeof dnr.updateSessionRules !== 'function') return;
  const rulesByKind = { session: new Map(), dynamic: new Map() };
  const isHeaderRule = (r) => r && r.action && r.action.type === 'modifyHeaders';

  const globToRegExp = (filter) => {          // le « urlFilter » de Chrome : | début/fin, || domaine, ^ séparateur, * joker
    let s = filter, start = '', end = '';
    if (s.startsWith('||')) { start = '^[a-z][a-z0-9+.-]*://([^/]*\\.)?'; s = s.slice(2); } else if (s.startsWith('|')) { start = '^'; s = s.slice(1); }
    if (s.endsWith('|')) { end = '$'; s = s.slice(0, -1); }
    const body = s.replace(/[.+?${}()[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\^/g, '([^a-z0-9_.%-]|$)');
    return new RegExp(start + body + end, 'i');
  };
  function matches(rule, url, type) {
    const c = rule.condition || {};
    let u; try { u = new URL(url); } catch (e) { return false; }
    if (c.resourceTypes && !c.resourceTypes.includes(type)) return false;
    if (c.excludedResourceTypes && c.excludedResourceTypes.includes(type)) return false;
    if (!c.resourceTypes && type !== 'xmlhttprequest' && type !== 'other') { /* sans résumé de types : toutes sauf main_frame */ }
    const host = u.hostname;
    const inDomain = (list) => list.some((d) => host === d || host.endsWith('.' + d));
    if (c.requestDomains && !inDomain(c.requestDomains)) return false;
    if (c.excludedRequestDomains && inDomain(c.excludedRequestDomains)) return false;
    if (c.urlFilter && !globToRegExp(c.urlFilter).test(url)) return false;
    if (c.regexFilter) { try { if (!new RegExp(c.regexFilter, c.isUrlFilterCaseSensitive ? '' : 'i').test(url)) return false; } catch (e) { return false; } }
    return true;
  }
  function applyTo(headers, url, type) {
    const all = [...rulesByKind.session.values(), ...rulesByKind.dynamic.values()].filter((r) => matches(r, url, type)).sort((a, b) => (b.priority || 1) - (a.priority || 1));
    let changed = false;
    for (const rule of all) for (const h of rule.action.requestHeaders || []) {
      const name = h.header; changed = true;
      if (h.operation === 'remove') headers.delete(name); else if (h.operation === 'append') headers.append(name, h.value); else headers.set(name, h.value);
    }
    return changed;
  }

  const wrapUpdate = (kind, method, getter) => {
    const original = dnr[method].bind(dnr), originalGet = typeof dnr[getter] === 'function' ? dnr[getter].bind(dnr) : null;
    dnr[method] = api(async (options = {}) => {
      const store = rulesByKind[kind];
      for (const id of options.removeRuleIds || []) store.delete(id);
      const add = options.addRules || [], mine = add.filter(isHeaderRule), rest = add.filter((r) => !isHeaderRule(r));
      for (const r of mine) { if (store.has(r.id) && !(options.removeRuleIds || []).includes(r.id)) throw new Error('Rule with id ' + r.id + ' does not have a unique ID.'); store.set(r.id, r); }
      return original({ ...options, addRules: rest });
    });
    if (originalGet) dnr[getter] = api(async (filter) => { const list = await originalGet(filter); return list.concat([...rulesByKind[kind].values()].filter((r) => !filter || !filter.ruleIds || filter.ruleIds.includes(r.id))); });
  };
  wrapUpdate('session', 'updateSessionRules', 'getSessionRules');
  if (typeof dnr.updateDynamicRules === 'function') wrapUpdate('dynamic', 'updateDynamicRules', 'getDynamicRules');

  if (typeof G.fetch === 'function') {
    const originalFetch = G.fetch.bind(G);
    G.fetch = function (input, init) {
      try {
        if (rulesByKind.session.size + rulesByKind.dynamic.size) {
          const request = new Request(input, init), headers = new Headers(request.headers);
          if (applyTo(headers, request.url, 'xmlhttprequest')) return originalFetch(new Request(request, { headers }));
        }
      } catch (e) { /* tant pis : la requête part sans modification */ }
      return originalFetch(input, init);
    };
  }
  if (typeof G.XMLHttpRequest === 'function') {
    const open = G.XMLHttpRequest.prototype.open, send = G.XMLHttpRequest.prototype.send;
    G.XMLHttpRequest.prototype.open = function (method, url, ...rest) { this.__oreeURL = String(url); return open.call(this, method, url, ...rest); };
    G.XMLHttpRequest.prototype.send = function (body) {
      try { if (this.__oreeURL && rulesByKind.session.size + rulesByKind.dynamic.size) { const h = new Headers(); if (applyTo(h, new URL(this.__oreeURL, G.location && G.location.href).href, 'xmlhttprequest')) h.forEach((v, k) => this.setRequestHeader(k, v)); } } catch (e) {}
      return send.call(this, body);
    };
  }
})();
