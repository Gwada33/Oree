/* chrome.privacy : réglages de confidentialité de Chrome. Orée n'a pas ces réglages : les valeurs sont gardées (pour que l'extension relise ce qu'elle a écrit)
   mais ne changent rien au navigateur. `levelOfControl` le dit honnêtement. */
(function () {
  const DEFAULTS = {
    'network.networkPredictionEnabled': true, 'network.webRTCIPHandlingPolicy': 'default', 'network.globalPrivacyControlEnabled': false,
    'services.autofillAddressEnabled': true, 'services.autofillCreditCardEnabled': true, 'services.autofillEnabled': true, 'services.passwordSavingEnabled': true,
    'services.safeBrowsingEnabled': true, 'services.safeBrowsingExtendedReportingEnabled': false, 'services.searchSuggestEnabled': true,
    'services.spellingServiceEnabled': false, 'services.translationServiceEnabled': true,
    'websites.adMeasurementEnabled': true, 'websites.doNotTrackEnabled': false, 'websites.fledgeEnabled': true, 'websites.hyperlinkAuditingEnabled': true,
    'websites.privacySandboxEnabled': true, 'websites.protectedContentEnabled': true, 'websites.referrersEnabled': true, 'websites.relatedWebsiteSetsEnabled': true,
    'websites.thirdPartyCookiesAllowed': true, 'websites.topicsEnabled': true,
  };
  function setting(path) {
    const key = '__oree.privacy.' + path, onChange = makeEvent();
    const read = async () => { const a = storageArea(); if (!a) return DEFAULTS[path]; const r = await a.get(key); return key in r ? r[key] : DEFAULTS[path]; };
    const details = (value) => ({ value, levelOfControl: 'controllable_by_this_extension' });
    return {
      get: api(async () => details(await read())),
      set: api(async (d) => { const a = storageArea(); if (a) await a.set({ [key]: d.value }); onChange.dispatch(details(d.value)); }),
      clear: api(async () => { const a = storageArea(); if (a) await a.remove(key); onChange.dispatch(details(DEFAULTS[path])); }),
      onChange,
    };
  }
  const group = (prefix) => Object.fromEntries(Object.keys(DEFAULTS).filter((k) => k.startsWith(prefix + '.')).map((k) => [k.slice(prefix.length + 1), setting(k)]));
  extend('privacy', { network: group('network'), services: group('services'), websites: group('websites'), IPHandlingPolicy: { DEFAULT: 'default', DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: 'default_public_and_private_interfaces', DEFAULT_PUBLIC_INTERFACE_ONLY: 'default_public_interface_only', DISABLE_NON_PROXIED_UDP: 'disable_non_proxied_udp' } });
  shared.setting = setting;   // réutilisé par d'autres sections (proxy, accessibilityFeatures…)
})();
