#!/usr/bin/env python3
"""Luciole dans la page : l'appel (capsule), la sélection (éventail), la réponse ancrée (surlignage, fil) et « Garder », sur une page locale, dans une instance d'essai (debug).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/luciole_page_check.py
"""
import functools, http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "luciole_fixture")
PORT = 8797

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="lucpage-"); auto = os.path.join(tmp, "auto")
    for d in (auto, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto,
               HB_AI_NO_AGENT="1", HB_AI_SCRIPTED="1", HB_AI_PROVIDER="groq", HB_LUCIOLE_PAGE="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    json.dump(["Ce passage explique que **le cheval blanc** traverse la plaine au lever du jour."], open("/tmp/oree-ai-script.json", "w"))
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def state(): return ui("tab", "aistate", "0")
    def wait_for(pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pred(): return True
            time.sleep(0.4)
        return False
    select = "(function(){var s=getSelection();s.selectAllChildren(document.getElementById('%s'));return 1})()"
    try:
        time.sleep(9)
        ui("load", f"http://127.0.0.1:{PORT}/page.html"); time.sleep(3)
        print("Sélection")
        ui("eval", select % "p1")
        check("trois mots sélectionnés : l'éventail apparaît (3 gestes) près du texte", wait_for(lambda: "fan=3" in state(), 15))
        s = state(); print("  ", s[:900])
        check("une sélection de deux mots ne déclenche rien", (ui("eval", "(function(){var r=document.createRange();var t=document.getElementById('p2').firstChild;r.setStart(t,0);r.setEnd(t,5);var s=getSelection();s.removeAllRanges();s.addRange(r);return 1})()") and wait_for(lambda: "fan=" not in state() or "fan=0" in state(), 6)))
        ui("eval", select % "p1"); wait_for(lambda: "fan=3" in state(), 15)
        print("Expliquer")
        open("/tmp/oree-luciole-gesture.txt", "w").write("explain"); ui("tab", "luciolegesture", "0")
        check("la réponse arrive dans une bulle ancrée (sans capsule), avec le passage surligné", wait_for(lambda: "anchors=" in state() and "mode=answerOnly" in state() and "ho cheval" not in state() and "cheval blanc" in state(), 15))
        s = state(); print("  ", s[:330])
        check("le surlignage couvre le passage", "anchors=0" not in s)
        ui("eval", "window.scrollBy(0, 40)"); time.sleep(1.2)
        s2 = state()
        check("le surlignage suit le défilement (le suivi est actif après la sélection)", "anchors=0" not in s2)
        print("Garder")
        ui("tab", "aibar", "0"); time.sleep(1)       # ferme
        ui("eval", select % "p1"); wait_for(lambda: "fan=3" in state(), 15)
        open("/tmp/oree-luciole-gesture.txt", "w").write("keep"); ui("tab", "luciolegesture", "0"); time.sleep(1)
        check("« Garder » n'ouvre pas de réponse", "mode=answerOnly" not in state() or "anchors=0" in state())
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
