#!/usr/bin/env python3
"""Page d'accueil : la photo de fond n'est lisible que depuis une page oree://, jamais depuis un site ; les favoris non web n'y deviennent pas des liens.

  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/home_security_check.py
"""
import functools, http.server, os, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
START = "window.__photo = 'attente'; (function(){ const i = new Image(); i.onload = () => window.__photo = 'charge'; i.onerror = () => window.__photo = 'refuse'; i.src = 'oree://home/photo?' + Math.random(); })(); 1"
def read_photo():
    ui("eval", START)
    for _ in range(10):
        time.sleep(0.5); r = ui("eval", "window.__photo")
        if r != "attente": return r
    return "délai"

if __name__ == "__main__":
    tmp = tempfile.mkdtemp(prefix="homesec-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext")); os.environ["HB_AUTOMATION_DIR"] = auto
    photo = os.path.join(tmp, "p.png"); open(photo, "wb").write(open(os.environ["PHOTO"], "rb").read())
    page = os.path.join(tmp, "site.html"); open(page, "w").write("<!doctype html><title>site</title><p>un site</p>")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8817), functools.partial(type("H", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *a: None}), directory=tmp))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"), HB_HOME_PHOTO=photo)
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        time.sleep(9)
        check("depuis la page d'accueil d'Orée, la photo se charge", read_photo() == "charge")
        ui("load", "http://127.0.0.1:8817/site.html"); time.sleep(3)
        check("depuis un site, oree://home/photo est refusée", read_photo() == "refuse")
    finally:
        p.terminate()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
