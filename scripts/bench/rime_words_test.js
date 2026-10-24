// Les familles de rimes de « La Rime » : chaque mot de la liste doit retomber dans sa propre famille, et le dictionnaire répond.
const { FAMILIES, FILLERS, familyOf, rhymesFor } = require(require('path').join(__dirname, '../../Resources/Rime/words.js'));
let bad = 0;
const seen = new Map();
for (const f of FAMILIES) for (const w of f.words) {
  const g = familyOf(w); if (!g || g.id !== f.id) { bad++; console.log('mot mal classé :', w, 'dans', f.id, '→', g && g.id); }
  const k = w.toLowerCase(); if (seen.has(k) && seen.get(k) !== f.id) { bad++; console.log('mot dans deux familles :', w, seen.get(k), f.id); } seen.set(k, f.id);
}
for (const [mot, voulu] of [['maison', 'raison'], ['soir', 'espoir'], ['cœur', 'peur'], ['regret', 'secret']]) if (!rhymesFor(mot).includes(voulu)) { bad++; console.log('dictionnaire :', mot, 'devrait donner', voulu); }
if (rhymesFor('xyzqw').length) { bad++; console.log('un mot inconnu ne devrait rien donner'); }
const shortWords = FAMILIES.filter((f) => f.words.filter((w) => w.length <= 12 && !w.includes(' ')).length < 4);
if (shortWords.length) { bad++; console.log('familles sans 4 mots utilisables :', shortWords.map((f) => f.id).join(', ')); }
console.log(FAMILIES.length, 'familles,', FAMILIES.reduce((n, f) => n + f.words.length, 0), 'mots,', FILLERS.length, 'débuts de phrase,', bad, 'problème(s)');
{ const { STORIES, syl } = require(require('path').join(__dirname, '../../Resources/Rime/words.js')); let b = 0;
  for (const s of STORIES) { if (s.lines.length !== 8) b++; for (const l of s.lines) if (l.length !== 4 || syl(l[3]) < 1 || l.some((c) => c.length > 40)) b++; }
  console.log(STORIES.length, 'histoires,', b, 'problème(s)'); }
