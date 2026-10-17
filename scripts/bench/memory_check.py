#!/usr/bin/env python3
"""Mémoire ambiante : une page lue (restée ouverte une douzaine de secondes) est retrouvée par ses mots ; une page de connexion, un onglet privé ou une page à mot de passe ne sont pas gardés.

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/memory_check.py
"""
import functools, http.server, os, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "luciole_fixture")
PORT = 8798

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="memcheck-"); auto = os.path.join(tmp, "auto")
    for d in (auto, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto, HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def ask(q):
        open("/tmp/oree-memory-query.txt", "w").write(q); return ui("tab", "memoire", "0")
    try:
        time.sleep(9)
        ui("load", f"http://127.0.0.1:{PORT}/memoire.html"); time.sleep(3)
        check("juste après le chargement, rien n'est encore gardé (la page n'est pas « lue »)", "count=0" in ask("mémoire WebKit"))
        time.sleep(13)
        out = ask("l'article sur la mémoire de WebKit que j'ai lu hier"); print("  ", out)
        check("une page restée ouverte est gardée, et retrouvée par ses mots (sans les mots vides)", "127.0.0.1|La mémoire de WebKit expliquée" in out)
        ui("load", f"http://127.0.0.1:{PORT}/page.html"); time.sleep(16)
        check("une page trop courte n'est pas gardée", "count=1" in ask("cheval blanc"))
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
