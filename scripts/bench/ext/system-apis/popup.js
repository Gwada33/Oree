const results = {};
const check = async (name, fn) => { try { const r = await fn(); results[name] = r === true ? true : 'NON ' + JSON.stringify(r).slice(0, 140); } catch (e) { results[name] = 'ERR ' + (e && e.message || e); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  await check('management.getSelf', async () => { const s = await chrome.management.getSelf(); return s.name === 'Test API système' && s.enabled === true && s.type === 'extension' || s; });
  await check('management.getAll', async () => { const all = await chrome.management.getAll(); return all.length >= 2 && all.some((e) => e.name === 'Test API système') || all.length; });
  await check('management.get d\'un identifiant inconnu : refus', async () => { try { await chrome.management.get('inconnu'); return false; } catch (e) { return /Failed to find/.test(e.message); } });
  await check('idle.queryState', async () => ['active', 'idle', 'locked'].includes(await chrome.idle.queryState(60)));
  await check('power : requestKeepAwake / release', async () => { await chrome.power.requestKeepAwake('system'); await chrome.power.releaseKeepAwake(); return true; });
  await check('system.cpu.getInfo', async () => { const c = await chrome.system.cpu.getInfo(); return c.numOfProcessors > 0 && c.processors.length === c.numOfProcessors || c; });
  await check('system.memory.getInfo', async () => { const m = await chrome.system.memory.getInfo(); return m.capacity > 1e9 && m.availableCapacity > 0 || m; });
  await check('system.storage.getInfo', async () => (await chrome.system.storage.getInfo()).length >= 1);
  await check('system.display.getInfo', async () => { const d = await chrome.system.display.getInfo(); return d.length >= 1 && d[0].bounds.width > 0 || d; });
  await check('browsingData.removeCache', async () => { await chrome.browsingData.removeCache({ since: 0 }); return true; });
  await check('sessions.getRecentlyClosed', async () => Array.isArray(await chrome.sessions.getRecentlyClosed({})));
  await check('tts.getVoices', async () => (await chrome.tts.getVoices()).length > 0);
  await check('tts.speak : événement end', async () => new Promise((resolve) => { chrome.tts.speak('essai', { onEvent: (e) => { if (e.type === 'end') resolve(true); } }); setTimeout(() => resolve('pas d\'événement end'), 3000); }));
  await check('identity.launchWebAuthFlow : redirection interceptée', async () => {
    const base = chrome.identity.getRedirectURL(); const flow = chrome.identity.launchWebAuthFlow({ url: 'https://example.org/login', interactive: true });
    let tab = null; for (let i = 0; i < 30 && !tab; i++) { await sleep(200); tab = (await chrome.tabs.query({})).find((t) => (t.url || '').includes('example.org')); }
    if (!tab) return 'onglet de connexion introuvable';
    await chrome.tabs.update(tab.id, { url: base + 'cb?code=42' });
    const result = await Promise.race([flow, sleep(5000).then(() => 'délai dépassé')]);
    return result === base + 'cb?code=42' || result;
  });
  await check('identity.launchWebAuthFlow : non interactif refusé', async () => { try { await chrome.identity.launchWebAuthFlow({ url: 'https://example.org/', interactive: false }); return false; } catch (e) { return /interaction/i.test(e.message); } });
  await check('downloads.search : liste', async () => Array.isArray(await chrome.downloads.search({})));
  await check('downloads.download : adresse invalide refusée', async () => { try { await chrome.downloads.download({ url: 'file:///etc/hosts' }); return false; } catch (e) { return /Invalid URL/.test(e.message); } });
  document.getElementById('t').textContent = JSON.stringify(results);
})();
