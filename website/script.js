(function () {
  var root = document.documentElement;
  root.classList.add('js');

  // Thème : suit le système, mémorise le choix si possible.
  var stored = null;
  try { stored = localStorage.getItem('oree-theme'); } catch (e) {}
  if (stored) root.setAttribute('data-theme', stored);
  var btn = document.getElementById('theme');
  if (btn) btn.addEventListener('click', function () {
    var cur = root.getAttribute('data-theme') ||
      (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    var next = cur === 'dark' ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem('oree-theme', next); } catch (e) {}
  });

  // Apparition au scroll.
  var items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add('in'); });
  }

  // Démo mémoire : tout charger vs restauration paresseuse (chiffres mesurés, Mac M1 8 Go).
  var mem = document.getElementById('mem');
  if (mem) {
    var val = document.getElementById('memval');
    var note = document.getElementById('memnote');
    var texts = {
      all: ['~700 Mo', '8 pages chargées'],
      lazy: ['~120–175 Mo', '1 page chargée, 7 en attente']
    };
    mem.querySelectorAll('.seg button').forEach(function (b) {
      b.addEventListener('click', function () {
        var m = b.getAttribute('data-mode');
        mem.setAttribute('data-mode', m);
        mem.querySelectorAll('.seg button').forEach(function (o) {
          var on = o === b;
          o.classList.toggle('on', on);
          o.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
        val.textContent = texts[m][0];
        note.textContent = texts[m][1];
      });
    });
  }

  // Palette du hero : saisie animée.
  var typed = document.getElementById('typed');
  if (typed && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    var word = 'lisb', i = 0;
    typed.textContent = '';
    (function tick() {
      i = (i + 1) % (word.length + 6);
      typed.textContent = word.slice(0, Math.min(i, word.length));
      setTimeout(tick, i === 0 ? 700 : i > word.length ? 400 : 180);
    })();
  }

  // Téléchargement : le bouton pointe déjà vers le dernier .dmg (adresse stable de GitHub). On affiche en plus
  // le numéro, la date et la taille de la dernière version, sans rien casser si l'API est indisponible.
  var fine = document.getElementById('dl-fine');
  if (fine && window.fetch) {
    fetch('https://api.github.com/repos/Gwada33/oree/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (rel) {
        if (!rel || !rel.tag_name) return;
        var dmg = (rel.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
        var parts = ['Version ' + rel.tag_name.replace(/^v/, '')];
        if (rel.published_at) parts.push(new Date(rel.published_at).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' }));
        if (dmg) parts.push(Math.round(dmg.size / 1048576) + ' Mo');
        parts.push('Apple silicon (M1 et suivants)');
        fine.textContent = parts.join(' · ');
      })
      .catch(function () {});
  }
})();
