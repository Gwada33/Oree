const out = {};
const c = (typeof chrome !== 'undefined') ? chrome : {};
for (const ns of Object.keys(c)) {
  let v; try { v = c[ns]; } catch (e) { continue; }
  if (v && typeof v === 'object') { const k = []; try { for (const m in v) k.push(m); } catch (e) {} out[ns] = k.sort(); } else out[ns] = typeof v;
}
out.__compat = c.__oreeCompat ? { failed: c.__oreeCompat.failed, n: c.__oreeCompat.defined.length } : 'absent';
document.getElementById('t').textContent = JSON.stringify(out);
