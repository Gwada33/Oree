/* chrome.tabGroups et chrome.tabs.group / ungroup. Orée n'a pas de groupes d'onglets à l'écran : les groupes existent pour l'extension (identifiants,
   titres, couleurs, appartenance), gardés dans storage.local, et l'extension les retrouve comme dans Chrome. */
(function () {
  const NONE = -1, KEY = '__oree.tabGroups';
  const COLORS = { GREY: 'grey', BLUE: 'blue', RED: 'red', YELLOW: 'yellow', GREEN: 'green', PINK: 'pink', PURPLE: 'purple', CYAN: 'cyan', ORANGE: 'orange' };
  const onCreated = makeEvent(), onUpdated = makeEvent(), onMoved = makeEvent(), onRemoved = makeEvent();
  let state = null;     // { next, groups: { id: {id, windowId, title, color, collapsed} }, tabs: { tabId: groupId } }
  async function load() {
    if (state) return state;
    const a = storageArea(); const r = a ? await a.get(KEY) : {};
    state = r[KEY] || { next: 1, groups: {}, tabs: {} };
    return state;
  }
  async function save() { const a = storageArea(); if (a) await a.set({ [KEY]: state }); }
  const publicGroup = (g) => ({ id: g.id, windowId: g.windowId, title: g.title || '', color: g.color || 'grey', collapsed: !!g.collapsed });
  async function windowOf(tabId) { try { const t = await C.tabs.get(tabId); return t && t.windowId; } catch (e) { return undefined; } }

  const tabGroups = {
    TAB_GROUP_ID_NONE: NONE, Color: COLORS,
    get: api(async (id) => { const s = await load(); const g = s.groups[id]; if (!g) throw new Error('No group with id: ' + id + '.'); return publicGroup(g); }),
    query: api(async (q = {}) => {
      const s = await load();
      return Object.values(s.groups).filter((g) => (q.windowId === undefined || q.windowId === g.windowId) && (q.title === undefined || q.title === g.title)
        && (q.color === undefined || q.color === g.color) && (q.collapsed === undefined || q.collapsed === !!g.collapsed)).map(publicGroup);
    }),
    update: api(async (id, props = {}) => {
      const s = await load(); const g = s.groups[id]; if (!g) throw new Error('No group with id: ' + id + '.');
      for (const k of ['title', 'color', 'collapsed']) if (props[k] !== undefined) g[k] = props[k];
      await save(); onUpdated.dispatch(publicGroup(g)); return publicGroup(g);
    }),
    move: api(async (id, props = {}) => { const s = await load(); const g = s.groups[id]; if (!g) throw new Error('No group with id: ' + id + '.'); if (props.windowId !== undefined) g.windowId = props.windowId; await save(); onMoved.dispatch(publicGroup(g)); return publicGroup(g); }),
    onCreated, onUpdated, onMoved, onRemoved,
  };
  extend('tabGroups', tabGroups);

  async function removeEmpty(s) {
    const used = new Set(Object.values(s.tabs));
    for (const id of Object.keys(s.groups)) if (!used.has(Number(id))) { const g = s.groups[id]; delete s.groups[id]; onRemoved.dispatch(publicGroup(g)); }
  }
  extend('tabs', {
    TAB_GROUP_ID_NONE: NONE,
    group: api(async (opts = {}) => {
      const s = await load(); const ids = [].concat(opts.tabIds === undefined ? [] : opts.tabIds);
      if (!ids.length) throw new Error('No tabs specified.');
      let gid = opts.groupId;
      if (gid === undefined) {
        const win = (opts.createProperties && opts.createProperties.windowId) || await windowOf(ids[0]);
        gid = s.next++; s.groups[gid] = { id: gid, windowId: win === undefined ? -1 : win, title: '', color: 'grey', collapsed: false }; onCreated.dispatch(publicGroup(s.groups[gid]));
      } else if (!s.groups[gid]) throw new Error('No group with id: ' + gid + '.');
      for (const t of ids) s.tabs[t] = gid;
      await removeEmpty(s); await save(); return gid;
    }),
    ungroup: api(async (tabIds) => { const s = await load(); for (const t of [].concat(tabIds)) delete s.tabs[t]; await removeEmpty(s); await save(); }),
  });
  // Les onglets décrits par tabs.get / tabs.query portent leur groupId, comme dans Chrome.
  for (const root of B ? [C, B] : [C]) {
    const T = root.tabs; if (!T) continue;
    const tag = async (t) => { if (t && typeof t === 'object' && t.id !== undefined) { const s = await load(); t.groupId = s.tabs[t.id] === undefined ? NONE : s.tabs[t.id]; } return t; };
    for (const name of ['get', 'getCurrent', 'create', 'update', 'duplicate']) {
      const orig = T[name]; if (typeof orig !== 'function' || orig.__oree) continue;
      const wrapped = function (...args) {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const p = Promise.resolve(orig.apply(T, args)).then(tag);
        if (cb) { p.then((t) => cb(t), () => cb()); return; } return p;
      };
      wrapped.__oree = true; try { T[name] = wrapped; } catch (e) { diag.failed.push('tabs.' + name); }
    }
    const q = T.query;
    if (typeof q === 'function' && !q.__oree) {
      const wrapped = function (...args) {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const info = args[0] || {};
        const p = Promise.resolve(q.call(T, ...(info.groupId !== undefined ? [Object.fromEntries(Object.entries(info).filter(([k]) => k !== 'groupId'))] : args)))
          .then(async (list) => { list = await Promise.all((list || []).map(tag)); return info.groupId === undefined ? list : list.filter((t) => t.groupId === info.groupId); });
        if (cb) { p.then((l) => cb(l), () => cb([])); return; } return p;
      };
      wrapped.__oree = true; try { T.query = wrapped; } catch (e) { diag.failed.push('tabs.query'); }
    }
  }
  C.tabs.onRemoved && C.tabs.onRemoved.addListener(async (id) => { const s = await load(); if (id in s.tabs) { delete s.tabs[id]; await removeEmpty(s); await save(); } });
})();
