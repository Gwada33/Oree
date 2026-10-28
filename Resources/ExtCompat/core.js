/* Orée — compatibilité des extensions Chrome.
   WebKit ne fournit que 16 des ~70 espaces `chrome.*`. Ce script est chargé AVANT tout autre script de l'extension (service worker, page de fond,
   popup, réglages, panneau latéral…) et ajoute ce qui manque. Il n'écrase JAMAIS ce que WebKit fournit déjà.
   Trois sortes d'API :
     - en JavaScript seul (privacy, tabGroups, declarativeContent…) ;
     - par le pont vers l'app (`chrome.runtime.sendNativeMessage('oree', { m, a })`) : history, bookmarks, debugger… ;
     - « honnêtes » : quand Orée ne peut pas le faire, l'appel échoue avec un message clair (jamais un faux succès). */
(function () {
  'use strict';
  const G = globalThis;
  const C = G.chrome || G.browser;
  if (!C || !C.runtime || C.__oreeCompat) return;
  /* requestIdleCallback n'existe pas dans WebKit (ni Safari) et des extensions s'en servent dans leur page de fond. */
  if (typeof G.requestIdleCallback !== 'function' && typeof G.setTimeout === 'function') {
    G.requestIdleCallback = (callback, options) => G.setTimeout(() => callback({ didTimeout: false, timeRemaining: () => 40 }), 1);
    G.cancelIdleCallback = (id) => G.clearTimeout(id);
  }
  const diag = { version: 1, failed: [], defined: [] };
  try { Object.defineProperty(C, '__oreeCompat', { value: diag }); } catch (e) { return; }
  const B = (G.browser && G.browser !== C) ? G.browser : null;

  /* ---------- outils ---------- */
  const NATIVE = 'oree';
  let lastError = null;
  function setLastError(message) {
    lastError = message ? { message: String(message) } : null;
    try { Object.defineProperty(C.runtime, 'lastError', { configurable: true, get: () => lastError }); } catch (e) {}
  }
  /* Une fonction d'API : rappel (style Chrome) ou promesse (style Manifest V3), comme les vraies. */
  function api(impl) {
    return function (...args) {
      let cb = null;
      if (args.length && typeof args[args.length - 1] === 'function') cb = args.pop();
      // Un tour de boucle d'événements avant de répondre, comme le ferait un vrai appel au navigateur : sans cela, une extension qui attend un état en rappelant l'API
      // dans une boucle (await …) ne laisse jamais la main aux minuteurs ni aux événements, et son service worker semble mort.
      const self = this;
      const p = new Promise((resolve, reject) => { setTimeout(() => { try { Promise.resolve(impl.apply(self, args)).then(resolve, reject); } catch (e) { reject(e); } }, 0); });
      if (!cb) return p;
      p.then((v) => { setLastError(null); cb(v); }, (e) => { setLastError(e && e.message || e); try { cb(); } finally { setLastError(null); } });
    };
  }
  function makeEvent() {
    const L = new Set();
    return {
      addListener(f) { if (typeof f === 'function') L.add(f); },
      removeListener(f) { L.delete(f); },
      hasListener(f) { return L.has(f); },
      hasListeners() { return L.size > 0; },
      dispatch(...a) { for (const f of [...L]) { try { f(...a); } catch (e) { console.error(e); } } },
    };
  }
  function define(target, name, value) {
    if (name in target) return false;
    try { Object.defineProperty(target, name, { value, writable: true, configurable: true, enumerable: true }); diag.defined.push(name); return true; }
    catch (e) { diag.failed.push(name); return false; }
  }
  /* Ajoute `members` à l'espace `ns` (créé s'il manque) sans toucher à ce qui existe. */
  function extend(ns, members) {
    for (const root of B ? [C, B] : [C]) {
      if (!(ns in root)) define(root, ns, {});
      const target = root[ns];
      if (!target || typeof target !== 'object') continue;
      for (const k of Object.keys(members)) define(target, k, members[k]);
    }
    return C[ns];
  }
  const shared = {};     // ce que les sections se passent entre elles
  const unsupported = (what) => api(() => { throw new Error(what + " n'est pas disponible dans Orée"); });
  const storageArea = () => (C.storage && C.storage.local) || null;

  /* ---------- le pont vers l'app ---------- */
  function native(method, args) {
    return new Promise((resolve, reject) => {
      if (typeof C.runtime.sendNativeMessage !== 'function') return reject(new Error('pont natif absent'));
      C.runtime.sendNativeMessage(NATIVE, { m: method, a: args || {} }, (reply) => {
        const err = C.runtime.lastError;
        if (err) return reject(new Error(err.message));
        if (!reply) return reject(new Error('pas de réponse de l’app'));
        if (reply.ok) resolve(reply.r); else reject(new Error(reply.e || 'erreur'));
      });
    });
  }
  const events = {};                 // nom d'événement natif → makeEvent()
  const nativeEvent = (name) => events[name] || (events[name] = makeEvent());
  let port = null, retry = 0;
  function connect() {
    if (typeof C.runtime.connectNative !== 'function') return;
    try {
      port = C.runtime.connectNative(NATIVE);
      port.onMessage.addListener((m) => { if (m && m.ev && events[m.ev]) events[m.ev].dispatch(...[].concat(m.d)); });
      port.onDisconnect.addListener(() => { port = null; if (retry < 5) setTimeout(connect, 500 * ++retry); });
    } catch (e) { port = null; }
  }
  connect();
  /* Une application native que l'extension demande (connectNative('com.exemple.hote')) : s'il n'y en a pas, Chrome rend un port qui se déconnecte aussitôt avec une erreur
     (runtime.lastError) ; il ne lance pas d'exception. WebKit, lui, en lance une : l'extension planterait au démarrage. */
  if (typeof C.runtime.connectNative === 'function') {
    const real = C.runtime.connectNative.bind(C.runtime);
    const wrapped = function (name) {
      if (name === NATIVE) return real(name);
      try { return real(name); } catch (e) {
        const onMessage = makeEvent(), onDisconnect = makeEvent();
        const port = { name, onMessage, onDisconnect, postMessage() { throw new Error('Attempting to use a disconnected port object'); }, disconnect() {}, sender: undefined };
        setTimeout(() => { setLastError('Specified native messaging host not found.'); try { onDisconnect.dispatch(port); } finally { setLastError(null); } }, 0);
        return port;
      }
    };
    try { C.runtime.connectNative = wrapped; if (B && B.runtime) B.runtime.connectNative = wrapped; } catch (e) { diag.failed.push('runtime.connectNative'); }
  }

  /* ====== les API ajoutées : voir les sections ci-dessous ====== */
  /* Les erreurs non attrapées de l'extension sont notées côté app (journal des appels du pont : utile pour comprendre pourquoi une extension ne marche pas). */
  try {
    const report = (kind, message, where) => { native('log', { kind, message: String(message).slice(0, 400), where: String(where || '').slice(0, 200) }).catch(() => {}); };
    G.addEventListener('error', (e) => report('erreur', e.message, (e.filename || '') + ':' + (e.lineno || 0)));
    G.addEventListener('unhandledrejection', (e) => report('promesse rejetée', (e.reason && (e.reason.message || e.reason)) || 'inconnue', e.reason && e.reason.stack && e.reason.stack.split('\n')[0]));
  } catch (e) {}
  native('log', { kind: 'démarrage', message: (typeof window === 'undefined' ? 'service worker' : 'page') + ' ' + ((G.location && G.location.pathname) || '') }).catch(() => {});
  // Les sections (sections/NN-nom.js) prennent la place du repère ci-dessous : voir ExtensionCompat.assemble.
  //@@SECTIONS@@
})();
