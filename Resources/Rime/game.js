/* La Rime — le jeu caché d'Orée. Un beat (WebAudio, tout est synthétisé ici), une phrase qui finit sur un mot, une mesure pour y répondre par une rime. */
(function () {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const PREFS_KEY = 'oree.rime.prefs';
  const state = { mode: 'intro', src: 'builtin', bpm: 85, startBpm: 85, level: 'normal', length: 16, family: 'auto', muted: false, paused: false, starting: false, bars: [], total: 16, lastBeat: -1, startedAt: 0 };
  let ac = null, master = null, gridStart = 0, nextStep = 0, beatDur = 60 / 85, timer = null, raf = 0, noiseBuf = null;
  const prod = { buffer: null, name: '', detected: null, offset: 0, nudgeMs: 0, source: null }; // la prod (instrumental) de l'utilisateur, décodée en mémoire
  let previewTimer = null, previewSrc = null;

  /* ---------- forêt (aplats, générée une fois) ---------- */
  (function forest() {
    let seed = 7; const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
    const layer = (cls, base, color, spacing, h0, h1) => {
      let g = `<g class="${cls}" fill="${color}"><rect x="-100" y="${base - 30}" width="2200" height="600"/>`;
      for (let x = -80; x < 2000; x += spacing * (0.6 + rnd() * 0.9)) {
        const h = h0 + rnd() * (h1 - h0), w = 40 + rnd() * 60;
        g += `<path d="M${x - w} ${base} L${x} ${base - h} L${x + w} ${base} Z"/><path d="M${x - w * 0.8} ${base - h * 0.35} L${x} ${base - h * 1.05} L${x + w * 0.8} ${base - h * 0.35} Z"/>`;
      }
      return g + '</g>';
    };
    $('#forest').innerHTML = layer('far', 760, '#141e1a', 70, 150, 300) + layer('mid', 870, '#192721', 100, 220, 420) + layer('near', 1010, '#1f3128', 150, 320, 600) +
      Array.from({ length: 40 }, () => `<circle cx="${rnd() * 1920}" cy="${rnd() * 380}" r="${1 + rnd() * 1.5}" fill="#EEEAE3" opacity="${0.2 + rnd() * 0.4}"/>`).join('');
  })();

  /* ---------- son : un beat tout simple, joué à l'horloge audio ---------- */
  function noise() {
    if (noiseBuf) return noiseBuf;
    noiseBuf = ac.createBuffer(1, ac.sampleRate * 0.5, ac.sampleRate);
    const d = noiseBuf.getChannelData(0); for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    return noiseBuf;
  }
  const env = (g, t, peak, dur) => { g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(peak, t + 0.004); g.gain.exponentialRampToValueAtTime(0.0001, t + dur); };
  function kick(t) { const o = ac.createOscillator(), g = ac.createGain(); o.frequency.setValueAtTime(150, t); o.frequency.exponentialRampToValueAtTime(45, t + 0.13); env(g, t, 0.9, 0.3); o.connect(g).connect(master); o.start(t); o.stop(t + 0.32); }
  function snare(t) { const n = ac.createBufferSource(), f = ac.createBiquadFilter(), g = ac.createGain(), o = ac.createOscillator(), og = ac.createGain(); n.buffer = noise(); f.type = 'highpass'; f.frequency.value = 1800; env(g, t, 0.42, 0.2); n.connect(f).connect(g).connect(master); n.start(t, Math.random() * 0.2); n.stop(t + 0.22); o.frequency.value = 190; env(og, t, 0.3, 0.12); o.connect(og).connect(master); o.start(t); o.stop(t + 0.14); }
  function hat(t, soft) { const n = ac.createBufferSource(), f = ac.createBiquadFilter(), g = ac.createGain(); n.buffer = noise(); f.type = 'highpass'; f.frequency.value = 7500; env(g, t, soft ? 0.07 : 0.14, 0.05); n.connect(f).connect(g).connect(master); n.start(t, Math.random() * 0.3); n.stop(t + 0.06); }
  function note(t, freq, dur, peak, type) { const o = ac.createOscillator(), g = ac.createGain(), f = ac.createBiquadFilter(); o.type = type || 'triangle'; o.frequency.value = freq; f.type = 'lowpass'; f.frequency.value = 900; env(g, t, peak, dur); o.connect(f).connect(g).connect(master); o.start(t); o.stop(t + dur + 0.02); }
  const ROOTS = [55, 43.65, 65.41, 49]; // la, fa, do, sol : la même grille qu'une chanson douce
  function playStep(n, t) {
    const s = n % 8, bar = Math.floor(n / 8);
    if (s === 0 || s === 5) kick(t);
    if (s === 2 || s === 6) snare(t);
    hat(t, s % 2 === 1);
    if (s === 0) note(t, ROOTS[bar % 4], beatDur * 1.6, 0.34);
    if (s === 3) note(t, ROOTS[bar % 4] * 2, beatDur * 0.8, 0.16);
    if (s === 4) note(t, ROOTS[bar % 4] * 1.5, beatDur * 0.8, 0.12);
  }
  function pump() { if (!ac || state.src === 'prod') return; while (gridStart + nextStep * beatDur * 0.5 < ac.currentTime + 0.12) { playStep(nextStep, gridStart + nextStep * beatDur * 0.5); nextStep++; } }
  function chime(freqs, vol) { if (!ac || state.muted) return; const t = ac.currentTime; freqs.forEach((f, i) => note(t + i * 0.07, f, 0.9, vol || 0.18, 'sine')); }
  function startAudio() {
    if (!ac) { ac = new (window.AudioContext || window.webkitAudioContext)(); master = ac.createGain(); master.gain.value = state.muted ? 0 : 0.55; master.connect(ac.destination); }
    if (ac.state === 'suspended') ac.resume();
  }


  /* ---------- les cases ---------- */
  const el = { intro: $('#intro'), game: $('#game'), over: $('#over'), rows: $('#rows'), stage: $('#stage'), bar: $('#barNo'), bpm: $('#bpmShow'), lu: $('#luciole'), pause: $('#pauseBtn'), hint: $('#hint'), famLabel: $('#famLabel') };
  const show = (name) => { ['intro', 'game', 'over'].forEach((k) => { el[k].hidden = k !== name; }); state.mode = name; el.lu.style.display = name === 'game' ? 'none' : ''; document.body.classList.toggle('playing', name === 'game'); };
  const pose = (p) => { el.lu.setAttribute('class', 'lu lu-' + p); };
  const shuffle = (a) => { const b = a.slice(); for (let i = b.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [b[i], b[j]] = [b[j], b[i]]; } return b; };
  const loadPrefs = () => { try { return JSON.parse(localStorage.getItem(PREFS_KEY) || '{}'); } catch (e) { return {}; } };
  const savePrefs = () => { try { localStorage.setItem(PREFS_KEY, JSON.stringify({ level: state.level, length: state.length, family: state.family, bpm: state.src === 'builtin' ? state.startBpm : undefined })); } catch (e) {} };

  /* Une mesure = 4 cases (4 temps). La rime tombe dans la 4e. Toutes les 4 mesures, on change de famille de rimes (sauf si on en a choisi une). */
  let blockFamily = null, blockWords = [], lastFamilies = [];
  function bar(i) { // i = 0 est la mesure de décompte ; les vraies mesures commencent à 1
    if (state.bars[i]) return state.bars[i];
    if (i === 0) return (state.bars[0] = { count: true, cells: ['4', '3', '2', '1'] });
    const k = (i - 1) % 4;
    if (k === 0 || !blockFamily) {
      const pool = FAMILIES.filter((f) => !lastFamilies.includes(f.id));
      blockFamily = state.family === 'auto' ? pool[Math.floor(Math.random() * pool.length)] : FAMILIES.find((f) => f.id === state.family);
      lastFamilies.push(blockFamily.id); if (lastFamilies.length > 8) lastFamilies.shift();
      blockWords = shuffle(blockFamily.words.filter((w) => w.length <= 12 && !w.includes(' '))).slice(0, 4);
    }
    const word = blockWords[k] || blockWords[0];
    const fillers = shuffle(FILLERS).slice(0, 3);
    let cells;
    if (state.level === 'debutant') cells = [...fillers, word];
    else if (state.level === 'normal') cells = ['', '', '', word];
    else if (state.level === 'avance') cells = ['', '', '', k < 2 ? word : '…'];
    else cells = ['', '', '', k === 0 ? word : '…'];
    return (state.bars[i] = { cells, family: blockFamily.id, first: k === 0 });
  }
  const rowHtml = (b, i) => `<div class="bar${b.count ? ' count' : ''}" data-i="${i}">${b.cells.map((c, n) => `<div class="cell${n === 3 && !b.count ? ' rime' : ''}${c === '…' ? ' hidden' : ''}">${c}</div>`).join('')}</div>`;
  function ensureRows(upTo) {
    const have = el.rows.children.length;
    for (let i = have; i <= upTo && (state.total === Infinity || i <= state.total); i++) el.rows.insertAdjacentHTML('beforeend', rowHtml(bar(i), i));
  }
  function focusRow(i) {
    ensureRows(i + 4);
    [...el.rows.children].forEach((r) => { const d = Number(r.dataset.i) - i; r.className = r.className.replace(/\b(past|now|next|far)\b/g, '').trim() + ' ' + (d < 0 ? 'past' : d === 0 ? 'now' : d <= 2 ? 'next' : 'far'); });
    const rowH = el.rows.children[0].offsetHeight + 18;
    el.rows.style.transform = `translateY(${el.stage.clientHeight * 0.42 - (i * rowH + rowH / 2)}px)`;
  }

  /* ---------- déroulé ---------- */
  async function startGame() {
    if (state.starting || state.mode === 'game') return; state.starting = true;
    startAudio();
    if (ac.state !== 'running') { try { await Promise.race([ac.resume(), new Promise((r) => setTimeout(r, 1500))]); } catch (e) {} }
    state.starting = false;
    if (state.src === 'prod' && !prod.buffer) { flashProd('Dépose d’abord ta prod, ou reviens au beat d’Orée.'); return; }
    stopPreview(); savePrefs();
    state.bars = []; blockFamily = null; lastFamilies = []; state.paused = false; el.pause.textContent = 'Pause'; el.rows.innerHTML = '';
    state.total = state.length; state.bpm = state.startBpm; beatDur = 60 / state.bpm;
    gridStart = ac.currentTime + 0.4; nextStep = 0;
    if (state.src === 'prod') playProd(gridStart); else if (!timer) timer = setInterval(pump, 25);
    el.bpm.textContent = fmtBpm(state.bpm); el.hint.textContent = 'Rappe à voix haute : la rime tombe dans la 4ᵉ case. Orée n’écoute pas, c’est entre toi et le beat.';
    show('game'); state.lastBeat = -1; state.startedAt = gridStart; focusRow(0);
    el.lu.style.display = ''; el.lu.classList.add('ball');
    cancelAnimationFrame(raf); raf = requestAnimationFrame(frame);
  }
  function stopGame(toIntro) {
    clearInterval(timer); timer = null; cancelAnimationFrame(raf); stopProd();
    if (ac && ac.state === 'running') ac.suspend();
    el.lu.classList.remove('ball'); el.lu.style.cssText = ''; pose('idle');
    if (toIntro) show('intro');
  }
  function endGame() {
    stopGame(false); $('#finalBars').textContent = state.total === Infinity ? String(Math.max(0, Math.floor((ac.currentTime - state.startedAt) / (4 * beatDur)) - 1)) : String(state.total);
    pose('happy'); show('over'); $('#again').focus();
  }
  function togglePause() {
    if (state.mode !== 'game') return; state.paused = !state.paused;
    if (state.paused) ac.suspend(); else ac.resume();
    el.pause.textContent = state.paused ? 'Reprendre' : 'Pause';
  }
  const ease = (x) => x * x * (3 - 2 * x);
  function frame() {
    if (state.mode !== 'game') return;
    const bp = (ac.currentTime - state.startedAt) / beatDur, beat = Math.floor(bp), barIdx = Math.floor(bp / 4), frac = bp - beat;
    document.documentElement.style.setProperty('--pulse', String(Math.max(0, 1 - frac * 3.2)));
    if (beat !== state.lastBeat) {
      state.lastBeat = beat;
      if (barIdx >= 0 && (state.total === Infinity || barIdx <= state.total)) {
        focusRow(barIdx); el.bar.textContent = barIdx === 0 ? 'décompte' : (state.total === Infinity ? `mesure ${barIdx}` : `mesure ${barIdx} / ${state.total}`);
        const row = el.rows.querySelector(`.bar[data-i="${barIdx}"]`);
        if (row) [...row.children].forEach((c, n) => c.classList.toggle('on', n === beat % 4));
        const b = state.bars[barIdx]; el.famLabel.textContent = b && b.family && state.level !== 'expert' ? 'rime en -' + b.family : '';
      }
    }
    if (state.total !== Infinity && bp >= (state.total + 1) * 4) { endGame(); return; }
    // la balle (Luciole) saute de case en case, une case par temps
    const stage = el.stage, sr = stage.getBoundingClientRect(), W = Math.min(stage.clientWidth, 1100), cellW = W / 4, left = (stage.clientWidth - W) / 2, k = beat % 4;
    const x0 = left + (k + 0.5) * cellW, x1 = left + (((k + 1) % 4) + 0.5) * cellW, x = x0 + (x1 - x0) * ease(frac);
    const y = stage.clientHeight * 0.42 - 150 - Math.sin(Math.PI * frac) * 90;
    el.lu.style.transform = `translate(${x - 40 + sr.left}px, ${y + sr.top}px)`;
    raf = requestAnimationFrame(frame);
  }

  /* ---------- la prod : choisir, analyser, régler ---------- */
  const fmtBpm = (b) => (Math.abs(b - Math.round(b)) < 0.05 ? String(Math.round(b)) : b.toFixed(1)).replace('.', ',');
  const parseBpm = (t) => { const v = parseFloat(String(t).replace(',', '.')); return Number.isFinite(v) ? Math.min(200, Math.max(40, v)) : null; };
  const setBpm = (b) => { state.startBpm = Math.round(b * 20) / 20; $('#bpmInput').value = fmtBpm(state.startBpm); document.querySelectorAll('#presets .chip').forEach((c) => c.classList.toggle('on', Number(c.dataset.bpm) === state.startBpm)); if (previewSrc) startPreview(); };
  const flashProd = (t) => { const p = $('#prodInfo'); p.hidden = false; p.textContent = t; };
  function setSource(src) {
    state.src = src; stopPreview();
    document.querySelectorAll('.tab').forEach((t) => { const on = t.dataset.src === src; t.classList.toggle('on', on); t.setAttribute('aria-selected', String(on)); });
    $('#prodBox').hidden = src !== 'prod'; $('#presets').hidden = src === 'prod'; $('#offsetRow').hidden = src !== 'prod' || !prod.buffer;
    $('#half').hidden = $('#double').hidden = src !== 'prod';
    if (src === 'prod' && prod.detected) setBpm(prod.detected.bpm);
  }
  async function loadProd(file) {
    if (!file) return;
    startAudio(); flashProd('Analyse de « ' + file.name + ' »…');
    try {
      const buf = await ac.decodeAudioData(await file.arrayBuffer());
      const n = Math.min(buf.length, Math.floor(buf.sampleRate * 90)), mono = new Float32Array(n), chans = buf.numberOfChannels;
      for (let c = 0; c < chans; c++) { const d = buf.getChannelData(c); for (let i = 0; i < n; i++) mono[i] += d[i] / chans; }
      const r = detectBpm(mono, buf.sampleRate);
      Object.assign(prod, { buffer: buf, name: file.name, detected: r, offset: r.offset, nudgeMs: 0 });
      setBpm(r.bpm); $('#offVal').textContent = '0 ms'; $('#offsetRow').hidden = false;
      const sure = r.confidence >= 0.6 ? 'tempo sûr' : r.confidence >= 0.3 ? 'tempo probable, vérifie avec le clic' : 'tempo incertain : règle-le à la main ou tape-le';
      const info = $('#prodInfo'); info.hidden = false; info.innerHTML = ''; const b = document.createElement('b'); b.textContent = file.name; const em = document.createElement('em');
      em.textContent = ` — ${fmtBpm(r.bpm)} BPM détectés (${sure}) · ${Math.round(buf.duration)} s`; info.append(b, em);
      $('#dropText').innerHTML = 'Changer de prod : dépose un autre fichier ou <u>choisis-en un</u>';
    } catch (e) { flashProd('Impossible de lire ce fichier (essaie un mp3, wav ou m4a).'); }
  }
  function playProd(at) {
    stopProd(); if (!prod.buffer) return;
    const bar = 4 * 60 / state.bpm, off = Math.max(0, prod.offset + prod.nudgeMs / 1000), bars = Math.max(1, Math.floor((prod.buffer.duration - off) / bar));
    const src = ac.createBufferSource(); src.buffer = prod.buffer; src.loop = true; src.loopStart = off; src.loopEnd = off + bars * bar;
    src.connect(master); src.start(at, off); prod.source = src;
  }
  function stopProd() { if (prod.source) { try { prod.source.stop(); } catch (e) {} prod.source = null; } }
  function startPreview() {
    stopPreview(); if (!prod.buffer) return; startAudio();
    const bd = 60 / state.startBpm, t0 = ac.currentTime + 0.15, bar = 4 * bd, off = Math.max(0, prod.offset + prod.nudgeMs / 1000), bars = Math.max(1, Math.floor((prod.buffer.duration - off) / bar));
    const src = ac.createBufferSource(); src.buffer = prod.buffer; src.loop = true; src.loopStart = off; src.loopEnd = off + bars * bar; src.connect(master); src.start(t0, off); previewSrc = src;
    let k = 0; previewTimer = setInterval(() => { while (t0 + k * bd < ac.currentTime + 0.2) { note(t0 + k * bd, k % 4 === 0 ? 1760 : 1175, 0.06, 0.25, 'square'); k++; } }, 30);
    $('#preview').textContent = '■ Arrêter';
  }
  function stopPreview() { clearInterval(previewTimer); previewTimer = null; if (previewSrc) { try { previewSrc.stop(); } catch (e) {} previewSrc = null; } $('#preview').textContent = '▶ Écouter avec le clic'; }
  const tapTimes = [];
  $('#tap').addEventListener('click', () => {
    const now = performance.now(); if (tapTimes.length && now - tapTimes[tapTimes.length - 1] > 2500) tapTimes.length = 0;
    tapTimes.push(now); if (tapTimes.length > 8) tapTimes.shift();
    if (tapTimes.length >= 3) { const d = (tapTimes[tapTimes.length - 1] - tapTimes[0]) / (tapTimes.length - 1); setBpm(Math.min(200, Math.max(40, 60000 / d))); }
  });
  document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => setSource(t.dataset.src)));
  document.querySelectorAll('#presets .chip').forEach((c) => c.addEventListener('click', () => setBpm(Number(c.dataset.bpm))));
  $('#bpmMinus').addEventListener('click', () => setBpm(Math.max(40, state.startBpm - (state.src === 'prod' ? 0.5 : 1))));
  $('#bpmPlus').addEventListener('click', () => setBpm(Math.min(200, state.startBpm + (state.src === 'prod' ? 0.5 : 1))));
  $('#half').addEventListener('click', () => setBpm(Math.max(40, state.startBpm / 2)));
  $('#double').addEventListener('click', () => setBpm(Math.min(200, state.startBpm * 2)));
  $('#bpmInput').addEventListener('change', (e) => { const v = parseBpm(e.target.value); setBpm(v === null ? state.startBpm : v); });
  $('#bpmInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.stopPropagation(); e.target.blur(); } });
  const nudge = (d) => { prod.nudgeMs += d; $('#offVal').textContent = (prod.nudgeMs > 0 ? '+' : '') + prod.nudgeMs + ' ms'; if (previewSrc) startPreview(); };
  $('#offMinus').addEventListener('click', () => nudge(-10)); $('#offPlus').addEventListener('click', () => nudge(10));
  $('#preview').addEventListener('click', () => (previewSrc ? stopPreview() : startPreview()));
  $('#file').addEventListener('change', (e) => loadProd(e.target.files[0]));
  const drop = $('#drop');
  drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $('#file').click(); } });
  ['dragenter', 'dragover'].forEach((ev) => document.addEventListener(ev, (e) => { e.preventDefault(); if (e.target.closest && e.target.closest('#drop')) drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((ev) => document.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  document.addEventListener('drop', (e) => { const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0]; if (f) { setSource('prod'); loadProd(f); } });


  /* ---------- dictionnaire de rimes, réglages ---------- */
  const famSel = $('#famSel'); famSel.innerHTML = '<option value="auto">Au hasard</option>' + FAMILIES.map((f) => `<option value="${f.id}">-${f.id} (${f.words.slice(0, 3).join(', ')}…)</option>`).join('');
  function setChoice(group, value) { document.querySelectorAll(`[data-${group}]`).forEach((b) => b.classList.toggle('on', b.dataset[group] === String(value))); }
  document.querySelectorAll('[data-level]').forEach((b) => b.addEventListener('click', () => { state.level = b.dataset.level; setChoice('level', state.level); }));
  document.querySelectorAll('[data-length]').forEach((b) => b.addEventListener('click', () => { state.length = b.dataset.length === 'inf' ? Infinity : Number(b.dataset.length); setChoice('length', b.dataset.length); }));
  famSel.addEventListener('change', () => { state.family = famSel.value; });
  const dictIn = $('#dictIn'), dictOut = $('#dictOut');
  dictIn.addEventListener('input', () => {
    const w = dictIn.value.trim(); dictOut.textContent = ''; if (!w) return;
    const list = rhymesFor(w);
    if (!list.length) { dictOut.textContent = 'Je ne connais pas ce mot : essaie un mot plus courant.'; return; }
    list.slice(0, 40).forEach((r) => { const s = document.createElement('span'); s.textContent = r; dictOut.appendChild(s); });
  });
  $('#randomWord').addEventListener('click', () => { const f = FAMILIES[Math.floor(Math.random() * FAMILIES.length)]; $('#randomOut').textContent = f.words[Math.floor(Math.random() * f.words.length)]; });

  /* ---------- clavier et boutons ---------- */
  $('#start').addEventListener('click', startGame);
  $('#again').addEventListener('click', () => { show('intro'); startGame(); });
  $('#changeBtn').addEventListener('click', () => show('intro'));
  $('#pauseBtn').addEventListener('click', togglePause);
  $('#stopBtn').addEventListener('click', () => stopGame(true));
  document.addEventListener('keydown', (e) => {
    const typing = e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT';
    if (e.key === 'Enter' && state.mode !== 'game' && !typing && e.target.tagName !== 'BUTTON' && e.target.tagName !== 'LABEL') { e.preventDefault(); startGame(); }
    else if (e.key === ' ' && state.mode === 'game') { e.preventDefault(); togglePause(); }
    else if (e.key === 'Escape' && state.mode === 'game') stopGame(true);
    else if ((e.key === 'm' || e.key === 'M') && !typing) { state.muted = !state.muted; if (master) master.gain.value = state.muted ? 0 : 0.55; }
  });
  const prefs = loadPrefs();
  if (prefs.level) { state.level = prefs.level; setChoice('level', state.level); }
  if ('length' in prefs) { state.length = prefs.length === null ? Infinity : prefs.length; setChoice('length', state.length === Infinity ? 'inf' : state.length); }
  if (prefs.family) { state.family = prefs.family; famSel.value = prefs.family; }
  setBpm(prefs.bpm || 85); setChoice('level', state.level); pose('idle'); show('intro');
  window.__rime = { get audio() { return ac && ac.state; }, get time() { return ac ? ac.currentTime : -1; }, state, prod, startGame,
    loadBuffer: (buf) => { const r = detectBpm(buf.getChannelData(0), buf.sampleRate); Object.assign(prod, { buffer: buf, name: 'test', detected: r, offset: r.offset, nudgeMs: 0 }); setSource('prod'); setBpm(r.bpm); return r; } };
})();
