#!/usr/bin/env python3
"""End-to-end check of boosts (per-site CSS written by the local model, checked by the app) and calm mode on a local page. Starts its
own Orée instance (never touches yours). The boost it creates is for the host 127.0.0.1 and is removed at the end. The last step runs the
whole flow with the local model and is skipped when Apple Intelligence is unavailable. Exit 1 on any failure.

  python3 scripts/bench/boost_check.py
"""
import functools, http.server, json, os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "boost_fixture")
PORT = 8789

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

def style(sel, prop): return js(f"getComputedStyle(document.querySelector('{sel}')).{prop}")
def load(wait=2.5): ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(wait)
def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(1)
    return False

def main():
    server, before = serve(), pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        ui("tab", "boostremove", "0")
        load()
        check("avant : la publicité et la barre latérale s'affichent", style(".promo", "display") == "block" and style("#sidebar", "fontSize") == "14px")

        print("\nBoost (règles au format du modèle)")
        json.dump({"regles": [
            {"selecteur": ".promo", "declarations": {"display": "none"}},
            {"selecteur": "ad-slot", "declarations": {"display": "none"}},
            {"selecteur": "#sidebar", "declarations": "font-size: 22px; color: rgb(200, 0, 0); position: fixed"},
            {"selecteur": "body", "declarations": {"display": "none"}},
            {"selecteur": ".x {", "declarations": {"display": "none"}},
            {"selecteur": ".headline", "declarations": {"background-image": "url(http://evil/x.png)"}},
        ], "calme": False}, open("/tmp/oree-boost.json", "w"))
        out = ui("tab", "boostapply", "0"); print("  ", out)
        check("seules les 3 règles sûres sont gardées (corps entier, accolade et url() refusés)", "saved 3 rule(s)" in out)
        time.sleep(1)
        check("la publicité et l'encart sont cachés, sur la page déjà ouverte", style(".promo", "display") == "none" and style("ad-slot", "display") == "none")
        check("la barre latérale passe à 22 px, en rouge, sans 'position: fixed'", style("#sidebar", "fontSize") == "22px" and style("#sidebar", "color") == "rgb(200, 0, 0)" and style("#sidebar", "position") == "static")
        check("le reste de la page n'est pas touché", style("body", "display") == "block" and style(".article", "display") == "block")
        load(1.5)
        check("après un rechargement, le boost est là dès le chargement", style(".promo", "display") == "none")
        ui("tab", "boostremove", "0"); time.sleep(1)
        check("« retirer » rend la page telle quelle", style(".promo", "display") == "block" and style("#sidebar", "fontSize") == "14px")

        print("\nMode calme")
        ui("action", "toggleCalmForSiteAction"); time.sleep(1.5)
        check("l'animation est coupée", style(".pulse", "animationName") == "none")
        check("la pastille de notification est cachée", style(".badge-count", "display") == "none")
        check("« autoplay » est retiré de la vidéo", js("document.getElementById('v').hasAttribute('autoplay')") is False)
        check("le « (3) » est retiré du titre de l'onglet", js("document.title") == "Boîte de réception")
        ui("action", "toggleCalmForSiteAction"); time.sleep(1.2)
        check("quitter le mode calme rend l'animation", style(".pulse", "animationName") == "pulse")
        check("rien ne reste enregistré pour ce site", "127.0.0.1" not in ui("tab", "boostreport", "0"))

        print("\nBoost écrit par le modèle local")
        open("/tmp/oree-boost-request.txt", "w").write("cache la publicité")
        out = ui("tab", "boostmodel", "0"); print("  ", out)
        if "available: false" in out:
            print("  ignoré : modèle local indisponible")
        else:
            done = wait_for(lambda: "127.0.0.1 rules=" in ui("tab", "boostreport", "0"), 170)
            print("  ", ui("tab", "boostreport", "0"))
            check("le modèle crée un boost pour ce site", done)
            time.sleep(1.5)
            check("la publicité est cachée par la règle du modèle", style(".promo", "display") == "none" or style("ad-slot", "display") == "none")
            check("le texte de l'article reste visible", style(".article", "display") == "block")
    finally:
        ui("tab", "boostremove", "0")
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
