/* Petits manques dans les espaces que WebKit a déjà (runtime, tabs, storage, windows…) et espaces de types. */
(function () {
  /* chrome.runtime */
  extend('runtime', {
    onSuspend: makeEvent(), onSuspendCanceled: makeEvent(), onUpdateAvailable: makeEvent(), onBrowserUpdateAvailable: makeEvent(), onUserScriptConnect: makeEvent(), onUserScriptMessage: makeEvent(),
    requestUpdateCheck: api(async () => ({ status: 'no_update' })),
    restart: api(async () => { throw new Error('restart() n’est pas disponible dans Orée'); }),
    restartAfterDelay: api(async () => { throw new Error('restartAfterDelay() n’est pas disponible dans Orée'); }),
    getContexts: api(async (filter = {}) => {
      const ctx = { contextId: 'oree-' + (C.runtime.id || ''), contextType: (typeof window === 'undefined') ? 'BACKGROUND' : 'TAB', documentUrl: (G.location && G.location.href) || '', frameId: 0, incognito: false, tabId: -1, windowId: -1 };
      const ok = (!filter.contextTypes || filter.contextTypes.includes(ctx.contextType)) && (!filter.documentUrls || filter.documentUrls.includes(ctx.documentUrl));
      return ok ? [ctx] : [];
    }),
    ContextType: { TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS' },
    OnInstalledReason: { INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update' },
    OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
    PlatformArch: { ARM: 'arm', ARM64: 'arm64', X86_32: 'x86-32', X86_64: 'x86-64' },
    PlatformOs: { MAC: 'mac', WIN: 'win', ANDROID: 'android', CROS: 'cros', LINUX: 'linux', OPENBSD: 'openbsd' },
    RequestUpdateCheckStatus: { THROTTLED: 'throttled', NO_UPDATE: 'no_update', UPDATE_AVAILABLE: 'update_available' },
  });
  /* chrome.tabs : enums et anciennes méthodes (Manifest V2) */
  const runScript = (details, tabId) => C.scripting.executeScript({ target: { tabId, allFrames: !!details.allFrames }, ...(details.file ? { files: [details.file] } : { func: new Function(details.code) }) });
  extend('tabs', {
    TabStatus: { UNLOADED: 'unloaded', LOADING: 'loading', COMPLETE: 'complete' },
    WindowType: { NORMAL: 'normal', POPUP: 'popup', PANEL: 'panel', APP: 'app', DEVTOOLS: 'devtools' },
    ZoomSettingsMode: { AUTOMATIC: 'automatic', MANUAL: 'manual', DISABLED: 'disabled' },
    ZoomSettingsScope: { PER_ORIGIN: 'per-origin', PER_TAB: 'per-tab' },
    MutedInfoReason: { USER: 'user', CAPTURE: 'capture', EXTENSION: 'extension' },
    discard: api(async (tabId) => (tabId === undefined ? undefined : C.tabs.get(tabId))),
    highlight: api(async (info) => { const i = [].concat(info.tabs)[0]; const all = await C.tabs.query({ windowId: info.windowId }); const t = all[i]; if (t) await C.tabs.update(t.id, { active: true }); return C.windows.get(info.windowId === undefined ? -2 : info.windowId); }),
    getZoomSettings: api(async () => ({ mode: 'automatic', scope: 'per-origin', defaultZoomFactor: 1 })),
    setZoomSettings: api(async () => {}),
    executeScript: api(async (a, b) => { const tabId = typeof a === 'number' ? a : undefined; const details = typeof a === 'number' ? b : a; const r = await runScript(details || {}, tabId); return (r || []).map((x) => x.result); }),
    insertCSS: api(async (a, b) => { const tabId = typeof a === 'number' ? a : undefined; const d = typeof a === 'number' ? b : a; await C.scripting.insertCSS({ target: { tabId, allFrames: !!d.allFrames }, ...(d.file ? { files: [d.file] } : { css: d.code }) }); }),
    removeCSS: api(async (a, b) => { const tabId = typeof a === 'number' ? a : undefined; const d = typeof a === 'number' ? b : a; await C.scripting.removeCSS({ target: { tabId, allFrames: !!d.allFrames }, ...(d.file ? { files: [d.file] } : { css: d.code }) }); }),
  });
  /* chrome.windows */
  extend('windows', { WindowState: { NORMAL: 'normal', MINIMIZED: 'minimized', MAXIMIZED: 'maximized', FULLSCREEN: 'fullscreen', LOCKED_FULLSCREEN: 'locked-fullscreen' }, onBoundsChanged: makeEvent() });
  /* chrome.storage.managed : les règles d'entreprise (il n'y en a pas) */
  if (C.storage && !('managed' in C.storage)) {
    const managed = { get: api(async (keys) => (keys && typeof keys === 'object' && !Array.isArray(keys) ? { ...keys } : {})), getKeys: api(async () => []), getBytesInUse: api(async () => 0), set: unsupported('storage.managed.set'), remove: unsupported('storage.managed.remove'), clear: unsupported('storage.managed.clear'), onChanged: makeEvent() };
    for (const root of B ? [C, B] : [C]) define(root.storage, 'managed', managed);
    extend('storage', { AccessLevel: { TRUSTED_CONTEXTS: 'TRUSTED_CONTEXTS', TRUSTED_AND_UNTRUSTED_CONTEXTS: 'TRUSTED_AND_UNTRUSTED_CONTEXTS' } });
  }
  /* chrome.extensionTypes, chrome.events, chrome.types */
  extend('extensionTypes', { ImageFormat: { JPEG: 'jpeg', PNG: 'png' }, DocumentLifecycle: { PRERENDER: 'prerender', ACTIVE: 'active', CACHED: 'cached', PENDING_DELETION: 'pending_deletion' }, FrameType: { OUTERMOST_FRAME: 'outermost_frame', FENCED_FRAME: 'fenced_frame', SUB_FRAME: 'sub_frame' }, RunAt: { DOCUMENT_START: 'document_start', DOCUMENT_END: 'document_end', DOCUMENT_IDLE: 'document_idle' }, CSSOrigin: { AUTHOR: 'author', USER: 'user' }, ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' } });
  extend('events', { Event: function () { return makeEvent(); } });
  if (shared.setting) extend('types', { ChromeSetting: function (path) { return shared.setting(path); } });
})();
