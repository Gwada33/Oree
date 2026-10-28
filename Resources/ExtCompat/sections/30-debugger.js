/* chrome.debugger : pilotage d'un onglet avec le protocole de débogage de Chrome (CDP). WebKit n'a pas ce protocole : l'app en traduit les commandes
   les plus utilisées (Runtime.evaluate, Page.captureScreenshot, Page.navigate, Input.dispatchMouseEvent / dispatchKeyEvent / insertText…) en actions sur l'onglet.
   Les commandes qu'elle ne sait pas faire échouent avec un message qui le dit. Quand une extension s'attache, Orée l'affiche (comme la barre jaune de Chrome). */
(function () {
  const attached = new Map();       // tabId → { index, url }
  async function descriptor(target) {
    if (!target || target.tabId === undefined) throw new Error('Seuls les onglets (tabId) peuvent être déboguées dans Orée.');
    const t = await C.tabs.get(target.tabId).catch(() => null);
    if (!t) throw new Error('No tab with given id ' + target.tabId + '.');
    return { tabId: target.tabId, index: t.index, url: t.url || '', windowId: t.windowId };
  }
  extend('debugger', {
    attach: api(async (target, version) => { const d = await descriptor(target); await native('debugger.attach', { target: d, version }); attached.set(d.tabId, d); }),
    detach: api(async (target) => { const d = attached.get(target && target.tabId) || await descriptor(target); await native('debugger.detach', { target: d }); attached.delete(d.tabId); }),
    sendCommand: api(async (target, method, params) => {
      const d = attached.get(target && target.tabId);
      if (!d) throw new Error('Debugger is not attached to the tab with id: ' + (target && target.tabId) + '.');
      const fresh = await C.tabs.get(d.tabId).catch(() => null);      // l'onglet a pu changer de place
      return native('debugger.sendCommand', { target: fresh ? { ...d, index: fresh.index, url: fresh.url || d.url } : d, method, params: params || {} });
    }),
    getTargets: api(async () => {
      const tabs = await C.tabs.query({});
      return tabs.map((t) => ({ type: 'page', id: 'oree-tab-' + t.id, tabId: t.id, title: t.title || '', url: t.url || '', attached: attached.has(t.id), faviconUrl: t.favIconUrl || '' }));
    }),
    onEvent: nativeEvent('debugger.onEvent'),
    onDetach: Object.assign(makeEvent(), {}),
  });
  // Les événements de l'app arrivent avec le tabId d'origine ; un onglet détaché par l'app prévient l'extension.
  nativeEvent('debugger.detached').addListener((source, reason) => { attached.delete(source.tabId); C.debugger.onDetach.dispatch(source, reason); });
  extend('debugger', { Debuggee: {}, DebuggerSession: {}, DetachReason: { TARGET_CLOSED: 'target_closed', CANCELED_BY_USER: 'canceled_by_user', REPLACED_WITH_DEVTOOLS: 'replaced_with_devtools' } });
})();
