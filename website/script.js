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

  // La course se rejoue à chaque fois qu'on la revoit.
  var race = $('#race');
  if (race && 'IntersectionObserver' in window) {
    new IntersectionObserver(function (es) {
      es.forEach(function (e) { race.classList.toggle('go', e.isIntersecting && e.intersectionRatio > 0.55); });
    }, { threshold: [0, 0.55, 1] }).observe(race);
  } else if (race) race.classList.add('go');

  // ——— Décor discret : une rangée d'arbres très pâle, quelques lucioles ———
  function rng(seed) { return function () { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }; }
  (function trees() {
    var svg = $('#treesvg'); if (!svg) return;
    var r = rng(11), d = '', count = 30;
    for (var n = 0; n < count; n++) {
      var x = (n + r() * 0.8) * (1600 / count), h = 150 + r() * 200, w = h * (0.34 + r() * 0.14), top = 400 - h;
      for (var t = 0; t < 4; t++) { var y0 = top + t * h * 0.22, y1 = y0 + h * 0.4, half = w * (0.3 + 0.2 * t) / 1.6; d += 'M' + x + ',' + y0 + 'L' + (x + half) + ',' + y1 + 'L' + (x - half) + ',' + y1 + 'Z'; }
    }
    var p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', d + 'M0,400V394H1600V400Z'); svg.appendChild(p);
  })();

  var world = $('#world'), treesEl = $('#trees');
  var cv = $('#flies'), ctx = cv && cv.getContext('2d'), flies = [], W = 0, H = 0, trail = [];
  function sizeCanvas() { if (!cv) return; var dpr = Math.min(window.devicePixelRatio || 1, 2); W = innerWidth; H = innerHeight; cv.width = W * dpr; cv.height = H * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0); }
  function makeFlies() {
    var r = rng(5), n = reduce ? 6 : (innerWidth < 700 ? 6 : 10); flies = [];
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
    if (treesEl) treesEl.style.transform = 'translate3d(0,' + Math.min(scrollY * 0.04, 70) + 'px,0)';
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
  if (reduce) { drawWorld(0, 0); window.addEventListener('scroll', function () { if (nav) nav.classList.toggle('solid', scrollY > 20); }, { passive: true }); }
  else requestAnimationFrame(frame);
  document.addEventListener('visibilitychange', function () { running = !document.hidden; if (running && !reduce) requestAnimationFrame(frame); });

  // ——— Le sommeil : huit arbres, un seul éveillé ———
  var grove = $('#grove');
  if (grove) {
    var tree = '<svg viewBox="0 0 40 60"><rect class="trunk" x="18" y="40" width="4" height="20" rx="1"/><path class="crown" d="M20 4L34 26H6zM20 16L36 42H4z"/><circle class="lamp" cx="20" cy="34" r="2.4"/></svg>';
    for (var k = 0; k < 8; k++) { var d = document.createElement('div'); d.className = 'tab-tree' + (k === 0 ? ' keep' : ''); d.innerHTML = tree; grove.appendChild(d); }
  }
  var mem = $('#mem');
  if (mem) {
    var val = $('#memval'), note = $('#memnote');
    var texts = { all: ['~700 Mo', '8 pages chargées'], lazy: ['~120–175 Mo', '1 page chargée, 7 en attente'] };
    $$('.seg button', mem).forEach(function (b) {
      b.addEventListener('click', function () {
        var m = b.getAttribute('data-mode'); mem.setAttribute('data-mode', m);
        $$('.seg button', mem).forEach(function (o) { var on = o === b; o.classList.toggle('on', on); o.setAttribute('aria-pressed', on ? 'true' : 'false'); });
        val.textContent = texts[m][0]; note.textContent = texts[m][1];
      });
    });
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
