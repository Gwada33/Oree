const t = document.getElementById('t'), out = {};
chrome.runtime.sendNativeMessage('oree', { m: 'ping', a: {} }, (r) => {
  out.oneShot = r || ('ERR ' + (chrome.runtime.lastError && chrome.runtime.lastError.message));
  try {
    const port = chrome.runtime.connectNative('oree');
    port.onMessage.addListener((m) => { out.port = m; t.textContent = JSON.stringify(out); });
    port.postMessage({ id: 7, m: 'ping', a: {} });
  } catch (e) { out.portError = String(e); t.textContent = JSON.stringify(out); }
  t.textContent = JSON.stringify(out);
});
