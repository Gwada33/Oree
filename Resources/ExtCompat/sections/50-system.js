/* management, idle, power, system.*, browsingData, search, tts. */
(function () {
  const N = native;
  extend('management', {
    ExtensionDisabledReason: { UNKNOWN: 'unknown', PERMISSIONS_INCREASE: 'permissions_increase' },
    ExtensionInstallType: { ADMIN: 'admin', DEVELOPMENT: 'development', NORMAL: 'normal', SIDELOAD: 'sideload', OTHER: 'other' },
    ExtensionType: { EXTENSION: 'extension', HOSTED_APP: 'hosted_app', PACKAGED_APP: 'packaged_app', LEGACY_PACKAGED_APP: 'legacy_packaged_app', THEME: 'theme' },
    LaunchType: { OPEN_AS_REGULAR_TAB: 'OPEN_AS_REGULAR_TAB', OPEN_AS_PINNED_TAB: 'OPEN_AS_PINNED_TAB', OPEN_AS_WINDOW: 'OPEN_AS_WINDOW', OPEN_FULL_SCREEN: 'OPEN_FULL_SCREEN' },
    getAll: api(() => N('management.getAll')),
    get: api((id) => N('management.get', { id })),
    getSelf: api(() => N('management.getSelf')),
    setEnabled: api((id, enabled) => N('management.setEnabled', { id, enabled })),
    uninstall: api((id, options) => N('management.uninstall', { id, options })),
    uninstallSelf: api((options) => N('management.uninstallSelf', { options })),
    getPermissionWarningsById: api(async () => []),
    getPermissionWarningsByManifest: api(async () => []),
    launchApp: unsupported('management.launchApp()'), createAppShortcut: unsupported('management.createAppShortcut()'), setLaunchType: unsupported('management.setLaunchType()'), generateAppForLink: unsupported('management.generateAppForLink()'),
    installReplacementWebApp: unsupported('management.installReplacementWebApp()'),
    onInstalled: nativeEvent('management.onInstalled'), onUninstalled: nativeEvent('management.onUninstalled'), onEnabled: nativeEvent('management.onEnabled'), onDisabled: nativeEvent('management.onDisabled'),
  });
  extend('idle', {
    IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
    queryState: api((interval) => N('idle.queryState', { interval })),
    setDetectionInterval: api((interval) => N('idle.setDetectionInterval', { interval })),
    onStateChanged: nativeEvent('idle.onStateChanged'),
  });
  extend('power', {
    Level: { SYSTEM: 'system', DISPLAY: 'display' },
    requestKeepAwake: api((level) => N('power.requestKeepAwake', { level })),
    releaseKeepAwake: api(() => N('power.releaseKeepAwake')),
  });
  extend('system', {
    cpu: { getInfo: api(() => N('system.cpu.getInfo')) },
    memory: { getInfo: api(() => N('system.memory.getInfo')) },
    storage: { getInfo: api(() => N('system.storage.getInfo')), getAvailableCapacity: api((id) => N('system.storage.getAvailableCapacity', { id })), ejectDevice: unsupported('system.storage.ejectDevice()'), onAttached: makeEvent(), onDetached: makeEvent(), EjectDeviceResultCode: { SUCCESS: 'success', IN_USE: 'in_use', NO_SUCH_DEVICE: 'no_such_device', FAILURE: 'failure' }, StorageUnitType: { FIXED: 'fixed', REMOVABLE: 'removable', UNKNOWN: 'unknown' } },
    display: { getInfo: api(() => N('system.display.getInfo')), getDisplayLayout: api(async () => []), setDisplayProperties: unsupported('system.display.setDisplayProperties()'), setDisplayLayout: unsupported('system.display.setDisplayLayout()'), setMirrorMode: unsupported('system.display.setMirrorMode()'), enableUnifiedDesktop: () => {}, overscanCalibrationStart: () => {}, showNativeTouchCalibration: () => {}, onDisplayChanged: makeEvent() },
  });
  const KINDS = ['AppCache', 'Cache', 'CacheStorage', 'Cookies', 'Downloads', 'FileSystems', 'FormData', 'History', 'IndexedDB', 'LocalStorage', 'Passwords', 'PluginData', 'ServiceWorkers', 'WebSQL'];
  const browsingData = { remove: api((options = {}, dataToRemove = {}) => N('browsingData.remove', { options, dataToRemove })),
    settings: api(async () => ({ options: { since: 0 }, dataToRemove: Object.fromEntries(KINDS.map((k) => [k.charAt(0).toLowerCase() + k.slice(1), false])), dataRemovalPermitted: Object.fromEntries(KINDS.map((k) => [k.charAt(0).toLowerCase() + k.slice(1), true])) })) };
  for (const k of KINDS) browsingData['remove' + k] = api((options = {}) => N('browsingData.remove', { options, dataToRemove: { [k.charAt(0).toLowerCase() + k.slice(1)]: true } }));
  extend('browsingData', browsingData);
  extend('search', { Disposition: { CURRENT_TAB: 'CURRENT_TAB', NEW_TAB: 'NEW_TAB', NEW_WINDOW: 'NEW_WINDOW' }, query: api((info = {}) => N('search.query', info)) });
  /* chrome.tts : la voix du système */
  const handlers = new Map(); let seq = 0;
  nativeEvent('tts.event').addListener((id, event) => { const h = handlers.get(id); if (h) { try { h(event); } catch (e) { console.error(e); } if (event.type === 'end' || event.type === 'interrupted' || event.type === 'error') handlers.delete(id); } });
  extend('tts', {
    EventType: { START: 'start', END: 'end', WORD: 'word', SENTENCE: 'sentence', MARKER: 'marker', INTERRUPTED: 'interrupted', CANCELLED: 'cancelled', ERROR: 'error', PAUSE: 'pause', RESUME: 'resume' },
    VoiceGender: { MALE: 'male', FEMALE: 'female' },
    speak: api((text, options = {}) => { const id = 'tts-' + (++seq); const { onEvent, ...rest } = options; if (typeof onEvent === 'function') handlers.set(id, onEvent); return N('tts.speak', { text, options: rest, id }); }),
    stop: () => { N('tts.stop').catch(() => {}); },
    pause: () => { N('tts.pause').catch(() => {}); },
    resume: () => { N('tts.resume').catch(() => {}); },
    isSpeaking: api(() => N('tts.isSpeaking')),
    getVoices: api(() => N('tts.getVoices')),
    onEvent: makeEvent(), onVoicesChanged: makeEvent(),
  });
})();
