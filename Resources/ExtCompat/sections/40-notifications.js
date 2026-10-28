/* chrome.notifications (notifications du système) et les petits manques de chrome.action. */
(function () {
  const N = native;
  const TemplateType = { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' };
  extend('notifications', {
    TemplateType, PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
    create: api(async (a, b) => { const id = typeof a === 'string' ? a : ''; const options = typeof a === 'string' ? b : a; if (!options) throw new Error('Notification options are required.'); return N('notifications.create', { id, options }); }),
    update: api((id, options) => N('notifications.update', { id, options })),
    clear: api((id) => N('notifications.clear', { id })),
    getAll: api(() => N('notifications.getAll')),
    getPermissionLevel: api(() => N('notifications.getPermissionLevel')),
    onClicked: nativeEvent('notifications.onClicked'), onClosed: nativeEvent('notifications.onClosed'), onButtonClicked: nativeEvent('notifications.onButtonClicked'),
    onPermissionLevelChanged: makeEvent(), onShowSettings: makeEvent(),
  });
  /* chrome.action : la couleur du texte de la pastille (WebKit ne l'a pas) */
  if (C.action) {
    const KEY = '__oree.badgeTextColor';
    extend('action', {
      setBadgeTextColor: api(async (d = {}) => { const a = storageArea(); if (a) await a.set({ [KEY]: d.color }); }),
      getBadgeTextColor: api(async () => { const a = storageArea(); const r = a ? await a.get(KEY) : {}; return r[KEY] || [255, 255, 255, 255]; }),
    });
  }
})();
