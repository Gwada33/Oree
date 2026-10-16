#!/usr/bin/env python3
"""Vérification de bout en bout du journal d'événements, dans une instance d'essai SÉPARÉE (build de debug ; l'app de la personne n'est jamais touchée : le build se fait ailleurs
avec OREE_APP_DIR, l'instance est lancée directement et arrêtée par son numéro de processus).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/journal_check.py

Contrôle : les événements attendus arrivent (session, onglets, navigation, page, pointeur, liens, défilement, clavier), RIEN de confidentiel n'est écrit (adresse, titre, texte,
saisie, jeton d'URL), une page à mot de passe est muette, un onglet privé n'écrit rien, et un journal désactivé n'écrit rien.
"""
import functools, http.server, json, os, shutil, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal_fixture")
PORT = 8797

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def launch(tmp, journal_env):
    auto = os.path.join(tmp, "auto"); os.makedirs(auto, exist_ok=True); os.makedirs(os.path.join(tmp, "ext"), exist_ok=True)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto,
               HB_JOURNAL=journal_env, HB_JOURNAL_DIR=os.path.join(tmp, "journal"), HB_TAB_LAYOUT="vertical")
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(9); return proc

def js(expr): return ui("eval", expr)

SIM = """
window.__sim = {
  rect: id => { const r = document.getElementById(id).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; },
  move: (x0, y0, x1, y1, steps, gap) => { let i = 0; const t = setInterval(() => { i++; const x = x0 + (x1 - x0) * i / steps, y = y0 + (y1 - y0) * i / steps;
      document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: x, clientY: y })); if (i >= steps) clearInterval(t); }, gap); },
  hover: (id, ms, click) => { const el = document.getElementById(id), p = __sim.rect(id);
      el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, clientX: p.x, clientY: p.y }));
      setTimeout(() => { if (click) el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: p.x, clientY: p.y }));
        el.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: document.body })); }, ms); },
  scroll: () => { let i = 0; const t = setInterval(() => { window.scrollBy(0, i % 5 === 4 ? -120 : 220); if (++i > 12) clearInterval(t); }, 40); },
  keys: n => { const el = document.getElementById('champ'); if (el) el.focus(); for (let i = 0; i < n; i++) document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'a' })); },
};
document.addEventListener('click', e => { if (e.target.closest && e.target.closest('a')) e.preventDefault(); }, true);
'true'
"""

