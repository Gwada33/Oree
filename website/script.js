(function () {
  var root = document.documentElement;
  root.classList.add('js');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var clamp = function (v, a, b) { return Math.max(a, Math.min(b, v)); };
  var lastMove = Date.now();

  // ——— Thème : suit le système, mémorise le choix si possible ———
  var stored = null;
  try { stored = localStorage.getItem('oree-theme'); } catch (e) {}
  if (stored) root.setAttribute('data-theme', stored);
  function isDark() { var t = root.getAttribute('data-theme'); return t ? t === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches; }
  var themeBtn = $('#theme');
  if (themeBtn) themeBtn.addEventListener('click', function () {
    var next = isDark() ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('oree-theme', next); } catch (e) {}
  });

  // ——— Apparition au défilement ———
  var reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !reduce) {
    var rio = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); rio.unobserve(e.target); } });
    }, { threshold: 0.15, rootMargin: '0px 0px -40px 0px' });
    reveals.forEach(function (el) { rio.observe(el); });
  } else { reveals.forEach(function (el) { el.classList.add('in'); }); }

  // Ouverture : trois fenêtres se chargent pour de bon, avec chronomètre (temps réel ×2,2 pour qu'on le voie). Rejoué à chaque fois qu'on la revoit.
  var race = $('#race'), raceRaf = 0;
  function runRace() {
    var wins = $$('.win', race), start = performance.now();
    wins.forEach(function (w) { w.classList.remove('done'); $('b', w).textContent = '0,00 s'; });
    cancelAnimationFrame(raceRaf);
    (function tick(now) {
      var el = (now - start) / 1000 / 2.2, pending = false;
      wins.forEach(function (w) {
        var t = parseFloat(w.getAttribute('data-t')), v = Math.min(el, t);
        $('b', w).textContent = v.toFixed(2).replace('.', ',') + ' s';
        if (v >= t) w.classList.add('done'); else pending = true;
      });
      if (pending) raceRaf = requestAnimationFrame(tick);
    })(start);
  }
  // Téléchargement : les mégaoctets s'accumulent en direct, quinze connexions contre une (temps réel ×0,14 pour Orée : 7 s deviennent 1 s).
  var dlRaf = 0;
  function runDl() {
    var rows = $$('.dl', race), start = performance.now();
    rows.forEach(function (r) { r.classList.remove('done'); $('b', r).textContent = '0 Mo'; });
    cancelAnimationFrame(dlRaf);
    (function tick(now) {
      var el = (now - start) / 1000, pending = false;
      rows.forEach(function (r) {
        var d = parseFloat(r.getAttribute('data-d')), p = clamp(el / d, 0, 1);
        $('b', r).textContent = Math.round(192 * p) + ' Mo';
        if (p >= 1) r.classList.add('done'); else pending = true;
      });
      if (pending) dlRaf = requestAnimationFrame(tick);
    })(start);
  }
  function stopRace() { cancelAnimationFrame(raceRaf); cancelAnimationFrame(dlRaf); }
  if (race && 'IntersectionObserver' in window && !reduce) {
    new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        var on = e.isIntersecting && e.intersectionRatio > 0.5;
        if (on && !race.classList.contains('go')) { race.classList.add('go'); runRace(); runDl(); }
        else if (!e.isIntersecting && race.classList.contains('go')) { race.classList.remove('go'); stopRace(); }
      });
    }, { threshold: [0, 0.5, 1] }).observe(race);
  } else if (race) {
    race.classList.add('go');
    $$('.win', race).forEach(function (w) { w.classList.add('done'); $('b', w).textContent = w.getAttribute('data-t').replace('.', ',') + ' s'; });
    $$('.dl', race).forEach(function (r) { r.classList.add('done'); $('b', r).textContent = '192 Mo'; });
    var fixed = { '.83': '0,83 s', '.9': '0,90 s', '1.58': '1,58 s' }; $$('.win', race).forEach(function (w) { $('b', w).textContent = fixed[w.getAttribute('data-t')]; });
  }

  function rng(seed) { return function () { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }; }

  var world = $('#world');
  var cv = $('#flies'), ctx = cv && cv.getContext('2d'), flies = [], W = 0, H = 0, trail = [];
  function sizeCanvas() { if (!cv) return; var dpr = Math.min(window.devicePixelRatio || 1, 2); W = innerWidth; H = innerHeight; cv.width = W * dpr; cv.height = H * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0); }
  function makeFlies() {
    var r = rng(5), n = reduce ? 4 : (innerWidth < 700 ? 4 : 7); flies = [];
    for (var i = 0; i < n; i++) flies.push({ x: r() * innerWidth, y: r() * innerHeight, r: 1 + r() * 1.1, ph: r() * 6.28, sp: 0.4 + r() * 0.8 });
  }
  sizeCanvas(); makeFlies();
  window.addEventListener('resize', function () { sizeCanvas(); makeFlies(); });

  // ——— Luciole : vole d'un moment à l'autre, regarde le pointeur, réagit ———
  var guide = $('#guide'), say = $('#say'), gsvg = guide && $('svg', guide);
  var scenes = $$('.moment');
  var g = { x: innerWidth * 0.8, y: innerHeight * 0.55, vx: 0, vy: 0, pose: 'sleep', base: 'sleep', scene: null, woke: false, forced: null, hover: null, hopUntil: 0, sleepy: false, sayTimer: 0, mx: innerWidth / 2, my: innerHeight / 2 };
  function setPose(p) { if (!gsvg || g.pose === p) return; gsvg.setAttribute('class', 'lu lu-' + p); g.pose = p; }
  function speak(text, ms) {
    if (!say || !text || reduce) return;
    say.textContent = text; say.classList.add('on');
    clearTimeout(g.sayTimer); g.sayTimer = setTimeout(function () { say.classList.remove('on'); }, ms || 2600);
  }
  function wake(line) {
    if (g.woke && !g.sleepy) return;
    var was = g.sleepy; g.woke = true; g.sleepy = false; setPose('wake');
    setTimeout(function () { setPose('idle'); g.base = (g.scene && g.scene.getAttribute('data-pose')) || 'idle'; speak(line || (was ? 'Ah !' : $('#top').getAttribute('data-wake'))); }, 1500);
  }
  window.guideForce = function (pose) { g.forced = pose; };
  window.addEventListener('scroll', function () { lastMove = Date.now(); if (scrollY > 30) wake(); if (nav) nav.classList.toggle('solid', scrollY > 20); }, { passive: true });
  window.addEventListener('pointermove', function (e) { g.mx = e.clientX; g.my = e.clientY; lastMove = Date.now(); if (g.sleepy) wake(); }, { passive: true });
  setTimeout(function () { wake(); }, 3000);
  var nav = $('#nav');

  // Survol : les éléments marqués data-lu="pose|texte" font réagir Luciole.
  $$('[data-lu]').forEach(function (el) {
    var parts = el.getAttribute('data-lu').split('|');
    el.addEventListener('pointerenter', function () { if (!g.woke) return; g.hover = parts[0]; speak(parts[1], 1800); });
    el.addEventListener('pointerleave', function () { g.hover = null; });
  });
  // Clic sur Luciole : elle saute de joie.
  var hops = ['Hop !', 'Coucou.', 'Je brille, je brille…', 'Chut, les onglets dorment.', 'Tu m’as réveillée ?'];
  if (gsvg) gsvg.addEventListener('click', function () { wake(); g.hopUntil = Date.now() + 1500; speak(hops[Math.floor(Math.random() * hops.length)], 2200); });

  function targetFor(scene) {
    var sel = scene.getAttribute('data-anchor'), el = sel ? $(sel) : $('[data-station]', scene), vw = innerWidth, vh = innerHeight, x, y;
    if (el) { var r = el.getBoundingClientRect(); x = r.left + r.width / 2; y = r.top + r.height / 2; } else { x = vw * 0.88; y = vh * 0.45; }
    return { x: clamp(x, 40, vw - 40), y: clamp(y, 100, vh - 90) };
  }
  function activeScene() {
    var mid = innerHeight * 0.5, best = scenes[0];
    for (var i = 0; i < scenes.length; i++) { var r = scenes[i].getBoundingClientRect(); if (r.top <= mid && r.bottom > mid) { best = scenes[i]; break; } }
    return best;
  }

  // ——— Boucle d'animation unique ———
  var lastY = scrollY, running = true;
  function drawWorld(t, dy) {
    if (!ctx) return;
    ctx.clearRect(0, 0, W, H);
    var rgb = isDark() ? '226,214,120' : '217,164,65', i;
    for (i = 0; i < flies.length; i++) {
      var f = flies[i];
      if (!reduce) {
        f.x += Math.sin(t * 0.0003 * f.sp + f.ph) * 0.3; f.y += Math.cos(t * 0.00025 * f.sp + f.ph * 2) * 0.22 - dy * 0.12;
        var mx = g.x - f.x, my = g.y - f.y, dist = Math.hypot(mx, my);
        if (dist < 260 && dist > 1) { f.x += mx / dist * 0.18; f.y += my / dist * 0.18; }     // elles viennent près de Luciole
        if (f.x < -10) f.x = W + 10; if (f.x > W + 10) f.x = -10; if (f.y < -10) f.y = H + 10; if (f.y > H + 10) f.y = -10;
      }
      var a = 0.25 + 0.55 * (0.5 + 0.5 * Math.sin(t * 0.0014 * f.sp + f.ph));
      var gr = ctx.createRadialGradient(f.x, f.y, 0, f.x, f.y, f.r * 6);
      gr.addColorStop(0, 'rgba(' + rgb + ',' + (0.7 * a) + ')'); gr.addColorStop(1, 'rgba(' + rgb + ',0)');
      ctx.fillStyle = gr; ctx.beginPath(); ctx.arc(f.x, f.y, f.r * 6, 0, 6.283); ctx.fill();
    }
    // La traînée de lumière que Luciole laisse derrière elle.
    for (i = 0; i < trail.length; i++) {
      var p = trail[i], k = (i + 1) / trail.length;
      ctx.fillStyle = 'rgba(' + rgb + ',' + (0.22 * k * k) + ')'; ctx.beginPath(); ctx.arc(p.x, p.y, 1.5 + 4 * k, 0, 6.283); ctx.fill();
    }
  }
  function frame(t) {
    if (!running) return;
    var dy = scrollY - lastY; lastY = scrollY;
    // L'aube : une lueur chaude monte quand on approche de la fin.
    var camp = $('#telecharger');
    if (world && camp) world.style.setProperty('--dawn', String(clamp((scrollY + innerHeight - camp.offsetTop) / (innerHeight * 0.9), 0, 1) * 0.5));
    if (world && !reduce) { world.style.setProperty('--lx', g.x.toFixed(0) + 'px'); world.style.setProperty('--ly', (g.y + scrollY * 0).toFixed(0) + 'px'); }
    if (guide && !reduce) {
      var sc = activeScene();
      if (sc !== g.scene) { g.scene = sc; if (g.woke && !g.sleepy) { g.base = sc.getAttribute('data-pose') || 'idle'; speak(sc.getAttribute('data-say')); } }
      var tg = targetFor(sc);
      g.vx += (tg.x - g.x) * 0.0105; g.vy += (tg.y - g.y) * 0.0105; g.vx *= 0.9; g.vy *= 0.9; g.x += g.vx; g.y += g.vy;
      var speed = Math.hypot(g.vx, g.vy), hopping = Date.now() < g.hopUntil;
      var bob = Math.sin(t * 0.0021) * 4 - (hopping ? Math.abs(Math.sin((g.hopUntil - Date.now()) / 90)) * 22 : 0);
      var tilt = clamp(g.vx * 1.4, -16, 16);
      guide.style.transform = 'translate3d(' + (g.x - 29).toFixed(1) + 'px,' + (g.y - 29 + bob).toFixed(1) + 'px,0) rotate(' + tilt.toFixed(1) + 'deg)';
      guide.classList.toggle('flip', g.x > innerWidth * 0.55 && !sc.hasAttribute('data-noflip'));
      // Les yeux suivent le pointeur.
      var ex = clamp((g.mx - g.x) / innerWidth * 5, -1.5, 1.5), ey = clamp((g.my - g.y) / innerHeight * 5, -1.2, 1.2);
      guide.style.setProperty('--ex', ex.toFixed(2) + 'px'); guide.style.setProperty('--ey', ey.toFixed(2) + 'px');
      // S'endort si rien ne bouge pendant un moment.
      if (g.woke && !g.sleepy && Date.now() - lastMove > 25000) { g.sleepy = true; setPose('sleep'); speak('Zzz…', 3000); }
      if (g.woke && !g.sleepy && g.pose !== 'wake') setPose(hopping ? 'happy' : (g.forced || g.hover || (speed > 2.6 ? 'act' : (g.base || 'idle'))));
      guide.classList.add('live');
      trail.push({ x: g.x, y: g.y }); if (trail.length > 16) trail.shift();
      // Le pointeur près de la lanterne du titre la fait battre plus vite.
      var lamp = $('#lamp');
      if (lamp && scrollY < innerHeight) { var lr = lamp.getBoundingClientRect(); lamp.classList.toggle('near', Math.hypot(g.mx - (lr.left + lr.width / 2), g.my - (lr.top + lr.height / 2)) < 140); }
    }
    drawWorld(t, dy);
    requestAnimationFrame(frame);
  }
  window.__oreeFrame = frame;      // essais : fait avancer l'animation à la main quand la fenêtre est cachée (le navigateur suspend alors requestAnimationFrame)
  if (guide && reduce) { guide.style.transform = 'translate3d(' + (innerWidth - 80) + 'px,' + (innerHeight - 96) + 'px,0)'; guide.classList.add('live'); setPose('idle'); }
  if (reduce) { if (world) { world.style.setProperty('--lx', '72%'); world.style.setProperty('--ly', '60%'); } drawWorld(0, 0); window.addEventListener('scroll', function () { if (nav) nav.classList.toggle('solid', scrollY > 20); }, { passive: true }); }
  else requestAnimationFrame(frame);
  document.addEventListener('visibilitychange', function () { running = !document.hidden; if (running && !reduce) requestAnimationFrame(frame); });

  // ——— Le sommeil : huit fenêtres, une seule éveillée ; les autres s'endorment en vague ———
  var tabs8 = $('#tabs8');
  if (tabs8) {
    var sleeper = '<svg class="lu lu-sleep" viewBox="0 0 40 40" aria-hidden="true"><circle class="h" cx="20" cy="26.5" r="11"/><g transform="rotate(-30 11 10)"><ellipse class="w wl" cx="11" cy="10" rx="6" ry="3.3"/></g><g transform="rotate(30 29 10)"><ellipse class="w wr" cx="29" cy="10" rx="6" ry="3.3"/></g><g class="bd"><path class="a" d="M17.4 10Q15.8 6.4 13.2 5.4M22.6 10Q24.2 6.4 26.8 5.4"/><circle class="k" cx="13.2" cy="5.4" r="1.3"/><circle class="k" cx="26.8" cy="5.4" r="1.3"/><circle class="l" cx="20" cy="26.5" r="5.6"/><circle class="k" cx="20" cy="17" r="8.6"/><g class="es"><rect class="e" x="16.1" y="14.8" width="2.5" height="4.2" rx="1.25"/><rect class="e" x="21.4" y="14.8" width="2.5" height="4.2" rx="1.25"/></g></g></svg>';
    for (var k = 0; k < 8; k++) {
      var d = document.createElement('div'); d.className = 'tab8' + (k === 0 ? ' keep' : ''); d.style.setProperty('--w', (k * 0.07).toFixed(2) + 's');
      d.innerHTML = '<span class="ln"></span><span class="ln"></span><span class="ln"></span><span class="ln" style="width:70%"></span><span class="zz">' + (k === 0 ? '' : sleeper) + '</span>';
      tabs8.appendChild(d);
    }
  }
  var mem = $('#mem');
  if (mem) {
    var val = $('#memval'), note = $('#memnote'), shown = 700, tween = 0, auto = false;
    var texts = { all: [700, '8 pages chargées'], lazy: [150, '1 page chargée, 7 en attente · 120–175 Mo mesurés'] };
    var setMode = function (m) {
      mem.setAttribute('data-mode', m);
      $$('.seg button', mem).forEach(function (o) { var on = o.getAttribute('data-mode') === m; o.classList.toggle('on', on); o.setAttribute('aria-pressed', on ? 'true' : 'false'); });
      note.textContent = texts[m][1];
      cancelAnimationFrame(tween);
      var from = shown, to = texts[m][0], t0 = performance.now(), dur = reduce ? 1 : 1400;
      (function step(now) {
        var p = clamp((now - t0) / dur, 0, 1), e = 1 - Math.pow(1 - p, 3); shown = from + (to - from) * e;
        val.textContent = (m === 'lazy' && p === 1 ? '~' : '') + Math.round(shown) + ' Mo';
        if (p < 1) tween = requestAnimationFrame(step);
      })(t0);
    };
    $$('.seg button', mem).forEach(function (b) { b.addEventListener('click', function () { auto = true; setMode(b.getAttribute('data-mode')); }); });
    // La première fois qu'on la voit, elles s'endorment toutes seules : on comprend sans lire.
    if ('IntersectionObserver' in window && !reduce) {
      new IntersectionObserver(function (es, o) { if (es[0].isIntersecting) { o.disconnect(); setTimeout(function () { if (!auto) setMode('lazy'); }, 1800); } }, { threshold: 0.6 }).observe(mem);
    }
  }

  // ——— Luciole demande : démonstration et cerveau au choix ———
  var brain = {
    local: ['Tout reste sur ton Mac.', 'Tout reste sur ce Mac · Luciole peut se tromper'],
    lm: ['Tes modèles LM Studio, sur ton Mac.', 'LM Studio : tout reste sur ce Mac · Luciole peut se tromper'],
    mistral: ['Plus rapide — mais les pages lues partent chez Mistral.', 'Mistral (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper'],
    groq: ['Plus rapide — mais les pages lues partent chez Groq.', 'Groq (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper']
  };
  $$('#brains button').forEach(function (b) {
    b.addEventListener('click', function () {
      var k = b.getAttribute('data-b');
      $$('#brains button').forEach(function (o) { o.classList.toggle('on', o === b); });
      $('#brain-note').textContent = brain[k][0]; $('#pd-foot').textContent = brain[k][1];
    });
  });
  var pd = $('#pd');
  function show(id) { var e = $('#' + id); if (e) e.classList.remove('hidden'); }
  if (pd) {
    var played = false;
    var play = function () {
      if (played) return; played = true;
      [[200, function () { show('pd-user'); $('#pd-state').textContent = 'Au travail'; }],
       [900, function () { show('pd-trace'); window.guideForce('read'); }],
       [2300, function () { show('pd-r3'); var c = $('#pd-chip'); c.textContent = 'En attente de vous'; c.className = 'wait'; show('pd-confirm'); $('#pd-state').textContent = 'Attend ton accord'; window.guideForce('wait'); speak('Je n’appuie pas sans toi.', 4200); }]
      ].forEach(function (s) { setTimeout(s[1], reduce ? 0 : s[0]); });
    };
    if ('IntersectionObserver' in window) new IntersectionObserver(function (es, o) { if (es[0].isIntersecting) { play(); o.disconnect(); } }, { threshold: 0.5 }).observe(pd); else play();
    var finish = function (ok) {
      $('#pd-confirm').classList.add('hidden');
      var res = $('#pd-result'), chip = $('#pd-chip'); res.classList.remove('hidden'); chip.className = ''; chip.textContent = ok ? '3 étapes' : 'Annulée'; $('#pd-state').textContent = 'Prêt';
      $('#pd-r3 i').className = ''; $('#pd-r3 i').textContent = ok ? '✓' : '×';
      res.textContent = ok ? 'Envoyé — c’est toi qui as cliqué.' : 'Rien n’est parti. Le formulaire reste rempli.';
      window.guideForce(ok ? 'happy' : 'idle'); speak(ok ? 'Fait !' : 'D’accord.', 2600);
      setTimeout(function () { window.guideForce(null); }, 3000);
    };
    $('#pd-yes').addEventListener('click', function () { finish(true); });
    $('#pd-no').addEventListener('click', function () { finish(false); });
  }

  // ——— La teinte change tout le site ———
  var names = { mousse: 'Mousse', brique: 'Brique', ocre: 'Ocre', marine: 'Marine', prune: 'Prune', graphite: 'Graphite' };
  $$('#swatches button').forEach(function (b) {
    b.addEventListener('click', function () {
      var a = b.getAttribute('data-a');
      if (a === 'mousse') root.removeAttribute('data-accent'); else root.setAttribute('data-accent', a);
      $$('#swatches button').forEach(function (o) { o.setAttribute('aria-pressed', o === b ? 'true' : 'false'); });
      $('#swatch-name').textContent = names[a];
    });
  });

  // ——— Téléchargement : numéro, date et taille de la dernière version ———
  var fine = $('#dl-fine');
  if (fine && window.fetch) {
    var showRel = function (rel) {
      var dmg = (rel.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      var parts = ['Version ' + rel.tag_name.replace(/^v/, '')];
      if (rel.published_at) parts.push(new Date(rel.published_at).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' }));
      if (dmg) parts.push(Math.round(dmg.size / 1048576) + ' Mo');
      parts.push('Apple silicon (M1 et suivants)');
      fine.textContent = parts.join(' · ');
    };
    // L'API de GitHub limite à 60 requêtes par heure et par adresse : on garde la réponse 6 h dans le navigateur.
    var cached = null;
    try { cached = JSON.parse(localStorage.getItem('oree-release') || 'null'); } catch (e) {}
    if (cached && cached.rel && Date.now() - cached.at < 6 * 3600 * 1000) { showRel(cached.rel); }
    else {
      fetch('https://api.github.com/repos/Gwada33/oree/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (rel) {
          if (!rel || !rel.tag_name) return;
          var slim = { tag_name: rel.tag_name, published_at: rel.published_at, assets: (rel.assets || []).map(function (a) { return { name: a.name, size: a.size }; }) };
          try { localStorage.setItem('oree-release', JSON.stringify({ at: Date.now(), rel: slim })); } catch (e) {}
          showRel(slim);
        })
        .catch(function () {});
    }
  }
})();
