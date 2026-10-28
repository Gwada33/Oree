// Le service worker (ES module) doit déjà avoir les API ajoutées : le script de compatibilité est chargé avant lui.
const report = { compat: !!chrome.__oreeCompat, privacy: typeof chrome.privacy, group: typeof chrome.tabs.group, tabGroups: typeof chrome.tabGroups, identity: typeof chrome.identity };
try { const v = await chrome.privacy.network.networkPredictionEnabled.get({}); report.privacyValue = v.value; } catch (e) { report.privacyError = String(e); }
await chrome.storage.local.set({ swReport: report });
