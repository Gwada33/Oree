#!/usr/bin/env python3
"""Widgets de la barre latérale : pastille lue dans le titre de l'onglet, nombre d'éléments, texte d'un élément ; mise à jour quand la page change ; rien pour un site sans onglet.

  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/widget_check.py
"""
import functools, http.server, json, os, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "widget_fixture")
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

def widget(id, host, title, source): return {"id": id, "host": host, "title": title, "symbol": "envelope", "hue": "marine", "source": source, "enabled": True}
WIDGETS = [widget("t", "127.0.0.1", "Titre", {"titleCount": {"pattern": "\\((\\d+)\\)"}}),
           widget("c", "127.0.0.1", "Non lus", {"count": {"selector": "li.unread"}}),
           widget("x", "127.0.0.1", "Prochain", {"text": {"selector": "#next"}}),
           widget("other", "example.org", "Absent", {"titleCount": {"pattern": "\\((\\d+)\\)"}})]

def labels(): return [l.split('ax="')[1].rstrip('"') for l in ui("tree").splitlines() if 'ax="' in l and " : " in l]

if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8815), functools.partial(type("H", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *a: None}), directory=FIX))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="widgets-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext")); os.environ["HB_AUTOMATION_DIR"] = auto
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"),
               HB_SIDEBAR_MODE="fixed", HB_PAGE_WIDGETS=json.dumps(WIDGETS))
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def wait(pred, timeout=25):
        end = time.time() + timeout
        while time.time() < end:
            if pred(): return True
            time.sleep(1)
        return False
    try:
        time.sleep(9)
        check("sans onglet du site, aucune pastille", not any(" : " in l for l in labels()))
        ui("load", "http://127.0.0.1:8815/inbox.html")
        check("titre « (3) » : pastille « Titre : 3 »", wait(lambda: "Titre : 3" in labels()))
        check("nombre d'éléments : « Non lus : 2 »", wait(lambda: "Non lus : 2" in labels()))
        check("texte d'un élément : « Prochain : Réunion 14h »", wait(lambda: "Prochain : Réunion 14h" in labels()))
        if os.environ.get("WIDGET_SHOT"): ui("snapshot", os.environ["WIDGET_SHOT"])   # pour voir les pastilles
        check("le widget d'un autre site n'apparaît pas", "Absent" not in " ".join(labels()))
        ui("eval", "document.title='Boîte (7) - test'; 1")
        check("le titre change : la pastille passe à 7", wait(lambda: "Titre : 7" in labels()))
        ui("eval", "document.title='Boîte - test'; 1")
        check("plus de nombre : la pastille garde son nom sans valeur", wait(lambda: any(l.endswith('ax="Titre"') for l in ui("tree").splitlines())))
    finally:
        p.terminate()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
