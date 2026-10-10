#!/usr/bin/env python3
"""Offline check of the ghost capture (no network): local fixture pages with the cases that matter for privacy and
fidelity. Each page is frozen into a ghost; the script checks the captured HTML and compares the ghost with the live
page pixel by pixel. Exit 1 if anything fails.

  python3 scripts/bench/ghost_fixture_check.py

Pages: privacy (secrets, form state, scroll, CSSOM rules), components (open / closed / nested shadow DOM, adopted
sheets), canvas (2D and WebGL), video (same-origin and cross-origin), iframes (same-origin and cross-origin).
Two local origins (ports 8781 and 8782) make the cross-origin cases real. Only the Orée instance this script starts
is closed.
"""
import functools, http.server, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghost_fixture")
PORT, OTHER = 8781, 8782

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def pids():
    return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def diff_pct(a_path, b_path):
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size: b = b.resize(a.size)
    px = list(ImageChops.difference(a, b).convert("L").getdata())
    return 100.0 * sum(1 for v in px if v > 40) / len(px)

def serve(port):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
        def end_headers(self):                      # the app's persistent cache must never serve an older fixture
            self.send_header("Cache-Control", "no-store")
            super().end_headers()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

def expand(html, depth=0):
    """The HTML plus the decoded documents of its data: iframes (recursively), so checks can look inside frames."""
    import base64
    out = html
    if depth < 4:
        for m in re.finditer(r'src="data:text/html;charset=utf-8;base64,([A-Za-z0-9+/=]+)"', html):
            out += "\n" + expand(base64.b64decode(m.group(1)).decode("utf-8", "replace"), depth + 1)
    return out

def has(html, *needles): return all(n in html for n in needles)

# (name, page, seconds to wait after loading, max pixel difference %, [(check name, f(html, report) -> bool)])
PAGES = [
    ("vie privée et formulaires", "index.html", 3, 100, [
        ("aucun <script>", lambda h, r: "<script" not in h.lower()),
        ("aucun <noscript> (son texte ne doit pas s'afficher)", lambda h, r: "<noscript" not in h.lower() and "NOSCRIPT-VISIBLE" not in h),
        ("pas de meta refresh", lambda h, r: 'http-equiv="refresh"' not in h),
        ("pas de lien preload", lambda h, r: 'rel="preload"' not in h),
        ("SECRET : mot de passe absent", lambda h, r: "SECRET-PASSWORD" not in h),
        ("SECRET : numéro de carte absent", lambda h, r: "4111111111111111" not in h),
        ("SECRET : champ caché (jeton) absent", lambda h, r: "CSRF-TOKEN-123" not in h),
        ("texte saisi conservé", lambda h, r: "visible-text" in h),
        ("textarea conservé", lambda h, r: "my note" in h),
        ("case cochée conservée", lambda h, r: re.search(r'<input[^>]*id="chk"[^>]*checked', h) is not None),
        ("option choisie conservée", lambda h, r: re.search(r'<option[^>]*selected[^>]*>\s*b', h) is not None),
        ("scroll d'un conteneur noté", lambda h, r: 'data-oree-scroll="0,120"' in h),
        ("règle insertRule capturée", lambda h, r: "injected-rule" in h),
        ("image lazy visible rendue eager", lambda h, r: re.search(r'<img[^>]*id="lazyvis"[^>]*loading="eager"', h) is not None or re.search(r'<img[^>]*loading="eager"[^>]*id="lazyvis"', h) is not None),
        ("image lazy hors écran laissée lazy", lambda h, r: re.search(r'<img[^>]*id="lazy"[^>]*loading="lazy"', h) is not None or re.search(r'<img[^>]*loading="lazy"[^>]*id="lazy"', h) is not None),
        ("<base> vers l'adresse de la page", lambda h, r: f'<base href="http://127.0.0.1:{PORT}/' in h),
        ("scroll de la page noté (400)", lambda h, r: abs(r.get("scrollY", 0) - 400) <= 1),
    ]),
    ("web components (Shadow DOM)", "components.html", 2, 1.0, [
        ("shadow roots déclaratifs (ouvert, fermé, externe, imbriqué)", lambda h, r: h.count('shadowrootmode="open"') >= 4),
        ("contenu du shadow ouvert", lambda h, r: has(h, "OPEN-SHADOW", "slotted text")),
        ("contenu du shadow FERMÉ", lambda h, r: "CLOSED-SHADOW" in h),
        ("shadow fermé imbriqué dans un shadow", lambda h, r: has(h, "OUTER", "NESTED-CLOSED")),
        ("feuille adoptée du shadow capturée", lambda h, r: ".o{" in h.replace(" ", "") or ".o {" in h),
        ("<style> du shadow conservé", lambda h, r: ".box" in h and ".c{" in h.replace(" ", "") or ".c {" in h),
        ("bouton avec écouteur marqué data-oree-live", lambda h, r: re.search(r'<button[^>]*data-oree-live', h) is not None),
    ]),
    ("canvas 2D et WebGL", "canvas.html", 2, 1.0, [
        ("plus aucun <canvas> dans le fantôme", lambda h, r: "<canvas" not in h),
        ("canvas 2D en image (PNG)", lambda h, r: "data:image/png" in h),
        ("canvas WebGL en image (instantané du rectangle)", lambda h, r: "data:image/jpeg" in h),
    ]),
    ("vidéos", "video.html", 4, 3.0, [
        ("plus aucun <video> dans le fantôme", lambda h, r: "<video" not in h),
        ("deux images de vidéo (même origine + instantané cross-origin)", lambda h, r: h.count("data:image/jpeg") >= 2),
    ]),
    ("iframes", "iframes.html", 3, 1.5, [
        ("deux iframes pointent vers un document conservé", lambda h, r: h.count('src="data:text/html;charset=utf-8;base64,') >= 2),
        ("contenu des deux frames conservé (même origine + cross-origin)", lambda h, r: h.count("INNER-FRAME") >= 2),
        ("l'iframe cross-origin ne recharge plus son adresse", lambda h, r: f'src="http://127.0.0.1:{OTHER}' not in h),
    ]),
]

