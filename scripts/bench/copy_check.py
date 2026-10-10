#!/usr/bin/env python3
"""End-to-end check of clean copy on a local fixture (no network): selects text in a styled page, copies it with the real
copy command and reads the macOS pasteboard back. Starts its own Orée instance (never touches yours). Exit 1 on any failure.

  python3 scripts/bench/copy_check.py

The "source" mode is a setting; the script switches it on for one case and puts the previous value back afterwards.
"""
import functools, http.server, json, os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "copy_fixture")
PORT, DOMAIN = 8784, "com.nolhan.hyperbrowser"

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def copy(js_select):
    """Runs the selection script, copies, returns (plain, html) from the pasteboard."""
    ui("eval", js_select); time.sleep(0.3)
    ui("tab", "copy", "0"); time.sleep(0.4)
    out = ui("tab", "pasteboard", "0")
    plain = out.split("[public.utf8-plain-text]\n", 1)[1].split("\n[public.html]")[0]
    html = out.split("[public.html]", 1)[1].lstrip("\n")
    return plain, html   # html is "" / "(none)" when the page's clipboard has no HTML

def select(el): return f"(function(){{var s=getSelection();s.selectAllChildren(document.getElementById('{el}'));return 1}})()"

def launch_and_load():
    ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(3)

def main():
    server, before = serve(), pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    previous = subprocess.run(["defaults", "read", DOMAIN, "settings.copyAddsSource"], capture_output=True, text=True)
    try:
        launch_and_load()
        plain, html = copy(select("styled"))
        print("\ntexte stylé :", repr(plain), "\n  html :", repr(html[:80]))
        check("texte brut propre, sans le texte caché", plain == "Les tomates aiment le soleil et l'eau.")
        check("aucun HTML sur le presse-papiers (la destination garde son style)", html in ("", "(none)"))

        plain, html = copy(select("list"))
        check("les listes gardent leurs lignes", plain.strip() == "Arroser le matin\nPailler le sol")

        plain, html = copy(select("table"))
        print("\ntableau :", repr(plain))
        rows = [r.split("\t") for r in plain.strip("\n").split("\n")]
        check("tableau : texte séparé par des tabulations, 3 lignes de 3 colonnes", len(rows) == 3 and all(len(r) == 3 for r in rows))
        check("tableau : cellule vide conservée", rows[2][1] == "" and rows[2][2] == "3 août")

        plain, _ = copy("(function(){var r=document.createRange();var t=document.querySelector('#table tr:nth-child(2)');r.setStart(t.cells[1].firstChild,0);r.setEnd(t.cells[2].firstChild,4);getSelection().removeAllRanges();getSelection().addRange(r);return 1})()")
        check("sélection partielle de cellules : 2 colonnes copiées", plain.strip() == "420\t12 j")

        plain, _ = copy(select("own"))
        check("une page qui gère elle-même la copie est respectée", plain == "COPIE-PAR-LA-PAGE")

        ui("tab", "copy", "0")
        copy(select("addr")); time.sleep(0.8)
        notice = ui("tab", "notice", "0")
        check(f"adresse copiée : l'offre « Ouvrir dans Plans » apparaît ({notice})", "Adresse" in notice)
        copy(select("quote")); time.sleep(0.5)

        ui("eval", "document.getElementById('field').select()"); time.sleep(0.3)
        ui("tab", "copy", "0"); time.sleep(0.3)
        out = ui("tab", "pasteboard", "0")
        check("copie depuis un champ de saisie : laissée au système", "champ de saisie" in out)

        subprocess.run(["defaults", "write", DOMAIN, "settings.copyAddsSource", "-bool", "true"]); time.sleep(1.5)
        launch_and_load(); ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(3)
        plain, html = copy(select("quote"))
        print("\ncitation avec source :", repr(plain[-160:]))
        check("source ajoutée au texte avec un lien vers le passage", "— Carnet de jardin (http://127.0.0.1" in plain and "#:~:text=" in plain)
        short, _ = copy(select("title"))
        check("un texte court n'est pas une citation : pas de source", "#:~:text=" not in short)
    finally:
        if previous.returncode == 0: subprocess.run(["defaults", "write", DOMAIN, "settings.copyAddsSource", "-bool", "true" if previous.stdout.strip() in ("1", "true") else "false"])
        else: subprocess.run(["defaults", "delete", DOMAIN, "settings.copyAddsSource"], capture_output=True)
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
