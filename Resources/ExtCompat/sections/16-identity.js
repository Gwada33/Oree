/* chrome.identity : se connecter avec un compte. `launchWebAuthFlow` ouvre la page de connexion dans un onglet et attend la redirection vers
   https://<id>.chromiumapp.org/… ; `getAuthToken` (connexion Google intégrée à Chrome) n'existe pas : l'extension doit utiliser launchWebAuthFlow. */
(function () {
  const redirectBase = () => 'https://' + C.runtime.id + '.chromiumapp.org/';
  const onSignInChanged = makeEvent();
  extend('identity', {
    onSignInChanged,
    AccountStatus: { SYNC: 'SYNC', ANY: 'ANY' },
    getRedirectURL: (path = '') => redirectBase() + String(path).replace(/^\//, ''),
    getProfileUserInfo: api(async () => ({ email: '', id: '' })),
    getAccounts: api(async () => []),
    getAuthToken: api(async () => { throw new Error('getAuthToken() n’est pas disponible dans Orée : utilisez launchWebAuthFlow()'); }),
    removeCachedAuthToken: api(async () => {}),
    clearAllCachedAuthTokens: api(async () => {}),
    launchWebAuthFlow: api(async (details = {}) => {
      if (!details.url) throw new Error('Invalid value for argument 1. Property \'url\': Value must not be null.');
      const base = redirectBase();
      try { return await native('identity.launchWebAuthFlow', { url: details.url, redirectBase: base, interactive: details.interactive !== false }); }
      catch (nativeError) { if (!/pont natif|inconnue/.test(nativeError.message)) throw nativeError; }
      // Repli sans le pont : un onglet, surveillé par webNavigation / tabs.onUpdated.
      if (!C.tabs || !C.tabs.create) throw new Error('Authorization page could not be loaded.');
      return new Promise((resolve, reject) => {
        let tabId = null, done = false;
        const finish = (fn, v) => { if (done) return; done = true; try { C.tabs.onUpdated.removeListener(onUpdated); C.tabs.onRemoved.removeListener(onRemoved); } catch (e) {} if (tabId !== null) C.tabs.remove(tabId).catch(() => {}); fn(v); };
        const onUpdated = (id, change, tab) => { const url = change.url || (tab && tab.url) || ''; if (id === tabId && url.startsWith(base)) finish(resolve, url); };
        const onRemoved = (id) => { if (id === tabId) finish(reject, new Error('The user did not approve access.')); };
        C.tabs.onUpdated.addListener(onUpdated); C.tabs.onRemoved.addListener(onRemoved);
        C.tabs.create({ url: details.url, active: details.interactive !== false }).then((t) => { tabId = t.id; }, (e) => finish(reject, e));
      });
    }),
  });
})();
