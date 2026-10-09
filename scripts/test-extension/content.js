// Proves that content scripts run in pages: marks the page and its title.
document.documentElement.setAttribute('data-hb-ext', 'on');
document.title = '[ext] ' + document.title;
chrome.runtime.sendMessage({ type: 'hello', url: location.href }).then(function (reply) {
  document.documentElement.setAttribute('data-hb-ext-reply', reply && reply.ok ? 'ok' : 'none');
}).catch(function () { document.documentElement.setAttribute('data-hb-ext-reply', 'error'); });
