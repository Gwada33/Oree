chrome.runtime.onMessage.addListener((m, s, send) => { if (m === 'who-sw') send('sw'); });
