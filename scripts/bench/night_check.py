#!/usr/bin/env python3
"""End-to-end check of the night mode on two local pages (no network): a light page (must be darkened, photos kept as they
are, fixed header still fixed) and a page that is already dark (must be left alone). Starts its own Orée instance with the
mode forced on (HB_NIGHT=always) and never touches yours. The two site lists the mode learns (excluded / already dark) are
saved before and put back after. Exit 1 on any failure.

  python3 scripts/bench/night_check.py
"""
import functools, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "night_fixture")
PORT, DOMAIN, KEYS = 8785, "com.nolhan.hyperbrowser", ("settings.nightExcludedHosts", "settings.nightNativeHosts")

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

def saved_lists():
    out = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True).stdout
    prefs = plistlib.loads(out) if out else {}
    return {k: prefs.get(k) for k in KEYS}

def restore(saved):
    for key, value in saved.items():
        if value: subprocess.run(["defaults", "write", DOMAIN, key, "-array", *value])
        else: subprocess.run(["defaults", "delete", DOMAIN, key], capture_output=True)

def counts(path):
    img = Image.open(path).convert("RGB"); px = list(img.get_flattened_data() if hasattr(img, 'get_flattened_data') else img.getdata())
    lum = sum(0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in px) / (255 * len(px))
    # the brick-colored photo (200, 90, 60) after the page's contrast(.85): about (189, 96, 70)
    red = sum(1 for r, g, b in px if abs(r - 189) < 45 and abs(g - 96) < 45 and abs(b - 70) < 45)
    green = sum(1 for r, g, b in px if g > 110 and r < 70 and b < 70)
    return lum, red, green

def load(page, wait=3.5):
    ui("load", f"http://127.0.0.1:{PORT}/{page}"); time.sleep(wait)

def main():
    server, before, saved = serve(), pids(), saved_lists()
    for key in KEYS: subprocess.run(["defaults", "delete", DOMAIN, key], capture_output=True)
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_NIGHT=always", APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    tmp = tempfile.mkdtemp(prefix="night-")
    try:
        print("\nPage claire")
        load("light.html")
        filt = lambda sel: js(f"getComputedStyle(document.querySelector('{sel}')).filter")
        check("la page est assombrie (filtre sur la racine)", "invert(1)" in (filt("html") or ""))
        check("la photo est remise à l'endroit", "invert(1)" in (filt("#photo") or ""))
        check("la petite icône reste inversée (pas de contre-filtre)", filt("#icon") == "none" and js("document.getElementById('icon').hasAttribute('data-oree-icon')") is True)
        check("l'image de fond d'un bandeau est gardée telle quelle", js("document.getElementById('hero').hasAttribute('data-oree-keep')") is True)
        js("(window.scrollTo(0, 1000), 1)"); time.sleep(0.5)
        check("l'en-tête fixe reste collé en haut après défilement", js("document.getElementById('bar').getBoundingClientRect().top") == 0)
        js("(window.scrollTo(0, 0), 1)"); time.sleep(0.5)
        shot = os.path.join(tmp, "light.png"); ui("snapshot", shot)
        lum, red, green = counts(shot)
        print(f"  luminance moyenne {lum:.2f}, pixels de la photo {red}, verts {green}")
        check("rendu : l'écran est sombre (luminance moyenne < 0,45)", lum < 0.45)
        check("rendu : la photo garde sa couleur (à ±45 près)", red > 3000)
        check("rendu : le bandeau vert garde sa couleur", green > 3000)

        print("\nUn site clair, laissé clair d'un clic")
        ui("tab", "nightsite", "0"); time.sleep(1)
        check("exclu : plus de filtre", filt("html") == "none")
        ui("tab", "nightsite", "0"); time.sleep(1)
        check("réintégré : le filtre revient", "invert(1)" in (filt("html") or ""))

        print("\nPage déjà sombre")
        load("dark.html", 3)
        check("le filtre est retiré après la mesure du fond", filt("html") == "none")
        check("le site est mémorisé comme déjà sombre", "127.0.0.1" in ui("tab", "night", "0").split("native=")[1])
        shot = os.path.join(tmp, "dark.png"); ui("snapshot", shot)
        lum, _, _ = counts(shot)
        print(f"  luminance moyenne {lum:.2f}")
        check("rendu : la page sombre reste sombre", lum < 0.45)
        load("dark.html", 1.5)
        check("2e visite : aucun filtre dès le départ", filt("html") == "none")
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown(); restore(saved)
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
