/* chrome.webRequest : WebKit ne comprend ni les adresses ws:// / wss:// des filtres ("is an invalid match pattern"), ni l'option « blocking » (une extension ne peut pas
   annuler une requête par ce moyen dans WebKit). On retire ce qui est refusé pour que l'extension démarre ; elle observe les requêtes mais ne peut pas les bloquer
   (les extensions qui bloquent doivent passer par declarativeNetRequest). */
(function () {
  for (const root of B ? [C, B] : [C]) {
  const wr = root.webRequest;
  if (!wr) continue;
  const ok = (pattern) => /^(\*|https?|file|ftp):\/\//i.test(pattern) || pattern === '<all_urls>';
  for (const name of Object.keys(wr)) {
    const ev = wr[name];
    if (!name.startsWith('on') || !ev || typeof ev.addListener !== 'function') continue;
    const original = ev.addListener.bind(ev);
    try {
      ev.addListener = function (callback, filter, extra) {
        const urls = filter && Array.isArray(filter.urls) ? filter.urls.filter(ok) : (filter && filter.urls);
        const cleaned = filter ? { ...filter, urls: urls && urls.length ? urls : ['<all_urls>'] } : filter;
        const spec = Array.isArray(extra) ? extra.filter((x) => x !== 'blocking' && x !== 'asyncBlocking') : extra;
        try { return original(callback, cleaned, spec); } catch (e) { return original(callback, { urls: ['<all_urls>'] }); }
      };
    } catch (e) { diag.failed.push('webRequest.' + name); }
  }
  }
})();
