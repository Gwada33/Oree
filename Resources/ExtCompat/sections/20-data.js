/* history, bookmarks, topSites, sessions, readingList : les données d'Orée, par le pont. */
(function () {
  const N = native;
  extend('history', {
    search: api((q = {}) => N('history.search', q)),
    getVisits: api((d) => N('history.getVisits', d)),
    addUrl: api((d) => N('history.addUrl', d)),
    deleteUrl: api((d) => N('history.deleteUrl', d)),
    deleteRange: api((r) => N('history.deleteRange', r)),
    deleteAll: api(() => N('history.deleteAll')),
    onVisited: nativeEvent('history.onVisited'), onVisitRemoved: nativeEvent('history.onVisitRemoved'),
  });
  const noFolders = unsupported('Les dossiers de favoris');
  extend('bookmarks', {
    getTree: api(() => N('bookmarks.getTree')),
    getSubTree: api(async (id) => { const tree = await N('bookmarks.getTree'); const find = (n) => (n.id === id ? n : (n.children || []).map(find).find(Boolean)); const hit = tree.map(find).find(Boolean); if (!hit) throw new Error("Can't find bookmark for id."); return [hit]; }),
    getChildren: api((id) => N('bookmarks.getChildren', { id: String(id) })),
    get: api((ids) => (Array.isArray(ids) ? N('bookmarks.get', { ids: ids.map(String) }) : N('bookmarks.get', { id: String(ids) }))),
    getRecent: api((n) => N('bookmarks.getRecent', { numberOfItems: n })),
    search: api((q) => N('bookmarks.search', { query: q })),
    create: api((b = {}) => N('bookmarks.create', b)),
    update: api((id, changes) => N('bookmarks.update', { id: String(id), changes })),
    remove: api((id) => N('bookmarks.remove', { id: String(id) })),
    removeTree: api((id) => N('bookmarks.remove', { id: String(id) })),
    move: noFolders,
    onCreated: nativeEvent('bookmarks.onCreated'), onRemoved: nativeEvent('bookmarks.onRemoved'), onChanged: nativeEvent('bookmarks.onChanged'),
    onMoved: nativeEvent('bookmarks.onMoved'), onChildrenReordered: nativeEvent('bookmarks.onChildrenReordered'), onImportBegan: nativeEvent('bookmarks.onImportBegan'), onImportEnded: nativeEvent('bookmarks.onImportEnded'),
    MAX_WRITE_OPERATIONS_PER_HOUR: 1000000, MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
  });
  extend('topSites', { get: api(() => N('topSites.get')) });
  extend('sessions', {
    MAX_SESSION_RESULTS: 25,
    getRecentlyClosed: api(() => N('sessions.getRecentlyClosed')),
    getDevices: api(() => N('sessions.getDevices')),
    restore: unsupported('sessions.restore()'),
    onChanged: makeEvent(),
  });
  extend('readingList', {
    query: api((info = {}) => N('readingList.query', info)),
    addEntry: api((e) => N('readingList.addEntry', e)),
    removeEntry: api((e) => N('readingList.removeEntry', e)),
    updateEntry: unsupported('readingList.updateEntry()'),
    onEntryAdded: makeEvent(), onEntryRemoved: makeEvent(), onEntryUpdated: makeEvent(),
  });
})();
