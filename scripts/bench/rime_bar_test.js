// Les mesures générées (histoire / mots, avec ou sans beat) sans navigateur : un faux document suffit, game.js n'y touche que pour l'affichage.
const fs = require('fs'), path = require('path'), vm = require('vm'), dir = path.join(__dirname, '../../Resources/Rime');
const stub = () => new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : k === 'classList' ? { toggle() {}, add() {}, remove() {}, contains: () => false } : k === 'length' ? 0 : k === 'dataset' ? {} : k === 'value' ? '' : stub()), set: () => true, apply: () => stub() });
const doc = { querySelector: stub, querySelectorAll: () => [], addEventListener() {}, createElement: stub, getElementById: stub, body: stub() };
const win = { addEventListener() {}, AudioContext: function () {}, localStorage: { getItem: () => null, setItem() {} } };
const ctx = vm.createContext({ window: win, document: doc, localStorage: win.localStorage, console, Math, requestAnimationFrame() {}, setTimeout, setInterval, clearInterval() {}, Float32Array, Array, Promise, JSON, Number, String, Object });
for (const f of ['words.js', 'bpm.js', 'game.js']) vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8').replace(/if \(typeof module[\s\S]*$/m, ''), ctx, { filename: f });
const R = win.__rime; let bad = 0; const ok = (c, m) => { if (!c) { bad++; console.log('ÉCHEC', m); } };
for (const style of ['histoire', 'mots']) for (const level of ['debutant', 'normal', 'avance', 'expert']) {
  R.state.style = style; R.state.level = level; R.state.syll = 2; R.state.sections = ['beat', 'calme']; R.state.bars = [];
  for (let i = 1; i <= 16; i++) {
    const b = R.bar(i); ok(b.cells.length === 4, `${style}/${level} mesure ${i}: 4 cases`); ok(b.cells[3].length > 1 || b.cells[3] === '…', `${style}/${level} mesure ${i}: une rime`);
    ok(b.calm === (i % 2 === 1), `${style}/${level} mesure ${i}: calme selon la structure`);
    if (b.calm) ok(b.cells[1] === '' && b.cells[2] === '', 'mesure sans beat : une phrase posée sur la 1re case');
  }
}
R.state.style = 'histoire'; R.state.level = 'debutant'; R.state.sections = null; R.state.bars = [];
const a = R.bar(1), c = R.bar(2); ok(a.cells.slice(0, 3).every(Boolean) && c.cells.slice(0, 3).every(Boolean), 'débutant avec beat : 3 morceaux affichés');
console.log(bad ? bad + ' échec(s)' : 'mesures : ok');
