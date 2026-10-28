/* API que WebKit n'a pas et qu'Orée ne peut pas rendre (capture d'écran du système, impression, GCM…). On les définit pour que le démarrage de l'extension ne plante pas
   (`chrome.gcm.onMessage.addListener(...)` en tête de fichier), et chaque appel échoue AVEC UN MESSAGE CLAIR : jamais un faux succès. */
(function () {
  function inert(ns, spec) {
    const members = Object.assign({}, spec.values || {});
    for (const m of spec.methods || []) members[m] = unsupported('chrome.' + ns + '.' + m + '()');
    for (const e of spec.events || []) members[e] = makeEvent();
    for (const [m, v] of Object.entries(spec.answers || {})) members[m] = api(async () => (typeof v === 'function' ? v() : v));
    extend(ns, members);
  }
  inert('gcm', { methods: ['register', 'send', 'unregister'], events: ['onMessage', 'onMessagesDeleted', 'onSendError'], values: { MAX_MESSAGE_SIZE: 4096 } });
  let instanceId = null;
  inert('instanceID', { methods: ['getToken'], answers: { getID: async () => instanceId || (instanceId = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0')).join('')), getCreationTime: () => 0, deleteToken: undefined, deleteID: undefined }, events: ['onTokenRefresh'] });
  extend('desktopCapture', { chooseDesktopMedia: function (sources, a, b) { const cb = typeof a === 'function' ? a : b; if (cb) setTimeout(() => cb(''), 0); return 0; }, cancelChooseDesktopMedia: () => {} });
  inert('tabCapture', { methods: ['capture', 'captureOffscreenTab', 'getMediaStreamId'], answers: { getCapturedTabs: [] }, events: ['onStatusChanged'] });
  inert('pageCapture', { methods: ['saveAsMHTML'] });
  inert('processes', { methods: ['getProcessIdForTab', 'getProcessInfo', 'terminate'], events: ['onCreated', 'onExited', 'onUnresponsive', 'onUpdated', 'onUpdatedWithMemory'] });
  inert('documentScan', { methods: ['scan', 'getScannerList', 'openScanner', 'getOptionGroups', 'closeScanner', 'setOptions', 'startScan', 'cancelScan', 'readScanData'] });
  inert('printing', { methods: ['getPrinterInfo', 'submitJob', 'cancelJob'], answers: { getPrinters: [] }, events: ['onJobStatusChanged'], values: { MAX_GET_PRINTER_INFO_CALLS_PER_MINUTE: 20, MAX_SUBMIT_JOB_CALLS_PER_MINUTE: 40 } });
  inert('audio', { answers: { getDevices: [] }, methods: ['setActiveDevices', 'setProperties', 'getMute', 'setMute'], events: ['onDeviceListChanged', 'onLevelChanged', 'onMuteChanged'] });
  inert('loginState', { answers: { getProfileType: 'USER_PROFILE', getSessionState: 'UNKNOWN' }, events: ['onSessionStateChanged'], values: { ProfileType: { SIGNIN_PROFILE: 'SIGNIN_PROFILE', USER_PROFILE: 'USER_PROFILE', LOCK_PROFILE: 'LOCK_PROFILE' } } });
  inert('dns', { methods: ['resolve'] });
  inert('ttsEngine', { answers: { updateVoices: undefined }, events: ['onSpeak', 'onStop', 'onPause', 'onResume', 'onSpeakWithAudioStream', 'onInstallLanguageRequest', 'onLanguageStatusRequest', 'onUninstallLanguageRequest'] });
  inert('platformKeys', { methods: ['selectClientCertificates', 'getKeyPair', 'getKeyPairBySpki', 'verifyTLSServerCertificate'] });
  inert('certificateProvider', { events: ['onCertificatesUpdateRequested', 'onSignatureRequested'], methods: ['setCertificates', 'reportSignature'] });
  inert('webAuthenticationProxy', { methods: ['attach', 'detach', 'completeCreateRequest', 'completeGetRequest', 'completeIsUvpaaRequest'], events: ['onCreateRequest', 'onGetRequest', 'onIsUvpaaRequest', 'onRemoteSessionStateChange', 'onRequestCanceled'] });
  inert('wallpaper', { methods: ['setWallpaper'] });
  inert('vpnProvider', { methods: ['createConfig', 'destroyConfig', 'setParameters', 'sendPacket', 'notifyConnectionStateChanged'], events: ['onPlatformMessage', 'onPacketReceived', 'onConfigRemoved', 'onConfigCreated', 'onUIEvent'] });
  inert('systemLog', { methods: ['add'] });
  /* omnibox : les mots-clés de l'extension ne sont pas branchés sur la barre d'adresse d'Orée (pour l'instant) */
  extend('omnibox', { setDefaultSuggestion: () => {}, onInputStarted: makeEvent(), onInputChanged: makeEvent(), onInputEntered: makeEvent(), onInputCancelled: makeEvent(), onDeleteSuggestion: makeEvent(), DescriptionStyleType: { URL: 'url', MATCH: 'match', DIM: 'dim' }, OnInputEnteredDisposition: { CURRENT_TAB: 'currentTab', NEW_FOREGROUND_TAB: 'newForegroundTab', NEW_BACKGROUND_TAB: 'newBackgroundTab' } });
})();