def main():
    server = serve()
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    tmp = tempfile.mkdtemp(prefix="journalcheck-")
    proc = launch(tmp, "1")
    try:
        print("Journal activé")
        ui("load", f"http://127.0.0.1:{PORT}/article.html"); time.sleep(4)
        js(SIM)
        js("__sim.move(50, 80, 600, 300, 40, 25); 'x'"); time.sleep(1.6)
        js("__sim.hover('lk2', 450, true); 'x'"); time.sleep(1.2)
        js("__sim.hover('lk1', 350, false); 'x'"); time.sleep(1.5)
        js("__sim.hover('ft', 300, false); 'x'"); time.sleep(1.5)
        js("__sim.hover('nav1', 300, false); 'x'"); time.sleep(1.5)
        js("__sim.scroll(); 'x'"); time.sleep(1.4)
        js("__sim.keys(7); 'x'"); time.sleep(0.6)
        ui("tab", "fewtabs", "0"); time.sleep(3)
        ui("tab", "select", "1"); time.sleep(1); ui("tab", "select", "0"); time.sleep(1)
        ui("tab", "sleep", "2"); time.sleep(1.5); ui("tab", "prewake", "2"); time.sleep(11)
        ui("tab", "aibar", "0"); time.sleep(1); ui("tab", "aibar", "0"); time.sleep(0.5)
        ui("action", "focusAddressBar"); time.sleep(0.5); ui("type", "exemple"); time.sleep(0.5); ui("key", "escape"); time.sleep(0.5)
        ui("tab", "closeat", "3"); time.sleep(1)
        # page à mot de passe : sa forme est notée, puis plus rien
        ui("load", f"http://127.0.0.1:{PORT}/login.html"); time.sleep(4); js(SIM)
        js("__sim.move(50, 80, 400, 200, 30, 25); __sim.hover('lk', 300, true); 'x'"); time.sleep(3.5)
        # onglet privé : aucun événement
        ui("action", "newPrivateTabAction"); time.sleep(2)
        ui("load", f"http://127.0.0.1:{PORT}/article.html"); time.sleep(4); js(SIM)
        js("__sim.move(50, 80, 500, 300, 30, 25); __sim.hover('lk2', 400, true); 'x'"); time.sleep(3.5)
        summary = ui("tab", "journaldump", "0"); print("  ", summary)
        counts = dict((k, int(v)) for k, v in (p.split("=") for p in summary.split() if "=" in p))
        raw = open("/tmp/oree-journal-test.jsonl").read()
        events = [json.loads(l) for l in raw.splitlines()[1:]]
        check("la session commence (machine, énergie, démarrage)", counts.get("session.start") == 1)
        check("les onglets ouverts, choisis, fermés, mis en veille et réveillés sont notés", all(counts.get(k, 0) >= 1 for k in ("tab.open", "tab.select", "tab.close", "tab.sleep", "tab.wake")))
        check("l'interface : panneau ouvert puis fermé", counts.get("ui.panel", 0) >= 2)
        check("la barre d'adresse : on y entre, on y tape, on en sort sans valider (le texte tapé n'est pas gardé)", counts.get("addr.focus", 0) >= 1 and counts.get("addr.input", 0) >= 1 and counts.get("addr.suggest", 0) >= 1 and "exemple" not in raw.lower().replace("exemple-externe", ""))
        check("la navigation : début, validation, fin", all(counts.get(k, 0) >= 1 for k in ("nav.start", "nav.commit", "nav.done")))
        check("la forme et la vitesse de la page", counts.get("page.shape", 0) >= 1 and counts.get("page.perf", 0) >= 1)
        shape = next((e for e in events if e["e"] == "page.shape" and e["d"].get("kind") == "article"), None)
        check("la page est reconnue comme un article (sans que son texte sorte)", shape is not None)
        hovers = [e for e in events if e["e"] == "link.hover"]
        check("les liens survolés sont notés, avec la durée et si on a cliqué", any(h["d"].get("clicked") and h["d"].get("dwell", 0) >= 300 for h in hovers) and any(not h["d"].get("clicked") for h in hovers))
        check("un lien d'un autre site est vu comme externe, un lien interne comme du même site", any(h["d"].get("external") for h in hovers) and any(h["d"].get("same") for h in hovers))
        check("les clics sur liens sont notés", counts.get("link.click", 0) >= 1)
        check("le pointeur est résumé par fenêtres", counts.get("ptr.window", 0) >= 1 and all(e["d"].get("dist", 0) > 0 for e in events if e["e"] == "ptr.window"))
        check("le défilement est résumé", counts.get("scroll.window", 0) >= 1)
        check("le clavier : un compte, rien d'autre", any(e["e"] == "key.window" and e["d"].get("n") == 7 for e in events))
        check("les tâches et la barre d'adresse sont absentes quand elles n'ont pas eu lieu (rien d'inventé)", counts.get("ai.task", 0) == 0)
        print("\nConfidentialité")
        for secret in ("127.0.0.1", "localhost", "article.html", "login.html", "Titre secret", "confidentiel", "SECRET123", "exemple-externe", "autre-site", "pied.example", "banque", "Connexion"):
            check(f"« {secret} » n'est nulle part dans le journal", secret.lower() not in raw.lower())
        check("les sites ne sont que des empreintes de 16 caractères", all(len(e["d"][k]) == 16 for e in events for k in ("site", "from") if k in e["d"]))
        pw = [e for e in events if e["e"] == "page.shape" and e["d"].get("password")]
        check("la page à mot de passe est notée comme formulaire", bool(pw) and pw[0]["d"].get("kind") == "form")
        after = events[events.index(pw[0]) + 1:] if pw else []
        check("puis elle est muette (aucun pointeur, lien ni clavier de cette page)", not any(e["e"] in ("ptr.window", "link.hover", "link.click", "ptr.click", "key.window") and e["d"].get("tab") == pw[0]["d"]["tab"] for e in after))
        private_tab_events = len([e for e in events if e["t"] > (pw[0]["t"] if pw else 0)])
        check("l'onglet privé n'a rien écrit (aucun événement de pointeur ou de lien après la page à mot de passe)", not any(e["e"] in ("ptr.window", "link.hover", "link.click") and e["t"] > (pw[0]["t"] if pw else 0) for e in events))
        files = os.listdir(os.path.join(tmp, "journal")) if os.path.isdir(os.path.join(tmp, "journal")) else []
        raw_disk = b"".join(open(os.path.join(tmp, "journal", f), "rb").read() for f in files)
        check("les fichiers du journal sont chiffrés", files and b"tab.select" not in raw_disk and b"page.shape" not in raw_disk)
    finally:
        proc.terminate(); proc.wait(timeout=10)
    print("\\nJournal désactivé".replace("\\\\", ""))
    shutil.rmtree(tmp, ignore_errors=True); tmp2 = tempfile.mkdtemp(prefix="journalcheck-off-")
    proc = launch(tmp2, "0")
    try:
        ui("load", f"http://127.0.0.1:{PORT}/article.html"); time.sleep(4); js(SIM)
        js("__sim.move(50, 80, 500, 300, 30, 25); __sim.hover('lk2', 400, true); 'x'"); time.sleep(4)
        ui("tab", "fewtabs", "0"); time.sleep(3)
        out = ui("tab", "journalflush", "0")
        files = [f for f in (os.listdir(os.path.join(tmp2, "journal")) if os.path.isdir(os.path.join(tmp2, "journal")) else []) if not f.startswith(".")]
        check("rien n'est écrit quand le journal est désactivé", not files and "events=0" in out)
    finally:
        proc.terminate(); proc.wait(timeout=10); server.shutdown(); shutil.rmtree(tmp2, ignore_errors=True)
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
