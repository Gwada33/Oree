#!/usr/bin/env python3
"""Offline check of the ghost capture (no network): a local fixture page with the cases that matter for privacy
and fidelity. Fails (exit 1) if a secret reaches the ghost or a piece of state is lost.

  python3 scripts/bench/ghost_fixture_check.py
Only the Orée instance this script starts is closed.
"""
import functools, http.server, json, os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghost_fixture")
PORT = 8781

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def pids():
    return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    handler = functools.partial(Quiet, directory=FIXTURE)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="ghostfixture-")
    dump = os.path.join(tmp, "ghost.html")
    before = pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_GHOST=1", "--env", f"HB_GHOST_DUMP={dump}", APP, "--args", "--automation"])
    time.sleep(5)
    mine = pids() - before
    try:
        ui("load", f"http://127.0.0.1:{PORT}/"); time.sleep(3)
        ok, out = ui("ghost", os.path.join(tmp, "live.png"), os.path.join(tmp, "ghost.png"))
        if not ok or not os.path.exists(dump):
            print("ÉCHEC : la capture n'a rien produit :", out); return 1
        report, html = json.loads(out), open(dump, encoding="utf-8").read()
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    checks = [
        ("aucun <script>", "<script" not in html.lower()),
        ("aucun <noscript> (son texte ne doit pas s'afficher)", "<noscript" not in html.lower() and "NOSCRIPT-VISIBLE" not in html),
        ("pas de meta refresh", 'http-equiv="refresh"' not in html),
        ("pas de lien preload", 'rel="preload"' not in html),
        ("SECRET : mot de passe absent", "SECRET-PASSWORD" not in html),
        ("SECRET : numéro de carte absent", "4111111111111111" not in html),
        ("SECRET : champ caché (jeton) absent", "CSRF-TOKEN-123" not in html),
        ("texte saisi conservé", "visible-text" in html),
        ("textarea conservé", "my note" in html),
        ("case cochée conservée", re.search(r'<input[^>]*id="chk"[^>]*checked', html) is not None),
        ("option choisie conservée", re.search(r'<option[^>]*selected[^>]*>\s*b', html) is not None),
        ("scroll d'un conteneur noté", 'data-oree-scroll="0,120"' in html),
        ("règle insertRule capturée", "injected-rule" in html),
        ("image lazy rendue eager", 'loading="eager"' in html),
        ("<base> vers l'adresse de la page", f'<base href="http://127.0.0.1:{PORT}/"' in html),
        ("scroll de la page noté (400)", abs(report.get("scrollY", 0) - 400) <= 1),
    ]
    failed = [name for name, passed in checks if not passed]
    for name, passed in checks: print(("  ok   " if passed else "  ÉCHEC"), name)
    print(f"{len(checks) - len(failed)}/{len(checks)} vérifications passent")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
