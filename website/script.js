(function () {
  var root = document.documentElement;
  root.classList.add('js');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var clamp = function (v, a, b) { return Math.max(a, Math.min(b, v)); };

  // ——— Thème : suit le système, mémorise le choix si possible ———
  var stored = null;
  try { stored = localStorage.getItem('oree-theme'); } catch (e) {}
  if (stored) root.setAttribute('data-theme', stored);
  function isDark() {
    var t = root.getAttribute('data-theme');
    return t ? t === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
  }
  var themeBtn = $('#theme');
  if (themeBtn) themeBtn.addEventListener('click', function () {
    var next = isDark() ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('oree-theme', next); } catch (e) {}
    paintWorld(true);
  });

  // ——— Apparition au défilement ———
  var reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !reduce) {
    var rio = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); rio.unobserve(e.target); } });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    reveals.forEach(function (el) { rio.observe(el); });
  } else { reveals.forEach(function (el) { el.classList.add('in'); }); }

  // ——— Le monde : ciel qui change au fil du récit, trois rangées d'arbres, lucioles ———
  var world = $('#world');
  var STOPS = {
    dark: [
      ['#1B2A2C', '#3B4A3F', '#25342F', '#1D2A26', '#131C1A'],
      ['#16241F', '#2F4035', '#223029', '#1A2622', '#101816'],
      ['#101B1D', '#22332D', '#1B2824', '#151F1C', '#0D1412'],
      ['#0C1416', '#1C2A26', '#17221F', '#121B18', '#0A100F'],
      ['#0A1113', '#162320', '#131E1B', '#0F1816', '#080D0C'],
      ['#0B1012', '#1A231D', '#141C17', '#101612', '#0A0F0C'],
      ['#0E1618', '#222E27', '#1B2620', '#151E19', '#0D1310'],
      ['#27352F', '#9A8A5E', '#2A3A30', '#1F2D26', '#121C17']
    ],
    light: [
      ['#DDE7DF', '#F3F0EA', '#B9C9BC', '#9DB2A1', '#7F9885'],
      ['#D8E4DB', '#EFEDE5', '#B3C5B6', '#97AD9B', '#7A9380'],
      ['#D2E0D6', '#EBEADF', '#AEC1B1', '#92A996', '#768F7C'],
      ['#CEDCD3', '#E8E7DC', '#A9BDAD', '#8DA592', '#728B78'],
      ['#CBDACF', '#E5E5DA', '#A5BAA9', '#89A18E', '#6E8774'],
      ['#CFDCCF', '#E8E7DB', '#A9BDAA', '#8DA48F', '#728A74'],
      ['#DAE4D4', '#F0EDDF', '#B6C6AF', '#9BAE95', '#7E9479'],
      ['#F7E9C8', '#F3F0EA', '#C9CDB0', '#A9B592', '#879A78']
    ]
  };
  // Le jour, les arbres s'éclaircissent vers le ciel : le texte posé devant reste lisible.
  STOPS.light = STOPS.light.map(function (row) { return row.map(function (c, i) { return i < 2 ? c : lighten(c, '#F3F0EA', 0.34); }); });
  function lighten(a, b, t) { var x = hex(a), y = hex(b); return '#' + x.map(function (v, i) { return ('0' + Math.round(v + (y[i] - v) * t).toString(16)).slice(-2); }).join(''); }
  function hex(c) { return [parseInt(c.substr(1, 2), 16), parseInt(c.substr(3, 2), 16), parseInt(c.substr(5, 2), 16)]; }
  function mix(a, b, t) { var x = hex(a), y = hex(b); return 'rgb(' + x.map(function (v, i) { return Math.round(v + (y[i] - v) * t); }).join(',') + ')'; }
  var lastPaint = -1;
  function paintWorld(force) {
    if (!world) return;
    var camp = document.getElementById('telecharger');
    var max = Math.max(1, (camp ? camp.offsetTop : document.documentElement.scrollHeight) - innerHeight * 0.35);      // l'aube se lève au feu de camp
    var p = clamp(scrollY / max, 0, 1) * 7, i = Math.min(6, Math.floor(p)), t = p - i;
    var key = Math.round(p * 40) + (isDark() ? 'd' : 'l');
    if (!force && key === lastPaint) return;
    lastPaint = key;
    var set = STOPS[isDark() ? 'dark' : 'light'], a = set[i], b = set[i + 1];
    ['--sky-a', '--sky-b', '--tr1', '--tr2', '--tr3'].forEach(function (name, k) { world.style.setProperty(name, mix(a[k], b[k], t)); });
    world.style.setProperty('--moon', isDark() ? String(0.75 * (1 - Math.pow(p / 7, 3))) : '0');
  }

  function rng(seed) { return function () { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }; }
  function forest(id, count, seed, minH, maxH) {
    var svg = $('#' + id); if (!svg) return;
    var r = rng(seed), d = '';
    for (var n = 0; n < count; n++) {
      var x = (n + r() * 0.8) * (1600 / count), h = minH + r() * (maxH - minH), w = h * (0.34 + r() * 0.16), base = 400, top = base - h;
      d += 'M' + (x - 2) + ',' + base + 'h4v-14h-4z';
      for (var t = 0; t < 4; t++) {
        var y0 = top + t * h * 0.22, y1 = y0 + h * 0.4, half = w * (0.3 + 0.2 * t) / 1.6;
        d += 'M' + x + ',' + y0 + 'L' + (x + half) + ',' + y1 + 'L' + (x - half) + ',' + y1 + 'Z';
      }
    }
    d += 'M0,400V392H1600V400Z';
    var p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', d); svg.appendChild(p);
  }
  forest('trees1', 34, 11, 120, 230);
  forest('trees2', 22, 29, 170, 300);
  forest('trees3', 13, 47, 240, 390);
  var layers = [$('.t1'), $('.t2'), $('.t3')];

  // Lucioles du décor
  var cv = $('#flies'), ctx = cv && cv.getContext('2d'), flies = [], W = 0, H = 0, dpr = 1, mouse = { x: -999, y: -999 };
  function sizeCanvas() {
    if (!cv) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2); W = innerWidth; H = innerHeight;
    cv.width = W * dpr; cv.height = H * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  function makeFlies() {
    var n = reduce ? 10 : (innerWidth < 700 ? 14 : 30), r = rng(5);
    flies = [];
    for (var i = 0; i < n; i++) flies.push({ x: r() * innerWidth, y: r() * innerHeight, r: 1.2 + r() * 1.6, ph: r() * 6.28, sp: 0.4 + r() * 0.8, dx: (r() - 0.5) * 0.12 });
  }
  function drawFlies(t, dy) {
    if (!ctx) return;
    ctx.clearRect(0, 0, W, H);
    var rgb = isDark() ? '226,214,120' : '217,164,65';
    for (var i = 0; i < flies.length; i++) {
      var f = flies[i];
      if (!reduce) {
        f.x += Math.sin(t * 0.0003 * f.sp + f.ph) * 0.35 + f.dx;
        f.y += Math.cos(t * 0.00025 * f.sp + f.ph * 2) * 0.25 - dy * 0.18;
        var mx = mouse.x - f.x, my = mouse.y - f.y, dist = Math.hypot(mx, my);
        if (dist < 150 && dist > 1) { f.x += mx / dist * 0.35; f.y += my / dist * 0.35; }
        if (f.x < -10) f.x = W + 10; if (f.x > W + 10) f.x = -10;
        if (f.y < -10) f.y = H + 10; if (f.y > H + 10) f.y = -10;
      }
      var a = 0.3 + 0.7 * (0.5 + 0.5 * Math.sin(t * 0.0014 * f.sp + f.ph));
      var g = ctx.createRadialGradient(f.x, f.y, 0, f.x, f.y, f.r * 7);
      g.addColorStop(0, 'rgba(' + rgb + ',' + (0.9 * a) + ')'); g.addColorStop(1, 'rgba(' + rgb + ',0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(f.x, f.y, f.r * 7, 0, 6.283); ctx.fill();
    }
  }
  sizeCanvas(); makeFlies();
  window.addEventListener('resize', function () { sizeCanvas(); makeFlies(); });
  window.addEventListener('pointermove', function (e) { mouse.x = e.clientX; mouse.y = e.clientY; }, { passive: true });

  // ——— Luciole, le fil du récit ———
  var guide = $('#guide'), say = $('#say'), gsvg = guide && $('svg', guide);
  var scenes = $$('.scene[data-say]');
  var g = { x: innerWidth * 0.78, y: innerHeight * 0.4, vx: 0, vy: 0, pose: 'sleep', scene: null, woke: false, forced: null, sayTimer: 0 };
  function setPose(p) {
    if (!gsvg || g.pose === p) return;
    gsvg.setAttribute('class', 'lu lu-' + p); g.pose = p;
  }
  function speak(text, ms) {
    if (!say || !text) return;
    say.textContent = text; say.classList.add('on');
    clearTimeout(g.sayTimer); g.sayTimer = setTimeout(function () { say.classList.remove('on'); }, ms || 4200);
  }
  function wake() {
    if (g.woke) return; g.woke = true; setPose('wake');
    setTimeout(function () { g.base = 'idle'; setPose('idle'); speak($('#lisiere').getAttribute('data-wake'), 4200); }, 1800);
  }
  window.addEventListener('scroll', function () { if (scrollY > 30) wake(); }, { passive: true });
  setTimeout(wake, 2600);
  window.guideForce = function (pose) { g.forced = pose; };

  function targetFor(scene) {
    var anchorSel = scene.getAttribute('data-anchor'), el = anchorSel ? $(anchorSel) : $('[data-station]', scene);
    var vw = innerWidth, vh = innerHeight, x, y;
    if (el) { var r = el.getBoundingClientRect(); x = r.left + r.width / 2; y = r.top + r.height / 2; }
    else { x = scene.getAttribute('data-side') === 'left' ? vw * 0.08 : vw * 0.9; y = vh * 0.4; }
    return { x: clamp(x, 40, vw - 40), y: clamp(y, 110, vh - 90) };
  }
  function activeScene() {
    var mid = innerHeight * 0.5, best = scenes[0];
    for (var i = 0; i < scenes.length; i++) { var r = scenes[i].getBoundingClientRect(); if (r.top <= mid && r.bottom > mid) { best = scenes[i]; break; } }
    return best;
  }

  // ——— Chapitre I : le sentier se dessine avec le défilement ———
  var trail = $('#trail'), trailScene = $('#sentier');
  function drawTrail() {
    if (!trail || !trailScene) return;
    var r = trailScene.getBoundingClientRect(), p = clamp((innerHeight - r.top) / (r.height + innerHeight * 0.6), 0, 1);
    trail.style.setProperty('--dash', String(Math.round((1 - p) * 900)));
  }
  if (trail) { trail.style.strokeDasharray = '900'; trail.style.strokeDashoffset = 'var(--dash,900)'; trail.style.strokeDasharray = '6 10'; }

  // ——— Boucle d'animation unique ———
  var lastY = scrollY, running = true, tPrev = 0;
  function frame(t) {
    if (!running) return;
    var dy = scrollY - lastY; lastY = scrollY;
    paintWorld(false);
    layers.forEach(function (el, i) { if (el) el.style.transform = 'translate3d(0,' + Math.min(scrollY * [0.03, 0.06, 0.1][i], 90) + 'px,0)'; });
    drawFlies(t, dy);
    drawTrail();
    if (guide && !reduce) {
      var sc = activeScene();
      if (sc !== g.scene) { g.scene = sc; if (g.woke) { g.base = sc.getAttribute('data-pose'); speak(sc.getAttribute('data-say')); } }
      var tg = targetFor(sc);
      g.vx += (tg.x - g.x) * 0.0105; g.vy += (tg.y - g.y) * 0.0105; g.vx *= 0.9; g.vy *= 0.9;
      g.x += g.vx; g.y += g.vy;
      var speed = Math.hypot(g.vx, g.vy), bob = Math.sin(t * 0.0021) * 4;
      var tilt = clamp(g.vx * 1.4, -16, 16);
      guide.style.transform = 'translate3d(' + (g.x - 30).toFixed(1) + 'px,' + (g.y - 30 + bob).toFixed(1) + 'px,0) rotate(' + tilt.toFixed(1) + 'deg)';
      guide.classList.toggle('flip', g.x > innerWidth * 0.55);
      if (g.woke || g.pose !== 'sleep') {
        if (g.pose !== 'wake') setPose(g.forced || (speed > 2.4 ? 'act' : (g.base || sc.getAttribute('data-pose') || 'idle')));
      }
      guide.classList.add('live');
    }
    requestAnimationFrame(frame);
  }
  if (guide && reduce) {            // mouvement réduit : Luciole reste posée dans un coin, sans voler
    guide.style.transform = 'translate3d(' + (innerWidth - 80) + 'px,' + (innerHeight - 96) + 'px,0)'; guide.classList.add('live'); setPose('idle');
  }
  window.__oreeFrame = frame;      // essais : fait avancer l'animation à la main quand la fenêtre est cachée (le navigateur suspend alors requestAnimationFrame)
  paintWorld(true);
  if (reduce) { drawFlies(0, 0); window.addEventListener('scroll', function () { paintWorld(false); }, { passive: true }); }
  else requestAnimationFrame(frame);
  document.addEventListener('visibilitychange', function () {
    running = !document.hidden; if (running && !reduce) requestAnimationFrame(frame);
  });

  // ——— Navigation : chapitre en cours ———
  var links = $$('#chapters a'), chapterScenes = scenes.filter(function (s) { return s.id; });
  function spy() {
    var mid = innerHeight * 0.45, cur = null;
    chapterScenes.forEach(function (s) { var r = s.getBoundingClientRect(); if (r.top <= mid && r.bottom > mid) cur = s.id; });
    links.forEach(function (a) { a.classList.toggle('on', a.getAttribute('href') === '#' + cur); });
  }
  window.addEventListener('scroll', spy, { passive: true }); spy();

  // ——— Chapitre II : la capture se penche vers le pointeur ———
  var shot = $('#shot1');
  if (shot && !reduce) window.addEventListener('pointermove', function (e) {
    var r = shot.getBoundingClientRect(); if (r.bottom < 0 || r.top > innerHeight) return;
    shot.style.setProperty('--ry', (((e.clientX - (r.left + r.width / 2)) / innerWidth) * -9).toFixed(2) + 'deg');
  }, { passive: true });

  // ——— Chapitre III : huit arbres, un seul éveillé ———
  var grove = $('#grove');
  if (grove) {
    var tree = '<svg viewBox="0 0 40 60"><rect class="trunk" x="18" y="40" width="4" height="20" rx="1"/><path class="crown" d="M20 4L34 26H6zM20 16L36 42H4z"/><circle class="lamp" cx="20" cy="34" r="2.4"/></svg>';
    for (var k = 0; k < 8; k++) { var d = document.createElement('div'); d.className = 'tab-tree awake' + (k === 0 ? ' keep' : ''); d.innerHTML = tree; grove.appendChild(d); }
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

  // ——— Chapitre IV : cerveau au choix, et la démonstration du panneau ———
  var brainText = {
    local: ['<b>Modèle intégré.</b> Téléchargé une seule fois (environ 2,7 Go), avec ton accord. Tout reste sur ton Mac. Plus lent, il se trompe plus : c’est pour cela que tu valides.', 'Tout reste sur ce Mac · Luciole peut se tromper'],
    lm: ['<b>LM Studio.</b> Utilise les modèles que tu as déjà téléchargés dans LM Studio, via son serveur local : Orée les liste pour toi. Tant que l’adresse reste localhost, rien ne quitte ton Mac.', 'LM Studio : tout reste sur ce Mac · Luciole peut se tromper'],
    mistral: ['<b>Mistral (nuage).</b> Plus rapide et plus fiable pour agir — mais les pages que Luciole lit et tes questions sont envoyées à Mistral. Le panneau l’écrit en bas tant que c’est le cas. La clé reste dans le Trousseau.', 'Mistral (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper'],
    groq: ['<b>Groq (nuage).</b> Très rapide, appels d’outils natifs — mais les pages que Luciole lit et tes questions sont envoyées à Groq. Le panneau l’écrit en bas tant que c’est le cas. La clé reste dans le Trousseau.', 'Groq (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper']
  };
  $$('#brains button').forEach(function (b) {
    b.addEventListener('click', function () {
      var k = b.getAttribute('data-b');
      $$('#brains button').forEach(function (o) { o.classList.toggle('on', o === b); });
      $('#brain-note').innerHTML = brainText[k][0]; $('#pd-foot').textContent = brainText[k][1];
    });
  });

  var pd = $('#pd');
  function show(id) { var e = $('#' + id); if (e) e.classList.remove('hidden'); }
  function ripple(el) {
    if (reduce || !el) return;
    var r = el.getBoundingClientRect(), s = document.createElement('span');
    s.style.cssText = 'position:fixed;pointer-events:none;z-index:60;border-radius:50%;background:var(--accent);opacity:.35;width:20px;height:20px;left:' + (r.left + r.width / 2 - 10) + 'px;top:' + (r.top + r.height / 2 - 10) + 'px;transition:transform .6s cubic-bezier(.2,.8,.2,1),opacity .6s';
    document.body.appendChild(s); requestAnimationFrame(function () { s.style.transform = 'scale(5)'; s.style.opacity = '0'; });
    setTimeout(function () { s.remove(); }, 700);
  }
  if (pd) {
    var played = false;
    var play = function () {
      if (played) return; played = true;
      var steps = [
        [200, function () { show('pd-user'); $('#pd-state').textContent = 'Au travail'; }],
        [1100, function () { show('pd-lu'); window.guideForce('read'); }],
        [2300, function () { show('pd-r2'); $('#pd-chip').textContent = 'En cours · étape 2'; window.guideForce('act'); }],
        [3600, function () { show('pd-r3'); var c = $('#pd-chip'); c.textContent = 'En attente de vous'; c.className = 'wait'; show('pd-confirm'); $('#pd-state').textContent = 'Attend votre accord'; window.guideForce('wait'); speak('Je n’appuie pas sans vous.', 5000); }]
      ];
      steps.forEach(function (s) { setTimeout(s[1], reduce ? 0 : s[0]); });
    };
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (es, o) { if (es[0].isIntersecting) { play(); o.disconnect(); } }, { threshold: 0.45 }).observe(pd);
    } else play();
    function finish(ok) {
      $('#pd-confirm').classList.add('hidden');
      var res = $('#pd-result'), chip = $('#pd-chip'), row = $('#pd-r3 i');
      res.classList.remove('hidden');
      chip.className = ''; $('#pd-state').textContent = 'Prêt';
      if (ok) {
        ripple($('#pd-yes')); window.guideForce('happy');
        res.textContent = 'Réservation envoyée. Dans Orée, c’est toi qui as cliqué : Luciole n’appuie jamais à ta place.';
        row.className = ''; row.textContent = '✓'; chip.textContent = '3 étapes'; speak('Fait !', 3000);
      } else {
        window.guideForce('idle');
        res.textContent = 'Rien n’a été envoyé. Le formulaire reste rempli dans la page, et je ne réessaie pas.';
        row.className = ''; row.textContent = '×'; chip.textContent = '3 étapes · annulée'; speak('D’accord, on ne bouge pas.', 3000);
      }
      setTimeout(function () { window.guideForce(null); }, 3200);
    }
    $('#pd-yes').addEventListener('click', function () { finish(true); });
    $('#pd-no').addEventListener('click', function () { finish(false); });
  }

  // ——— Chapitre VII : la teinte change tout le site ———
  var names = { mousse: 'Mousse', brique: 'Brique', ocre: 'Ocre', marine: 'Marine', prune: 'Prune', graphite: 'Graphite' };
  $$('#swatches button').forEach(function (b) {
    b.addEventListener('click', function () {
      var a = b.getAttribute('data-a');
      if (a === 'mousse') root.removeAttribute('data-accent'); else root.setAttribute('data-accent', a);
      $$('#swatches button').forEach(function (o) { o.setAttribute('aria-pressed', o === b ? 'true' : 'false'); });
      $('#swatch-name').textContent = names[a];
      speak('Belle lanterne, non ?', 2400);
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
