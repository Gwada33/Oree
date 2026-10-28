/* Réglages que Chrome range sous chrome.* mais qu'Orée n'a pas : les valeurs sont gardées et relues, sans effet (levelOfControl le dit). */
(function () {
  const S = shared.setting; if (!S) return;
  extend('accessibilityFeatures', Object.fromEntries(['animationPolicy', 'autoclick', 'caretHighlight', 'cursorColor', 'cursorHighlight', 'dictation', 'focusHighlight', 'highContrast', 'largeCursor', 'screenMagnifier', 'selectToSpeak', 'spokenFeedback', 'stickyKeys', 'switchAccess', 'virtualKeyboard'].map((k) => [k, S('accessibilityFeatures.' + k)])));
  extend('proxy', { settings: S('proxy.settings') });
  extend('fontSettings', {
    getFont: api(async () => ({ fontId: 'Helvetica', levelOfControl: 'controllable_by_this_extension' })), setFont: api(async () => {}), clearFont: api(async () => {}),
    getFontList: api(async () => [{ fontId: 'Helvetica', displayName: 'Helvetica' }, { fontId: 'Times', displayName: 'Times' }, { fontId: 'Menlo', displayName: 'Menlo' }]),
    getDefaultFontSize: api(async () => ({ pixelSize: 16, levelOfControl: 'controllable_by_this_extension' })), setDefaultFontSize: api(async () => {}), clearDefaultFontSize: api(async () => {}),
    getDefaultFixedFontSize: api(async () => ({ pixelSize: 13, levelOfControl: 'controllable_by_this_extension' })), setDefaultFixedFontSize: api(async () => {}), clearDefaultFixedFontSize: api(async () => {}),
    getMinimumFontSize: api(async () => ({ pixelSize: 0, levelOfControl: 'controllable_by_this_extension' })), setMinimumFontSize: api(async () => {}), clearMinimumFontSize: api(async () => {}),
    onFontChanged: makeEvent(), onDefaultFontSizeChanged: makeEvent(), onDefaultFixedFontSizeChanged: makeEvent(), onMinimumFontSizeChanged: makeEvent(),
    FontSizeSetting: {}, GenericFamily: { STANDARD: 'standard', SANSSERIF: 'sansserif', SERIF: 'serif', FIXED: 'fixed', CURSIVE: 'cursive', FANTASY: 'fantasy', MATH: 'math' }, LevelOfControl: { NOT_CONTROLLABLE: 'not_controllable', CONTROLLED_BY_OTHER_EXTENSIONS: 'controlled_by_other_extensions', CONTROLLABLE_BY_THIS_EXTENSION: 'controllable_by_this_extension', CONTROLLED_BY_THIS_EXTENSION: 'controlled_by_this_extension' },
  });
  /* chrome.contentSettings : cookies, images, javascript, location, popups… (gardés, non appliqués) */
  const KEY = '__oree.contentSettings';
  function contentSetting(name) {
    const read = async () => { const a = storageArea(); if (!a) return []; const r = await a.get(KEY); return (r[KEY] && r[KEY][name]) || []; };
    const write = async (v) => { const a = storageArea(); if (!a) return; const r = await a.get(KEY); const all = r[KEY] || {}; all[name] = v; await a.set({ [KEY]: all }); };
    return {
      get: api(async (d) => { const rules = await read(); const hit = rules.find((x) => x.primaryPattern === '<all_urls>' || (d.primaryUrl || '').includes(x.primaryPattern.replace(/\*/g, ''))); return { setting: hit ? hit.setting : 'allow' }; }),
      set: api(async (d) => { const rules = await read(); rules.push({ primaryPattern: d.primaryPattern, secondaryPattern: d.secondaryPattern, setting: d.setting }); await write(rules); }),
      clear: api(async () => { await write([]); }),
      getResourceIdentifiers: api(async () => []),
    };
  }
  extend('contentSettings', Object.assign(Object.fromEntries(['automaticDownloads', 'autoVerify', 'camera', 'clipboard', 'cookies', 'fullscreen', 'images', 'javascript', 'location', 'microphone', 'mouselock', 'notifications', 'plugins', 'popups', 'unsandboxedPlugins'].map((k) => [k, contentSetting(k)])),
    { ContentSetting: {}, CookieControlsMode: {}, MultipleAutomaticDownloadsContentSetting: {}, PpapiBrokerContentSetting: {}, ResourceIdentifier: {}, Scope: { REGULAR: 'regular', INCOGNITO_SESSION_ONLY: 'incognito_session_only' } }));
})();
