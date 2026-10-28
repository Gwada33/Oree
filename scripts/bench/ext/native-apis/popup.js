const results = {};
const check = async (name, fn) => { try { const r = await fn(); results[name] = r === true ? true : 'NON ' + JSON.stringify(r).slice(0, 140); } catch (e) { results[name] = 'ERR ' + (e && e.message || e); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rejects = async (p, re) => { try { await p; return 'n\'a pas échoué'; } catch (e) { return re.test(e.message) ? true : e.message; } };
(async () => {
  await check('history : addUrl + search', async () => { await chrome.history.addUrl({ url: 'https://history-test.example/a', title: 'Hist A' }); const r = await chrome.history.search({ text: 'history-test', maxResults: 5 }); return r.length === 1 && r[0].title === 'Hist A' && r[0].visitCount >= 1 || r; });
  await check('history : getVisits', async () => (await chrome.history.getVisits({ url: 'https://history-test.example/a' })).length === 1);
  await check('history : deleteUrl', async () => { await chrome.history.deleteUrl({ url: 'https://history-test.example/a' }); return (await chrome.history.search({ text: 'history-test' })).length === 0; });
  await check('bookmarks : create + search + get', async () => {
    const n = await chrome.bookmarks.create({ title: 'B1', url: 'https://bm.example/' }); const found = await chrome.bookmarks.search('bm.example'); const got = await chrome.bookmarks.get(n.id);
    results.__bm = n.id; return n.url === 'https://bm.example/' && found.length === 1 && got[0].title === 'B1' || [n.url, found.length, JSON.stringify(got)];
  });
  await check('bookmarks : getTree contient le favori', async () => { const t = await chrome.bookmarks.getTree(); return JSON.stringify(t).includes('bm.example'); });
  await check('bookmarks : update', async () => { const u = await chrome.bookmarks.update(results.__bm, { title: 'B2' }); results.__bm = u.id; return u.title === 'B2'; });
  await check('bookmarks : remove', async () => { await chrome.bookmarks.remove(results.__bm); return (await chrome.bookmarks.search('bm.example')).length === 0; });
  await check('bookmarks : dossier refusé clairement', () => rejects(chrome.bookmarks.create({ title: 'Dossier' }), /dossiers/));
  delete results.__bm;
  await check('topSites.get', async () => Array.isArray(await chrome.topSites.get()));
  await check('readingList', async () => { await chrome.readingList.addEntry({ url: 'https://rl.example/', title: 'RL', hasBeenRead: false }); const q = await chrome.readingList.query({ url: 'https://rl.example/' }); await chrome.readingList.removeEntry({ url: 'https://rl.example/' }); return q.length === 1 && (await chrome.readingList.query({ url: 'https://rl.example/' })).length === 0; });
  await check('notifications : create / getAll / clear', async () => { const id = await chrome.notifications.create('n1', { type: 'basic', iconUrl: 'x.png', title: 't', message: 'm' }); const all = await chrome.notifications.getAll(); const cleared = await chrome.notifications.clear('n1'); return id === 'n1' && all.n1 === true && cleared === true; });
  await check('notifications : niveau de permission', async () => ['granted', 'denied'].includes(await chrome.notifications.getPermissionLevel()));
  await check('permission non demandée : refus clair', () => rejects(chrome.sessions.getDevices(), /permission/));
  await check('sidePanel : ouvre une page de l\'extension', async () => {
    await chrome.sidePanel.setOptions({ path: 'panel.html', enabled: true }); await chrome.sidePanel.open({}); await sleep(600);
    const ctx = await chrome.runtime.getContexts({ contextTypes: ['SIDE_PANEL'] }); const reply = await chrome.runtime.sendMessage('who');
    return ctx.length === 1 && reply === 'panel' || [ctx, reply];
  });
  await check('sidePanel : close', async () => { await chrome.sidePanel.close(); return (await chrome.runtime.getContexts({ contextTypes: ['SIDE_PANEL'] })).length === 0; });
  await check('offscreen : create / has / message / close', async () => {
    const before = await chrome.offscreen.hasDocument(); await chrome.offscreen.createDocument({ url: 'off.html', reasons: ['TESTING'], justification: 'essai' }); await sleep(600);
    const has = await chrome.offscreen.hasDocument(); const reply = await chrome.runtime.sendMessage('who-off'); const second = await rejects(chrome.offscreen.createDocument({ url: 'off.html', reasons: ['TESTING'], justification: 'x' }), /single/);
    await chrome.offscreen.closeDocument(); const after = await chrome.offscreen.hasDocument();
    return before === false && has === true && reply === 'offscreen' && second === true && after === false || [before, has, reply, second, after];
  });
  document.getElementById('t').textContent = JSON.stringify(results);
})();
