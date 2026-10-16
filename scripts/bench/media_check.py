#!/usr/bin/env python3
"""Copie des médias d'une page, copie de la page entière et inspecteur, sur une page locale, dans une instance d'essai (debug).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/media_check.py
Attention : ce banc écrase le presse-papiers pendant l'essai.
"""
import functools, http.server, os, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media_fixture")
PORT = 8791

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="mediacheck-"); auto = os.path.join(tmp, "auto"); dl = os.path.join(tmp, "dl")
    for d in (auto, dl, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto,
               HB_DOWNLOAD_DIR=dl, HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        time.sleep(9)
        ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(3)
        print("Médias")
        ui("tab", "mediacopy", "0"); time.sleep(4)
        folder = os.path.join(dl, "Médias — 127.0.0.1")
        files = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
        print("  ", files)
        check("chaque média est enregistré une seule fois (doublon écarté, image de fond et son compris)", files == ["fond.png", "rouge.png", "son.wav", "vert.png"])
        pb = ui("tab", "pbtypes", "0"); print("  ", pb)
        check("les 4 fichiers sont sur le presse-papiers (⌘V les colle dans le Finder)", "files=4" in pb)
        ui("tab", "mediaurls", "0"); time.sleep(1)
        check("les adresses sont copiées en texte", "rouge.png" in ui("tab", "pasteboard", "0"))
        print("Page entière")
        ui("tab", "pagecopy", "0"); time.sleep(3)
        pb = ui("tab", "pbtypes", "0"); print("  ", pb)
        size = int(pb.split("pdf=")[1].split()[0])
        check("la page entière est un PDF (avec une image) sur le presse-papiers", size > 1000 and "tiff" in pb)
        pages = ui("eval", "document.documentElement.scrollHeight")
        print("   hauteur de la page :", pages)
        print("Inspecteur")
        out = ui("tab", "inspect", "0"); print("  ", out)
        check("l'inspecteur s'ouvre sans message d'erreur", "inspectable=true" in out and "pas disponible" not in out)
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
