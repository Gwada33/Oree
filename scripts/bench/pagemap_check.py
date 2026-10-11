#!/usr/bin/env python3
"""End-to-end check of the page map (« les yeux » de l'IA) on local pages, in a separate Orée instance (never yours).
Gate of step 2 (Docs/ia.md): the map fits the budget, no secret comes out, references stay valid between two maps.

  python3 scripts/bench/pagemap_check.py
"""
import functools, http.server, os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pagemap_fixture")
PORT = 8789
BUDGET = 2500   # jetons estimés pour toute la carte

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def pagemap():
    ui("tab", "pagemap", "0")
    for _ in range(40):
        time.sleep(0.25)
        out = ui("tab", "pagemapget", "0")
        if out != "pending": return out
    return "pending"

def refs(text): return dict((m.group(2), m.group(1)) for m in re.finditer(r'@e(\d+) \S+ "([^"]*)"', text))

def main():
    server, before = serve(), pids()
    tmp = tempfile.mkdtemp(prefix="pagemap-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_AI_NO_AGENT=1"]
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nFormulaire de connexion")
        ui("load", f"http://127.0.0.1:{PORT}/login.html"); time.sleep(3)
        text = pagemap(); print(text)
        check("le titre et l'adresse sont là", 'PAGE http://127.0.0.1:%d/login.html "Connexion — Banque test"' % PORT in text)
        check("les champs ont leur libellé", all(x in text for x in ('"Adresse e-mail"', '"Mot de passe"', '"Se connecter"', '"Pays"')))
        check("le courriel est lu, la case cochée est vue", "nolhan@example.org" in text and "checked" in text)
        check("le mot de passe ne sort jamais", "SuperSecret123" not in text and "secret" in text)
        check("le numéro de carte ne sort jamais", "4111111111111111" not in text)
        check("les éléments cachés ou masqués n'y sont pas", "Lien caché" not in text and "Masqué aux lecteurs" not in text)
        check("le bouton désactivé est signalé", re.search(r'"Désactivé" disabled', text) is not None)
        check("le texte de la page est là", "[h1] Connexion" in text)

        print("\nGrande page (120 liens)")
        ui("load", f"http://127.0.0.1:{PORT}/long.html"); time.sleep(3)
        text = pagemap()
        tokens = int(re.search(r"tokens≈(\d+)", text).group(1)) if "tokens≈" in text else 99999
        print("  jetons estimés :", tokens)
        check(f"la carte tient dans le budget ({BUDGET} jetons)", tokens <= BUDGET)
        check("60 éléments au plus, le reste est compté", len(re.findall(r"^@e\d+ ", text, re.M)) <= 60 and re.search(r"AUTRES \+\d+", text))
        first = refs(text)

        print("\nRéférences entre deux cartes")
        again = refs(pagemap())
        common = set(first) & set(again)
        check("les mêmes éléments gardent la même référence", len(common) > 20 and all(first[k] == again[k] for k in common))
        ui("eval", "window.scrollTo(0, document.body.scrollHeight)"); time.sleep(1)
        scrolled = refs(pagemap())
        check("après un défilement, un élément déjà vu garde sa référence", all(first[k] == scrolled[k] for k in set(first) & set(scrolled)) and set(scrolled) != set(first))

        print("\nPage qui remplace ses champs")
        ui("load", f"http://127.0.0.1:{PORT}/react.html"); time.sleep(3)
        a = refs(pagemap())
        ui("eval", "window.rerender()"); time.sleep(0.5)
        b = refs(pagemap())
        check("le champ conservé garde sa référence", a.get("Nom") == b.get("Nom") and a.get("Nom"))
        check("le champ remplacé reçoit une nouvelle référence", a.get("Ville") and b.get("Ville") and a["Ville"] != b["Ville"])
    finally:
        for pid in mine: subprocess.run(["kill", pid])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    sys.exit(0 if all(results) else 1)

if __name__ == "__main__": main()
