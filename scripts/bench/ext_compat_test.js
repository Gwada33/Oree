#!/usr/bin/env node
/* Les API ajoutées aux extensions (Resources/ExtCompat) essayées sans navigateur : un faux `chrome` minimal, comme celui de WebKit.
   node scripts/bench/ext_compat_test.js */
const fs = require('fs'), path = require('path'), vm = require('vm');
const dir = path.join(__dirname, '../../Resources/ExtCompat');
const core = fs.readFileSync(path.join(dir, 'core.js'), 'utf8');
const sections = fs.readdirSync(path.join(dir, 'sections')).filter((f) => f.endsWith('.js')).sort().map((f) => fs.readFileSync(path.join(dir, 'sections', f), 'utf8'));
const source = core.replace('//@@SECTIONS@@', () => sections.join('\n'));

let bad = 0, total = 0;
const ok = (c, m) => { total++; if (!c) { bad++; console.log('ÉCHEC', m); } };
const ev = () => { const L = new Set(); return { addListener: (f) => L.add(f), removeListener: (f) => L.delete(f), hasListener: (f) => L.has(f), fire: (...a) => [...L].forEach((f) => f(...a)) }; };

function fakeChrome(extra = {}) {
  const store = {}; const calls = [];
  const tabs = [{ id: 1, windowId: 10, url: 'https://a.test/' }, { id: 2, windowId: 10, url: 'https://b.test/' }, { id: 3, windowId: 11, url: 'https://c.test/' }];
  const chrome = {
    __dnrCalls: [],
    runtime: { id: 'abcdef', getManifest: () => ({}), lastError: undefined },
    storage: { local: {
      get: async (k) => (typeof k === 'string' ? (k in store ? { [k]: JSON.parse(JSON.stringify(store[k])) } : {}) : {}),
      set: async (o) => { for (const k of Object.keys(o)) store[k] = JSON.parse(JSON.stringify(o[k])); },
      remove: async (k) => { delete store[k]; } } },
    tabs: { onRemoved: ev(), onUpdated: ev(), query: async () => tabs.map((t) => ({ ...t })), get: async (id) => ({ ...tabs.find((t) => t.id === id) }),
      create: async (p) => { const t = { id: 99, windowId: 10, url: p.url }; chrome.__created = t; return t; }, remove: async (id) => { calls.push(['tabs.remove', id]); }, update: async () => ({}) },
    webNavigation: { onCommitted: ev() },
    declarativeNetRequest: { updateSessionRules: async (o) => { chrome.__dnrCalls.push(o); }, getSessionRules: async () => [] },
    action: { enable: async (id) => calls.push(['enable', id]), disable: async (id) => calls.push(['disable', id]) },
    windows: { get: async (id) => ({ id }) },
    ...extra,
  };
  return { chrome, calls, store };
}
function boot(extra) {
  const env = fakeChrome(extra);
  const ctx = vm.createContext({ chrome: env.chrome, console, setTimeout, Promise, JSON, Object, Array, Set, Math, Date, Error, URL, RegExp, Function, Number, String, crypto: { getRandomValues: (a) => a.fill(7) }, Request, Headers, fetch: async (r) => ({ headers: r instanceof Request ? Object.fromEntries(r.headers) : {} }) });
  ctx.globalThis = ctx; vm.runInContext(source, ctx, { filename: 'oree-compat.js' });
  return { ...env, ctx };
}
(async () => {
  const { chrome, calls, ctx } = boot();
  ok(Array.isArray(chrome.__oreeCompat.failed) && chrome.__oreeCompat.failed.length === 0, 'aucune définition refusée : ' + JSON.stringify(chrome.__oreeCompat.failed));
  const before = Object.keys(chrome).length;
  vm.runInContext(source, ctx);      // 2e chargement : sans effet
  ok(Object.keys(chrome).length === before, 'idempotent');

  // privacy
  const p = chrome.privacy.network.networkPredictionEnabled;
  ok((await p.get({})).value === true, 'privacy : valeur par défaut');
  let changed = null; p.onChange.addListener((d) => { changed = d; });
  await p.set({ value: false });
  ok((await p.get({})).value === false && changed && changed.value === false, 'privacy : set, get, onChange');
  await p.clear({}); ok((await p.get({})).value === true, 'privacy : clear');
  ok(chrome.privacy.websites.thirdPartyCookiesAllowed && chrome.privacy.services.autofillEnabled, 'privacy : sous-espaces');

  // tabGroups + tabs.group
  const created = []; chrome.tabGroups.onCreated.addListener((g) => created.push(g));
  const gid = await chrome.tabs.group({ tabIds: [1, 2] });
  ok(typeof gid === 'number' && gid > 0 && created.length === 1, 'tabs.group crée un groupe');
  ok((await chrome.tabGroups.get(gid)).windowId === 10, 'tabGroups.get : fenêtre de l’onglet');
  await chrome.tabGroups.update(gid, { title: 'Travail', color: 'blue' });
  ok((await chrome.tabGroups.query({ title: 'Travail' })).length === 1, 'tabGroups.query par titre');
  ok((await chrome.tabs.get(1)).groupId === gid && (await chrome.tabs.get(3)).groupId === -1, 'tabs.get porte groupId');
  ok((await chrome.tabs.query({ groupId: gid })).map((t) => t.id).join() === '1,2', 'tabs.query({groupId})');
  let gone = 0; chrome.tabGroups.onRemoved.addListener(() => gone++);
  await chrome.tabs.ungroup([1]); ok(gone === 0, 'un groupe non vide reste');
  await chrome.tabs.ungroup([2]); ok(gone === 1 && (await chrome.tabGroups.query({})).length === 0, 'groupe vide supprimé');
  let cbResult; await new Promise((r) => chrome.tabGroups.query({}, (v) => { cbResult = v; r(); })); ok(Array.isArray(cbResult), 'style rappel');

  // divers
  ok((await chrome.storage.managed.get({ a: 1 })).a === 1, 'storage.managed.get rend les valeurs par défaut');
  ok(chrome.tabs.TabStatus.COMPLETE === 'complete' && chrome.runtime.ContextType.TAB === 'TAB', 'énumérations');
  ok((await chrome.runtime.requestUpdateCheck()).status === 'no_update', 'requestUpdateCheck');

  // declarativeContent
  await new Promise((r) => chrome.declarativeContent.onPageChanged.addRules([{ conditions: [new chrome.declarativeContent.PageStateMatcher({ pageUrl: { hostSuffix: 'a.test' } })], actions: [new chrome.declarativeContent.ShowAction()] }], r));
  chrome.webNavigation.onCommitted.fire({ frameId: 0, tabId: 1, url: 'https://x.a.test/p' });
  chrome.webNavigation.onCommitted.fire({ frameId: 0, tabId: 2, url: 'https://other.test/' });
  await new Promise((r) => setTimeout(r, 20));
  ok(calls.some((c) => c[0] === 'enable' && c[1] === 1) && calls.some((c) => c[0] === 'disable' && c[1] === 2), 'declarativeContent : ShowAction sur les pages qui correspondent');

  // honnêtes
  let msg = ''; try { await chrome.gcm.register(['1']); } catch (e) { msg = e.message; }
  ok(/gcm\.register.*Orée/.test(msg), 'gcm.register échoue avec un message clair : ' + msg);
  ok((await chrome.printing.getPrinters()).length === 0, 'printing.getPrinters : liste vide');
  let cancelled = null; chrome.desktopCapture.chooseDesktopMedia(['screen'], (id) => { cancelled = id; }); await new Promise((r) => setTimeout(r, 5)); ok(cancelled === '', 'desktopCapture : annulé');
  ok(typeof chrome.gcm.onMessage.addListener === 'function', 'gcm.onMessage existe (le démarrage ne plante pas)');

  // identity
  ok(chrome.identity.getRedirectURL('cb') === 'https://abcdef.chromiumapp.org/cb', 'identity.getRedirectURL');
  const flow = chrome.identity.launchWebAuthFlow({ url: 'https://login.test/auth', interactive: true });
  await new Promise((r) => setTimeout(r, 20));
  ok(chrome.__created && chrome.__created.url === 'https://login.test/auth', 'launchWebAuthFlow ouvre la page de connexion');
  chrome.tabs.onUpdated.fire(99, { url: 'https://abcdef.chromiumapp.org/cb?code=42' }, {});
  ok((await flow) === 'https://abcdef.chromiumapp.org/cb?code=42', 'launchWebAuthFlow rend l’adresse de redirection');
  ok(calls.some((c) => c[0] === 'tabs.remove' && c[1] === 99), 'l’onglet de connexion est refermé');

  // declarativeNetRequest : modifyHeaders retiré de l'appel natif et appliqué à fetch
  await chrome.declarativeNetRequest.updateSessionRules({ addRules: [
    { id: 1, priority: 1, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'x-client', operation: 'set', value: 'oree' }] }, condition: { urlFilter: '||api.test/', resourceTypes: ['xmlhttprequest'] } },
    { id: 2, priority: 1, action: { type: 'block' }, condition: { urlFilter: '||ads.test/' } }] });
  ok(chrome.__dnrCalls[0].addRules.length === 1 && chrome.__dnrCalls[0].addRules[0].id === 2, 'DNR : la règle modifyHeaders n’est pas envoyée à WebKit');
  const hit = await ctx.fetch('https://api.test/v1', { headers: { a: '1' } }), miss = await ctx.fetch('https://other.test/v1');
  ok(hit.headers['x-client'] === 'oree' && hit.headers.a === '1', 'DNR : en-tête ajouté sur api.test : ' + JSON.stringify(hit.headers));
  ok(!('x-client' in miss.headers), 'DNR : rien sur les autres sites');
  ok((await chrome.declarativeNetRequest.getSessionRules()).some((r) => r.id === 1), 'DNR : getSessionRules rend aussi la règle émulée');

  // ne remplace pas ce que WebKit a déjà
  const own = () => 'natif'; const k = boot({ runtime: { id: 'x', restart: own, getManifest: () => ({}) } });
  ok(k.chrome.runtime.restart === own, 'ce que WebKit fournit n’est pas écrasé');

  console.log(bad ? `${bad} échec(s) sur ${total}` : `API ajoutées : ${total} vérifications, ok`);
  process.exit(bad ? 1 : 0);
})();
