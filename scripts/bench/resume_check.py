#!/usr/bin/env python3
"""End-to-end check of "reprendre où tu en étais" on local pages (no network): a long article is remembered, while long lists and videos are not. Starts its own Orée
instance (never touches yours). Positions are stored in the app's database under URLs made unique for each run, and forgotten
at the end. Exit 1 on any failure.

  python3 scripts/bench/resume_check.py
"""
import functools, http.server, json, os, re, subprocess, sys, threading, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resume_fixture")
PORT, RUN = 8787, uuid.uuid4().hex[:8]
import tempfile
DB = tempfile.mkdtemp(prefix="resume-"); os.makedirs(DB + "/ext")

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def js(expr):
    try: return json.loads(ui("eval", f"JSON.stringify({expr})"))
    except Exception: return None

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def report(): return ui("tab", "resume", "0")

def stored_video():
    m = re.search(r"video=([0-9.]+)", report())
    return float(m.group(1)) if m else None
def load(page, wait=3): ui("load", f"http://127.0.0.1:{PORT}/{page}?run={RUN}"); time.sleep(wait)

def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(0.5)
    return False

def main():
    server, before = serve(), pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", f"HB_DB_PATH={DB}/db.sqlite", "--env", f"HB_EXT_DIR={DB}/ext", "--env", "HB_AI_NO_AGENT=1", APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nArticle long")
        load("article.html")
        check("première visite : aucune offre", "notice=(none)" in report())
        js("(document.getElementById('p20').scrollIntoView(), 1)")
        check("la position de lecture est enregistrée (~50 %)", wait_for(lambda: "read=0.5" in report() or "read=0.4" in report(), 8))
        print("  ", report())
        check("la barre de progression suit la lecture", "bar=0." in report())
        load("article.html")            # a fresh visit to the same page
        check("2e visite : l'offre « Reprendre la lecture » apparaît", wait_for(lambda: "Reprendre la lecture" in report(), 6))
        ui("tab", "pressnotice", "0"); time.sleep(1.2)
        top = js("document.getElementById('p20').getBoundingClientRect().top")
        check(f"« Reprendre » ramène au bon paragraphe (haut du p20 à {top} pt)", top is not None and -20 <= top <= 140)
        ui("action", "reloadAction"); time.sleep(3)
        check("un rechargement ne propose rien (WebKit restaure déjà la position)", "notice=(none)" in report())
        ui("tab", "resumeforget", "0")

        print("\nPages qui ne sont pas des articles")
        load("list.html")
        js("(window.scrollTo(0, 3000), 1)"); time.sleep(3)
        check("une longue liste de produits n'enregistre aucune position", "read=-" in report() or "point=none" in report())
        load("video.html")
        js("(document.getElementById('v').play(), 1)"); time.sleep(1)
        js("(document.getElementById('v').currentTime = 100, 1)"); time.sleep(1); js("(document.getElementById('v').pause(), 1)"); time.sleep(2)
        check("une vidéo n'enregistre aucune position", "video=-" in report() or "point=none" in report())
        load("video.html")
        check("et ne propose rien au retour", "notice=(none)" in report())
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
