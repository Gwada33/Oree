#!/usr/bin/env python3
"""End-to-end check of page translation on a local English fixture (no network). Starts its own Orée instance
(never touches yours), translates the page with the system Translation framework and checks what was and was not
translated, then restores the original and checks it is byte-identical. Exit 1 if anything fails.

  python3 scripts/bench/translate_check.py

Needs macOS 26+ with the English -> your language models installed (Réglages Système > Général > Langue et région >
Langues de traduction). The model translates ~3 segments a second, so a run takes about a minute.
"""
import functools, http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "translate_fixture")
PORT = 8783

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def js(expr):
    ok, out = ui("eval", f"JSON.stringify({expr})")
    try: return json.loads(out)
    except Exception: return None

def text(sel): return js(f"document.querySelector({json.dumps(sel)}).textContent")

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self):
            self.send_header("Cache-Control", "no-store"); super().end_headers()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

def report(): return ui("tab", "translation", "0")[1]

def wait_for(predicate, timeout):
    """Polls: the page-side script reports changes after a debounce, and a hidden test window throttles timers."""
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(1)
    return False

def wait_idle(timeout):
    """Until the translator has settled (translated and no round running)."""
    end = time.time() + timeout
    while time.time() < end:
        r = report()
        if "state=translated" in r and "working=false" in r: return True
        if "state=idle" in r: return False
        time.sleep(1)
    return False

def main():
    server, before = serve(), pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", APP, "--args", "--automation"])
    time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append((name, bool(ok))); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(8)       # the page adds a paragraph after 6 s
        original = js("document.documentElement.outerHTML")
        original_title = js("document.title")
        print("\nlangue reconnue :", report())
        check("la langue de la page est reconnue (en)", "lang=en" in report())

        t0 = time.time(); ui("tab", "translate", "0")
        first = None
        while time.time() - t0 < 90:
            if first is None and text("#h1") and "committee" not in text("#h1"): first = time.time() - t0
            if "state=translated" in report(): break
            time.sleep(0.5)
        done = wait_idle(180); total = time.time() - t0
        print(f"\n1er texte traduit en {first and round(first, 1)} s, tout l'écran en {total:.0f} s   ({report()})")
        check("la traduction se termine", done)
        check("le titre H1 est traduit", text("#h1") and "committee" not in text("#h1") and "comité" in text("#h1").lower())
        check("le titre de l'onglet est traduit", js("document.title") != original_title)
        check("le texte dans le Shadow DOM est traduit", js("document.getElementById('host').shadowRoot.querySelector('p').textContent") != "Welcome to the shadow garden")
        check("le placeholder est traduit", js("document.getElementById('field').placeholder") != "Search the archive")
        check("le title d'un bouton est traduit", js("document.getElementById('btn').title") != "Open the settings panel")
        check("l'alt d'une image est traduit", js("document.getElementById('img').alt") != "A red tomato on a wooden table")
        check("le prix et l'année ne changent pas", text("#price") == "12,99 € — 2026")
        check("translate=\"no\" est respecté", text("#skip") == "DO-NOT-TRANSLATE brand name")
        check(".notranslate est respecté", text("#skip2") == "Another protected sentence")
        check("<code> et <pre> ne changent pas", text("#code") == "npm install tomatoes" and text("#pre") == 'const greeting = "hello world"')
        check("la zone éditable ne change pas", text("#editable") == "This sentence is being edited by the reader")
        check("la valeur tapée par l'utilisateur ne change pas", js("document.getElementById('field').value") == "typed by the user")
        check("le texte coupé par un <b> est traduit en 3 morceaux (limite connue)", text("#inline") != "Click here to continue reading about tomatoes.")
        check("le paragraphe lointain n'est pas encore traduit (paresseux)", "far below" in (text("#far") or ""))
        check("le menu caché n'est pas encore traduit", "Terms of service" in (text("#menu") or ""))
        check("le contenu ajouté par la page est traduit", text("#late") and "loaded after" not in text("#late"))

        ui("eval", "window.scrollTo(0, document.body.scrollHeight)")
        check("le paragraphe lointain est traduit après défilement", wait_for(lambda: "far below" not in (text("#far") or "far below"), 90))
        ui("eval", "window.scrollTo(0, 0)")                               # a menu far from the screen is left for later, by design
        ui("eval", "document.getElementById('open').click()")
        check("le menu est traduit une fois ouvert", wait_for(lambda: "Terms of service" not in (text("#menu") or "Terms of service"), 90))
        wait_idle(60)

        ui("tab", "untranslate", "0"); time.sleep(1.5)
        js("(document.getElementById('menu').removeAttribute('class'), 1)")
        restored = js("document.documentElement.outerHTML")
        if restored != original:
            i = next((k for k, (a, b) in enumerate(zip(original, restored or "")) if a != b), min(len(original), len(restored or "")))
            print("  différence près de :", repr(original[max(0, i - 40):i + 60]), "\n  devenu             :", repr((restored or "")[max(0, i - 40):i + 60]))
        check("l'original est restitué à l'identique", restored == original)
        check("le titre de l'onglet est restitué", js("document.title") == original_title)
        check("le traducteur est au repos", "state=idle" in report())
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    failed = sum(1 for _, ok in results if not ok)
    print(f"\n{len(results) - failed}/{len(results)} vérifications passent")
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
