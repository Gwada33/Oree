chrome.runtime.onMessage.addListener((m, s, send) => { if (m === 'ping') { chrome.storage.local.set({ last: 'ping' }); send('pong'); } });