def main():
    clip = os.path.join(FIXTURE, "clip.mp4")
    if not os.path.exists(clip) and shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=3:size=320x180:rate=15",
                        "-pix_fmt", "yuv420p", clip], check=False)
    servers = [serve(PORT), serve(OTHER)]
    tmp = tempfile.mkdtemp(prefix="ghostfixture-")
    dump = os.path.join(tmp, "ghost.html")
    before = pids()
    extra = [x for k in ("HB_GHOST_PROBE", "HB_GHOST_SETTLE") if k in os.environ for x in ("--env", f"{k}={os.environ[k]}")]
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_GHOST=1", "--env", f"HB_GHOST_DUMP={dump}", *extra, APP, "--args", "--automation"])
    time.sleep(5)
    mine = pids() - before
    total = failed = 0
    try:
        wanted = sys.argv[1:]          # optional: only these pages (file names)
        for name, page, wait, max_diff, checks in PAGES:
            if wanted and page not in wanted: continue
            if page == "video.html" and not os.path.exists(clip):
                print(f"\n{name}: ignoré (ffmpeg absent, pas de clip de test)"); continue
            if os.path.exists(dump): os.remove(dump)
            ui("load", f"http://127.0.0.1:{PORT}/{page}"); time.sleep(wait)
            live, ghost = os.path.join(tmp, "live.png"), os.path.join(tmp, "ghost.png")
            ok, out = ui("ghost", live, ghost)
            print(f"\n{name}")
            if not ok or not os.path.exists(dump):
                print("  ÉCHEC  la capture n'a rien produit :", out[:120]); total += 1; failed += 1; continue
            report, html = json.loads(out), expand(open(dump, encoding="utf-8").read())
            if report.get("probe"): print("  sonde :", report["probe"])
            results = [(c, bool(f(html, report))) for c, f in checks]
            d = min(diff_pct(live, ghost), diff_pct(live.replace(".png", "-after.png"), ghost))
            results.append((f"fantôme = page vivante (écart {d:.2f} % ≤ {max_diff} %)", d <= max_diff))
            if d > max_diff:
                for suffix in ("live", "ghost"): shutil.copy(os.path.join(tmp, f"{suffix}.png"), os.path.join(tmp, f"{page}-{suffix}.png"))
            for c, passed in results:
                print(("  ok     " if passed else "  ÉCHEC  ") + c)
            total += len(results); failed += sum(1 for _, p in results if not p)
    finally:
        for p in mine: subprocess.run(["kill", p])
        for s in servers: s.shutdown()
    print(f"\n{total - failed}/{total} vérifications passent   (captures : {tmp})")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
