/* Détection du tempo et du premier temps d'une « prod » (instrumental), sans rien envoyer nulle part.
   Méthode : enveloppe d'énergie → force d'attaque (hausses brusques) → autocorrélation pour le tempo → recherche fine, puis du décalage du premier temps. */
function detectBpm(mono, sampleRate) {
  const target = 11025, ratio = Math.max(1, Math.round(sampleRate / target)), sr = sampleRate / ratio;
  const n = Math.floor(mono.length / ratio), low = new Float32Array(n), full = new Float32Array(n);
  let lp = 0; const a = 1 - Math.exp(-2 * Math.PI * 150 / sr);           // filtre grave (≈150 Hz) : la grosse caisse
  for (let i = 0; i < n; i++) { let s = 0; for (let k = 0; k < ratio; k++) s += mono[i * ratio + k]; s /= ratio; lp += a * (s - lp); low[i] = lp; full[i] = s; }
  const hop = 128, frames = Math.floor(n / hop), onset = new Float32Array(frames), fps = sr / hop;
  let prevLow = 0, prevFull = 0;
  for (let f = 0; f < frames; f++) {
    let el = 0, ef = 0; for (let i = f * hop; i < (f + 1) * hop; i++) { el += low[i] * low[i]; ef += (full[i] - low[i]) * (full[i] - low[i]); }
    el = Math.sqrt(el / hop); ef = Math.sqrt(ef / hop);
    onset[f] = Math.max(0, el - prevLow) * 1.6 + Math.max(0, ef - prevFull); prevLow = el; prevFull = ef;
  }
  // on retire la moyenne locale (≈ 0,5 s) pour que seuls les vrais coups comptent
  const w = Math.round(fps * 0.5), flat = new Float32Array(frames); let run = 0;
  for (let f = 0; f < frames; f++) { run += onset[f]; if (f >= w) run -= onset[f - w]; flat[f] = Math.max(0, onset[f] - run / Math.min(f + 1, w) * 1.2); }
  const at = (x) => { const i = Math.floor(x); if (i < 0 || i + 1 >= frames) return 0; const t = x - i; return flat[i] * (1 - t) + flat[i + 1] * t; };
  // autocorrélation de la force d'attaque : un tempo juste revient à 1, 2, 4 et 8 temps
  const maxLag = Math.ceil((60 / 70) * 8 * fps) + 2, R = new Float32Array(maxLag + 1);
  for (let lag = 1; lag <= maxLag; lag++) { let s = 0; for (let f = 0; f + lag < frames; f++) s += flat[f] * flat[f + lag]; R[lag] = s / Math.max(frames - lag, 1); }
  const r = (x) => { const i = Math.floor(x); if (i < 1 || i + 1 > maxLag) return 0; const t = x - i; return R[i] * (1 - t) + R[i + 1] * t; };
  const score = (bpm) => { const L = (60 / bpm) * fps; let s = 0; for (let k = 1; k <= 8; k++) s += r(k * L) * (k % 2 === 0 ? 1 : 0.6); return s / 8; };
  // 1) grossière, 70–140 BPM (la plage où on rappe ; le bouton ×2 / ÷2 de la page corrige les tempos en double ou demi-temps)
  let bpm = 90, best = -1; for (let b = 70; b <= 140; b += 0.25) { const s = score(b); if (s > best) { best = s; bpm = b; } }
  // 2) fine : ±1,5 BPM au pas de 0,05
  let fine = bpm, fs = -1; for (let b = bpm - 1.5; b <= bpm + 1.5; b += 0.05) { const s = score(b); if (s > fs) { fs = s; fine = b; } }
  bpm = Math.round(fine * 20) / 20;
  // 4) décalage : le premier temps est l'endroit de la première mesure où les coups graves (grosse caisse) sont les plus forts
  const beat = (60 / bpm) * fps, bar = beat * 4; let bestO = 0, bestOS = -1;
  for (let o = 0; o < bar; o += 0.5) { let s = 0; for (let k = 0; o + k * beat < frames - 2; k++) s += at(o + k * beat) * (k % 4 === 0 ? 1.25 : 1); if (s > bestOS) { bestOS = s; bestO = o; } }
  const mean = R.slice(1).reduce((x, y) => x + y, 0) / maxLag || 1;
  return { bpm, offset: bestO / fps, confidence: Math.max(0, Math.min(1, (score(bpm) / mean - 1) / 3)) };
}

/* Structure de la prod, mesure par mesure : « beat » (grosse caisse / basse présentes) ou « calme » (rien de grave : intro, pont, break).
   Sert à poser les mots autrement quand on n'entend pas le beat. Seuil relatif au passage le plus chargé, donc indépendant du volume. */
function analyzeSections(mono, sampleRate, bpm, offset) {
  const bar = 4 * 60 / bpm * sampleRate, start = offset * sampleRate, n = Math.floor((mono.length - start) / bar);
  if (n < 1) return [];
  const a = 1 - Math.exp(-2 * Math.PI * 150 / sampleRate), low = new Float32Array(n); let lp = 0;
  for (let b = 0; b < n; b++) { let e = 0; const i0 = Math.floor(start + b * bar), i1 = Math.floor(start + (b + 1) * bar); for (let i = i0; i < i1; i += 2) { lp += a * 2 * (mono[i] - lp); e += lp * lp; } low[b] = Math.sqrt(e / ((i1 - i0) / 2)); }
  const sorted = [...low].sort((x, y) => x - y), ref = sorted[Math.floor(sorted.length * 0.8)] || 0;
  return Array.from(low, (v) => (v < ref * 0.3 ? 'calme' : 'beat'));
}
if (typeof module !== 'undefined') module.exports = { detectBpm, analyzeSections };
