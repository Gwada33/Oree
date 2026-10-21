#!/usr/bin/env python3
"""Luciole répond par Claude Code (`claude -p`) : une question de culture, un calcul (outil `calculate`), une action sur une page (défilement), dans une instance d'essai (debug).
Utilise VRAIMENT le programme `claude` connecté sur ce Mac : quelques appels Haiku sur votre limite d'abonnement.

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/claude_code_check.py
"""
import functools, http.server, os, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "luciole_fixture")
PORT = 8799

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE)).serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="claudecode-"); auto = os.path.join(tmp, "auto")
    for d in (auto, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto, HB_AI_NO_AGENT="1",
               HB_AI_PROVIDER="claudeCode", HB_LUCIOLE_PAGE="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def state(): return ui("tab", "aistate", "0")
    def ask(text, timeout=90):
        open("/tmp/oree-ai-query.txt", "w").write(text); t = time.time(); ui("tab", "aiquery", "0")
        time.sleep(1.5)
        while time.time() - t < timeout:
            s = state()
            if "running=false" in s: return s, time.time() - t
            time.sleep(0.5)
        return state(), time.time() - t
    try:
        time.sleep(9)
        ui("load", f"http://127.0.0.1:{PORT}/page.html"); time.sleep(3)
        ui("tab", "aibar", "0"); time.sleep(1.5)
        s, d = ask("Quelle est la capitale du Portugal ?"); print(f"  {d:.1f} s :", s[s.find("answer="):][:120])
        check("une question simple reçoit sa réponse (Lisbonne)", "isbonne" in s)
        s, d = ask("Combien font 1234 fois 56 plus 789 ?"); print(f"  {d:.1f} s :", s[s.find("trace="):][:200], s[s.find("answer="):][:90])
        check("un calcul passe par l'outil calculate et donne 69 893", ("69893" in s or "69 893" in s or "69 893" in s) and "alcul" in s)
        s, d = ask("Descends tout en bas de la page."); print(f"  {d:.1f} s :", s[s.find("trace="):][:200])
        check("une action sur la page : Luciole fait défiler (outil scroll)", "Défilement" in s)
        check("aucune erreur de fournisseur", "line=|" in s or "line=| " in s)
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
