const results = {};
const check = async (name, fn) => { try { const r = await fn(); results[name] = r === true ? true : 'NON ' + JSON.stringify(r).slice(0, 160); } catch (e) { results[name] = 'ERR ' + (e && e.message || e); } };
(async () => {
  await check('sendNativeMessage : réponse de l\'hôte', async () => { const r = await new Promise((res, rej) => chrome.runtime.sendNativeMessage('com.oree.test_host', { a: 1 }, (x) => { const e = chrome.runtime.lastError; e ? rej(new Error(e.message)) : res(x); })); return r.echo.a === 1 && r.origin === 'chrome-extension://' + chrome.runtime.id + '/' || r; });
  await check('connectNative : échange sur un port', async () => new Promise((resolve) => {
    const port = chrome.runtime.connectNative('com.oree.test_host'); const got = [];
    port.onMessage.addListener((m) => { got.push(m.echo.n); if (got.length === 2) { port.disconnect(); resolve(got.join() === '1,2' || got); } });
    port.postMessage({ n: 1 }); port.postMessage({ n: 2 }); setTimeout(() => resolve('délai : ' + JSON.stringify(got)), 4000);
  }));
  await check('hôte inconnu : erreur claire', async () => new Promise((resolve) => chrome.runtime.sendNativeMessage('com.oree.absent', {}, () => resolve(/not found/.test((chrome.runtime.lastError || {}).message || '') || (chrome.runtime.lastError || {}).message))));
  document.getElementById('t').textContent = JSON.stringify(results);
})();
