const results = {};
const check = async (name, fn) => { try { results[name] = (await fn()) === true; } catch (e) { results[name] = 'ERR ' + (e && e.message || e); } };
(async () => {
  await check('popup : script de compatibilité présent', () => !!chrome.__oreeCompat);
  await check('privacy.get/set', async () => { const s = chrome.privacy.services.autofillEnabled; await s.set({ value: false }); const v = (await s.get({})).value; await s.clear({}); return v === false; });
  await check('tabs.group + tabGroups', async () => {
    const tabs = await chrome.tabs.query({}); const gid = await chrome.tabs.group({ tabIds: [tabs[0].id] });
    await chrome.tabGroups.update(gid, { title: 'T' }); const g = await chrome.tabGroups.get(gid); await chrome.tabs.ungroup([tabs[0].id]);
    return g.title === 'T' && g.id === gid;
  });
  await check('identity.getRedirectURL', () => chrome.identity.getRedirectURL('x') === 'https://' + chrome.runtime.id + '.chromiumapp.org/x');
  await check('storage.managed', async () => (await chrome.storage.managed.get({ a: 2 })).a === 2);
  await check('runtime.getContexts', async () => Array.isArray(await chrome.runtime.getContexts({})));
  await check('gcm échoue clairement', async () => { try { await chrome.gcm.register(['1']); return false; } catch (e) { return /Orée/.test(e.message); } });
  await check('service worker : API présentes au démarrage', async () => {
    for (let i = 0; i < 30; i++) { const r = (await chrome.storage.local.get('swReport')).swReport; if (r) { results.__sw = r; return r.compat === true && r.privacy === 'object' && r.group === 'function' && r.tabGroups === 'object' && r.privacyValue === true; } await new Promise((r) => setTimeout(r, 200)); }
    return false;
  });
  document.getElementById('t').textContent = JSON.stringify(results);
})();
