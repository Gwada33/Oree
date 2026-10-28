/* chrome.sidePanel (panneau latéral de la fenêtre) et chrome.offscreen (page cachée en arrière-plan). */
(function () {
  const N = native;
  const manifest = (C.runtime.getManifest && C.runtime.getManifest()) || {};
  const defaultPath = manifest.side_panel && manifest.side_panel.default_path;
  const state = { path: defaultPath, enabled: true, openPanelOnActionClick: false };
  extend('sidePanel', {
    setOptions: api(async (o = {}) => { if (o.path !== undefined) state.path = o.path; if (o.enabled !== undefined) state.enabled = o.enabled; await N('sidePanel.setOptions', { path: state.path, enabled: state.enabled, tabId: o.tabId }); }),
    getOptions: api(async () => ({ path: state.path, enabled: state.enabled })),
    setPanelBehavior: api(async (b = {}) => { if (b.openPanelOnActionClick !== undefined) state.openPanelOnActionClick = !!b.openPanelOnActionClick; await N('sidePanel.setPanelBehavior', { openPanelOnActionClick: state.openPanelOnActionClick, path: state.path }); }),
    getPanelBehavior: api(async () => ({ openPanelOnActionClick: state.openPanelOnActionClick })),
    open: api(async (o = {}) => { if (!state.path) throw new Error('No sidePanel path set'); await N('sidePanel.open', { path: state.path, tabId: o.tabId, windowId: o.windowId }); }),
    close: api(async () => { await N('sidePanel.close'); }),
    isOpen: api(() => N('sidePanel.isOpen')),
  });
  // Le panneau latéral ouvert est un contexte de type SIDE_PANEL pour runtime.getContexts.
  shared.contextProviders.push(async (filter) => {
    if (filter.contextTypes && !filter.contextTypes.includes('SIDE_PANEL')) return [];
    return (await N('sidePanel.isOpen')) ? [{ contextId: 'oree-side-panel', contextType: 'SIDE_PANEL', documentUrl: C.runtime.getURL(state.path || ''), frameId: 0, incognito: false, tabId: -1, windowId: -1 }] : [];
  });
  extend('offscreen', {
    Reason: { TESTING: 'TESTING', AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', IFRAME_SCRIPTING: 'IFRAME_SCRIPTING', DOM_SCRAPING: 'DOM_SCRAPING', BLOBS: 'BLOBS', DOM_PARSER: 'DOM_PARSER', USER_MEDIA: 'USER_MEDIA', DISPLAY_MEDIA: 'DISPLAY_MEDIA', WEB_RTC: 'WEB_RTC', CLIPBOARD: 'CLIPBOARD', LOCAL_STORAGE: 'LOCAL_STORAGE', WORKERS: 'WORKERS', BATTERY_STATUS: 'BATTERY_STATUS', MATCH_MEDIA: 'MATCH_MEDIA', GEOLOCATION: 'GEOLOCATION' },
    createDocument: api(async (p = {}) => { if (!p.url) throw new Error("Invalid value for argument 1. Property 'url' is required."); await N('offscreen.create', { url: p.url, reasons: p.reasons || [], justification: p.justification || '' }); }),
    closeDocument: api(async () => { await N('offscreen.close'); }),
    hasDocument: api(() => N('offscreen.has')),
  });
})();
