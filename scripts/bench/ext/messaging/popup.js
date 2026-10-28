chrome.runtime.sendMessage('ping', r => { document.getElementById('r').textContent = 'reponse=' + r; });
