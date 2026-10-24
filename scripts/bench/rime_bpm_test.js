const { detectBpm } = require(require('path').join(__dirname, '../../Resources/Rime/bpm.js'));
function synth(bpm, seconds, offset, sr = 44100, swing = 0) {
  const x = new Float32Array(sr * seconds), beat = 60 / bpm; let seed = 1; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const add = (t, f, len, amp, noise) => { const s0 = Math.floor(t * sr); for (let i = 0; i < len * sr && s0 + i < x.length; i++) { const e = Math.exp(-i / sr * (noise ? 60 : 18)); x[s0 + i] += amp * e * (noise ? rnd() * 2 - 1 : Math.sin(2 * Math.PI * (f * (1 + 2 * Math.exp(-i / sr * 30))) * i / sr)); } };
  for (let b = 0; offset + b * beat < seconds - 0.3; b++) { const t = offset + b * beat; if (b % 4 === 0 || b % 4 === 2 && b % 8 === 6) add(t, 55, 0.3, 0.9, false); if (b % 4 === 1 || b % 4 === 3) add(t, 0, 0.15, 0.4, true); add(t + beat / 2 * (1 + swing), 0, 0.04, 0.12, true); }
  return x;
}
let bad = 0;
for (const [bpm, off] of [[90, 0.2], [85, 0], [100, 0.37], [115, 0.1], [75, 0.5], [128, 0.25], [140, 0.05]]) {
  const r = detectBpm(synth(bpm, 30, off), 44100), half = Math.abs(r.bpm * 2 - bpm) < 0.6, ok = Math.abs(r.bpm - bpm) < 0.6 || half, offOk = Math.min(Math.abs(r.offset - off), Math.abs(r.offset - off - 4 * 60 / bpm), Math.abs(r.offset - off + 4 * 60 / bpm)) < 0.05;
  console.log(bpm, '→', r.bpm, 'décalage', r.offset.toFixed(3), 'attendu', off, 'sûr', r.confidence.toFixed(2), ok && offOk ? (half ? 'ok (demi-tempo : le bouton ×2 corrige)' : 'ok') : 'ÉCART'); if (!ok || !offOk) bad++;
}
console.log(bad, 'écart(s)');
