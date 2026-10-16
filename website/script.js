(function () {
  var root = document.documentElement;
  root.classList.add('js');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var clamp = function (v, a, b) { return Math.max(a, Math.min(b, v)); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
  };

  // ——— Thème : suit le système, mémorise le choix ———
  function isDark() { var t = root.getAttribute('data-theme'); return t ? t === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches; }
  var themeBtn = $('#theme');
  if (themeBtn) themeBtn.addEventListener('click', function () {
    var next = isDark() ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    store.set('oree-theme', next);
  });

  // ——— Navigation : fond au défilement, section courante ———
  var nav = $('#nav');
  function onScrollNav() { if (nav) nav.classList.toggle('solid', window.scrollY > 24); }
  onScrollNav();
  var links = $$('.nav-links a');
  var navObserver = null;
  if ('IntersectionObserver' in window && links.length) {
    var map = {};
    links.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
    navObserver = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (!e.isIntersecting) return;
        links.forEach(function (o) { o.classList.toggle('on', o === map[e.target.id]); });
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    Object.keys(map).forEach(function (id) { var sec = document.getElementById(id); if (sec) navObserver.observe(sec); });
  }

  // ——— Apparition au défilement ———
  var reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !reduce) {
    var rio = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); rio.unobserve(e.target); } });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    reveals.forEach(function (el) { rio.observe(el); });
  } else { reveals.forEach(function (el) { el.classList.add('in'); }); }

  // ——— La lisière : des troncs denses au bord, qui s'éclaircissent vers le centre (comme le logo) ———
  function plant(el, fromBottom) {
    var vw = window.innerWidth;
    var small = vw < 720;
    var n = small ? 4 : 9;
    var w0 = small ? 9 : clamp(vw * 0.034, 16, 54);
    var html = '';
    for (var i = 0; i < n; i++) {
      var w = w0 * Math.pow(0.76, i);
      var gap = (small ? 4 : clamp(vw * 0.008, 4, 12)) * Math.pow(1.24, i);
      var o = (isDark() ? 0.42 : 0.5) * (small ? 0.7 : 1) * Math.pow(0.8, i);
      html += '<i style="--w:' + w.toFixed(1) + 'px;--o:' + o.toFixed(3) + ';--t:' + (0.05 + i * 0.07).toFixed(2) + 's;margin-' + (el.classList.contains('trees-r') ? 'left' : 'right') + ':' + gap.toFixed(1) + 'px"></i>';
    }
    el.innerHTML = html;
    el.style.setProperty('--gap', '0px');
  }
  function plantAll() {
    $$('.forest .trees').forEach(function (t) { plant(t); });
    var nt = $('.night-trees');
    if (nt) {
      nt.innerHTML = '<div class="trees trees-l"></div><div class="trees trees-r"></div>';
      $$('.trees', nt).forEach(function (t) { plant(t, true); });
    }
  }
  plantAll();
  var lastW = window.innerWidth;
  window.addEventListener('resize', function () { if (Math.abs(window.innerWidth - lastW) > 60) { lastW = window.innerWidth; plantAll(); } });

  // ——— Héros : la forêt s'écarte et la fenêtre se redresse quand on descend ———
  var forest = $('#forest'), shot = $('#hero-shot'), mac = shot && $('.mac', shot);
  var ticking = false;
  function onScroll() {
    onScrollNav();
    if (ticking || reduce) return;
    ticking = true;
    requestAnimationFrame(function () {
      ticking = false;
      var y = window.scrollY, vh = window.innerHeight;
      if (forest && y < vh * 1.6) forest.style.setProperty('--open', clamp(y / (vh * 0.8), 0, 1).toFixed(3));
      if (mac) {
        var r = shot.getBoundingClientRect();
        var p = clamp(1 - (r.top - vh * 0.18) / (vh * 0.62), 0, 1);
        mac.style.setProperty('--tilt', (10 * (1 - p)).toFixed(2) + 'deg');
        mac.style.setProperty('--sc', (0.94 + 0.06 * p).toFixed(4));
      }
    });
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
  if (reduce && mac) { mac.style.setProperty('--tilt', '0deg'); mac.style.setProperty('--sc', '1'); }

  // ——— Vitesse : trois fenêtres et trois téléchargements, rejoués à chaque passage ———
  var race = $('#race'), raceRaf = 0, dlRaf = 0;
  var fmt = function (v) { return v.toFixed(2).replace('.', ',') + ' s'; };
  function runRace() {
    var wins = $$('.win', race), start = performance.now();
    wins.forEach(function (w) { w.classList.remove('done'); $('b', w).textContent = '0,00 s'; });
    cancelAnimationFrame(raceRaf);
    (function tick(now) {
      var el = (now - start) / 1000 / 2.2, pending = false;                 // temps réel ×2,2 pour qu'on le voie
      wins.forEach(function (w) {
        var t = parseFloat(w.getAttribute('data-t')), v = Math.min(el, t);
        $('b', w).textContent = fmt(v);
        if (v >= t) w.classList.add('done'); else pending = true;
      });
      if (pending) raceRaf = requestAnimationFrame(tick);
    })(start);
  }
  function runDl() {
    var rows = $$('.dl', race), start = performance.now();
    rows.forEach(function (r) { r.classList.remove('done'); r.style.setProperty('--p', 0); $('b', r).textContent = '0 Mo'; });
    cancelAnimationFrame(dlRaf);
    (function tick(now) {
      var el = (now - start) / 1000, pending = false;                        // 1 s ici = 7 s réelles
      rows.forEach(function (r) {
        var d = parseFloat(r.getAttribute('data-d')), p = clamp(el / d, 0, 1);
        r.style.setProperty('--p', p.toFixed(4));
        $('b', r).textContent = Math.round(192 * p) + ' Mo';
        if (p >= 1) r.classList.add('done'); else pending = true;
      });
      if (pending) dlRaf = requestAnimationFrame(tick);
    })(start);
  }
  function finishRace() {
    race.classList.add('go');
    $$('.win', race).forEach(function (w) { w.classList.add('done'); $('b', w).textContent = fmt(parseFloat(w.getAttribute('data-t'))); });
    $$('.dl', race).forEach(function (r) { r.classList.add('done'); r.style.setProperty('--p', 1); $('b', r).textContent = '192 Mo'; });
  }
  if (race && 'IntersectionObserver' in window && !reduce) {
    new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        if (e.isIntersecting && e.intersectionRatio > 0.45 && !race.classList.contains('go')) { race.classList.add('go'); runRace(); runDl(); }
        else if (!e.isIntersecting && race.classList.contains('go')) { race.classList.remove('go'); cancelAnimationFrame(raceRaf); cancelAnimationFrame(dlRaf); }
      });
    }, { threshold: [0, 0.45, 1] }).observe(race);
  } else if (race) { finishRace(); }

  // ——— Légèreté : huit onglets, un seul éveillé, les autres s'endorment en vague ———
  var lu = '<svg class="lu lu-sleep" viewBox="0 0 40 40" aria-hidden="true"><circle class="h" cx="20" cy="26.5" r="11"/><g transform="rotate(-30 11 10)"><ellipse class="w wl" cx="11" cy="10" rx="6" ry="3.3"/></g><g transform="rotate(30 29 10)"><ellipse class="w wr" cx="29" cy="10" rx="6" ry="3.3"/></g><g class="bd"><path class="a" d="M17.4 10Q15.8 6.4 13.2 5.4M22.6 10Q24.2 6.4 26.8 5.4"/><circle class="k" cx="13.2" cy="5.4" r="1.3"/><circle class="k" cx="26.8" cy="5.4" r="1.3"/><circle class="l" cx="20" cy="26.5" r="5.6"/><circle class="k" cx="20" cy="17" r="8.6"/><g class="es"><rect class="e" x="16.1" y="14.8" width="2.5" height="4.2" rx="1.25"/><rect class="e" x="21.4" y="14.8" width="2.5" height="4.2" rx="1.25"/></g></g></svg>';
  var tabs8 = $('#tabs8');
  if (tabs8) {
    for (var k = 0; k < 8; k++) {
      var d = document.createElement('div');
      d.className = 'tab8' + (k === 0 ? ' keep' : '');
      d.style.setProperty('--w', (k * 0.08).toFixed(2) + 's');
      d.innerHTML = '<span class="ln"></span><span class="ln"></span><span class="ln"></span><span class="ln" style="width:70%"></span>' + (k === 0 ? '' : '<span class="zz">' + lu + '</span>');
      tabs8.appendChild(d);
    }
  }
  var mem = $('#mem');
  if (mem) {
    var val = $('#memval'), note = $('#memnote'), shown = 700, tween = 0, touched = false;
    var texts = { all: [700, '8 pages chargées'], lazy: [150, '1 page chargée, 7 endormies'] };
    var setMode = function (m) {
      mem.setAttribute('data-mode', m);
      $$('.seg button', mem).forEach(function (o) { var on = o.getAttribute('data-mode') === m; o.classList.toggle('on', on); o.setAttribute('aria-pressed', on ? 'true' : 'false'); });
      note.textContent = texts[m][1];
      cancelAnimationFrame(tween);
      var from = shown, to = texts[m][0], t0 = performance.now(), dur = reduce ? 1 : 1400;
      (function step(now) {
        var p = clamp((now - t0) / dur, 0, 1), e = 1 - Math.pow(1 - p, 3);
        shown = from + (to - from) * e;
        val.textContent = (m === 'lazy' && p === 1 ? '≈ ' : '') + Math.round(shown) + ' Mo';
        if (p < 1) tween = requestAnimationFrame(step);
      })(t0);
    };
    $$('.seg button', mem).forEach(function (b) { b.addEventListener('click', function () { touched = true; setMode(b.getAttribute('data-mode')); }); });
    if ('IntersectionObserver' in window && !reduce) {
      new IntersectionObserver(function (es, o) {
        if (es[0].isIntersecting) { o.disconnect(); setTimeout(function () { if (!touched) setMode('lazy'); }, 1600); }
      }, { threshold: 0.55 }).observe(mem);
    }
  }

  // ——— Espaces : chaque espace garde ses onglets ———
  var SPACES = {
    perso: { name: 'Perso', meta: '3 onglets · 1 en veille', tabs: [['W', '#3A3A3A', 'Lisbonne — Wikipédia', 'on'], ['M', '#B6532F', 'Météo de la semaine', ''], ['R', '#6D2F7E', 'Radio du matin', 'zz']] },
    travail: { name: 'Travail', meta: '4 onglets · 2 en veille', tabs: [['B', '#2D5C9A', 'Boîte de réception', 'on'], ['A', '#B04A2A', 'Agenda de l’équipe', ''], ['D', '#3F3C37', 'Documentation WebKit', 'zz'], ['T', '#8A5E0E', 'Tableau du projet', 'zz']] },
    lecture: { name: 'Lecture', meta: '2 onglets · 1 en veille', tabs: [['H', '#2F7354', 'How browsers work', 'on'], ['P', '#87406F', 'Revue de presse du dimanche', 'zz']] }
  };
  var spaces = $('#spaces');
  if (spaces) {
    var showSpace = function (key) {
      var s = SPACES[key];
      $$('.sp-spine', spaces).forEach(function (b) { var on = b.getAttribute('data-s') === key; b.classList.toggle('on', on); b.setAttribute('aria-selected', on ? 'true' : 'false'); });
      $('#sp-name').textContent = s.name;
      $('#sp-meta').textContent = s.meta;
      $('#sp-tabs').innerHTML = s.tabs.map(function (t) { return '<li class="' + t[3] + '"><i style="background:' + t[1] + '">' + t[0] + '</i>' + t[2] + '</li>'; }).join('');
    };
    $$('.sp-spine', spaces).forEach(function (b) { b.addEventListener('click', function () { showSpace(b.getAttribute('data-s')); }); });
  }

  // ——— La teinte change tout le site ———
  var names = { mousse: 'Mousse', brique: 'Brique', ocre: 'Ocre', marine: 'Marine', prune: 'Prune', graphite: 'Graphite' };
  var swBtns = $$('#swatches button');
  var setAccent = function (a, save) {
    if (a === 'mousse') root.removeAttribute('data-accent'); else root.setAttribute('data-accent', a);
    swBtns.forEach(function (o) { o.setAttribute('aria-pressed', o.getAttribute('data-a') === a ? 'true' : 'false'); });
    var n = $('#swatch-name'); if (n) n.textContent = names[a];
    if (save) store.set('oree-accent', a === 'mousse' ? null : a);
  };
  swBtns.forEach(function (b) { b.addEventListener('click', function () { setAccent(b.getAttribute('data-a'), true); }); });
  setAccent(root.getAttribute('data-accent') || 'mousse', false);

  // ——— Luciole : démonstration et cerveau au choix ———
  var brain = {
    local: ['Tout reste sur ton Mac.', 'Tout reste sur ce Mac · Luciole peut se tromper'],
    lm: ['Tes modèles LM Studio, sur ton Mac.', 'LM Studio : tout reste sur ce Mac · Luciole peut se tromper'],
    mistral: ['Plus rapide, mais les pages lues partent chez Mistral.', 'Mistral (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper'],
    groq: ['Plus rapide, mais les pages lues partent chez Groq.', 'Groq (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper']
  };
  $$('#brains button').forEach(function (b) {
    b.addEventListener('click', function () {
      var k = b.getAttribute('data-b');
      $$('#brains button').forEach(function (o) { o.classList.toggle('on', o === b); });
      $('#brain-note').textContent = brain[k][0];
      $('#pd-foot').textContent = brain[k][1];
    });
  });
  var pd = $('#pd');
  if (pd) {
    var timers = [];
    var pose = function (p) { var s = $('#pd-lu'); if (s) s.setAttribute('class', 'lu lu-' + p); };
    var hide = function (id) { $('#' + id).classList.add('hidden'); };
    var show = function (id) { $('#' + id).classList.remove('hidden'); };
    var reset = function () {
      timers.forEach(clearTimeout); timers = [];
      ['pd-user', 'pd-trace', 'pd-r2', 'pd-r3', 'pd-confirm', 'pd-result'].forEach(hide);
      var c = $('#pd-chip'); c.textContent = 'En cours'; c.className = '';
      var s3 = $('#pd-r3s'); s3.className = 'q'; s3.textContent = '?';
      $('#pd-state').textContent = 'Prête'; pose('idle');
    };
    var play = function () {
      reset();
      var steps = [
        [300, function () { show('pd-user'); $('#pd-state').textContent = 'Au travail'; pose('read'); }],
        [1100, function () { show('pd-trace'); pose('act'); }],
        [1900, function () { show('pd-r2'); }],
        [2800, function () { show('pd-r3'); var c = $('#pd-chip'); c.textContent = 'En attente de toi'; c.className = 'wait'; show('pd-confirm'); $('#pd-state').textContent = 'Attend ton accord'; pose('wait'); }]
      ];
      steps.forEach(function (s) { timers.push(setTimeout(s[1], reduce ? 0 : s[0])); });
    };
    var finish = function (ok) {
      hide('pd-confirm');
      var res = $('#pd-result'), chip = $('#pd-chip'), s3 = $('#pd-r3s');
      show('pd-result'); chip.className = ''; chip.textContent = ok ? '3 étapes' : 'Annulée';
      s3.className = ok ? '' : 'no'; s3.textContent = ok ? '✓' : '×';
      res.textContent = ok ? 'Envoyé. C’est toi qui as cliqué.' : 'Rien n’est parti. Le formulaire reste rempli dans la page.';
      $('#pd-state').textContent = 'Prête'; pose(ok ? 'happy' : 'idle');
    };
    $('#pd-yes').addEventListener('click', function () { finish(true); });
    $('#pd-no').addEventListener('click', function () { finish(false); });
    $('#pd-replay').addEventListener('click', play);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (es, o) { if (es[0].isIntersecting) { play(); o.disconnect(); } }, { threshold: 0.45 }).observe(pd);
    } else play();
  }

  // ——— Téléchargement : numéro, date et taille de la dernière version (GitHub) ———
  var lines = $$('[data-release]');
  if (lines.length && window.fetch) {
    var showRel = function (rel) {
      var dmg = (rel.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      var v = 'Version ' + String(rel.tag_name).replace(/^v/, '');
      var date = rel.published_at ? new Date(rel.published_at).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' }) : '';
      var size = dmg ? Math.round(dmg.size / 1048576) + ' Mo' : '';
      lines.forEach(function (el, i) {
        var parts = i === 0 ? [v, size, 'macOS 15.4 ou plus récent', 'Apple silicon'] : [v, date, size, 'macOS 15.4 ou plus récent', 'Apple silicon (M1 et suivants)'];
        el.textContent = parts.filter(Boolean).join(' · ');
      });
    };
    // L'API de GitHub limite à 60 requêtes par heure et par adresse : la réponse est gardée 6 h dans le navigateur.
    var cached = null;
    try { cached = JSON.parse(store.get('oree-release') || 'null'); } catch (e) {}
    if (cached && cached.rel && Date.now() - cached.at < 6 * 3600 * 1000) { showRel(cached.rel); }
    else {
      fetch('https://api.github.com/repos/Gwada33/oree/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (rel) {
          if (!rel || !rel.tag_name) return;
          var slim = { tag_name: rel.tag_name, published_at: rel.published_at, assets: (rel.assets || []).map(function (a) { return { name: a.name, size: a.size }; }) };
          store.set('oree-release', JSON.stringify({ at: Date.now(), rel: slim }));
          showRel(slim);
        })
        .catch(function () {});
    }
  }
})();
