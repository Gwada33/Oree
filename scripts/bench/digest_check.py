#!/usr/bin/env python3
"""End-to-end check of « L'essentiel » on local pages (no network): a recipe that carries structured data (read exactly,
instantly), a recipe written as prose (read by the local model, ~30 s, skipped if Apple Intelligence is unavailable) and a page
with nothing to summarize. Starts its own Orée instance (never touches yours). Exit 1 on any failure.

  python3 scripts/bench/digest_check.py
"""
import functools, http.server, os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "digest_fixture")
PORT = 8788

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def get(): return ui("tab", "digestget", "0")
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
        print("\nRecette avec données structurées")
        ui("load", f"http://127.0.0.1:{PORT}/recipe.html"); time.sleep(3)
        check("la page est reconnue comme recette (4 ingrédients, 3 étapes)", wait_for(lambda: "candidate=recipe:4i/3s" in get(), 8))
        check("l'essentiel s'ouvre tout seul sur une recette, sans modèle, en quelques secondes", wait_for(lambda: "state=ready" in get(), 6))
        ui("tab", "digest", "0"); time.sleep(0.5)
        check("le bouton ferme le panneau", "state=closed" in get())
        ui("tab", "digest", "0")
        check("et le rouvre aussitôt", wait_for(lambda: "state=ready" in get(), 3))
        out = get(); print("  ", out[:260])
        check("ingrédients, étapes et temps sont là", all(x in out for x in ("250 g de farine", "4 œufs", "Cuire dans une poêle", "Préparation : 10 min", "Cuisson : 20 min")))
        check("le blabla n'y est pas", "cigales" not in out and "grand-mère, souvenir" not in out)
        open("/tmp/oree-digest-servings.txt", "w").write("24")
        ui("tab", "digestservings", "0"); time.sleep(1.2)
        scaled = ui("tab", "aiget", "0")
        print("  ", scaled[:200])
        check("le curseur de personnes recalcule les quantités (12 → 24 crêpes : 500 g de farine, 8 œufs)", "500 g de farine" in scaled and "8 œufs" in scaled and "24 crêpes" in scaled)
        ui("action", "reloadAction"); time.sleep(5)
        check("le pop-up reste après un rechargement de la page", "state=ready" in get())
        r = ui("tab", "digestcook", "0")
        check(f"mode cuisine : l'écran reste allumé ({r})", "cooking=true" in r and "screenHeld=true" in r)
        ui("tab", "digest", "0"); time.sleep(0.5)
        check("fermer le pop-up libère l'écran et quitte le mode cuisine", "state=closed" in get() and "screenHeld=false" in ui("tab", "digestcook", "0") + ui("tab", "digestcook", "0"))
        ui("tab", "digest", "0"); time.sleep(0.5); ui("tab", "digest", "0"); time.sleep(0.5)       # reopened, closed again: on purpose
        ui("action", "reloadAction"); time.sleep(5)
        check("fermé volontairement, il ne se rouvre pas tout seul au rechargement", "state=closed" in get())

        print("\nPage sans rien à résumer")
        ui("load", f"http://127.0.0.1:{PORT}/plain.html"); time.sleep(2.5)
        check("aucun bouton (pas de données structurées)", "candidate=none" in get())
        ui("tab", "digest", "0"); time.sleep(3)
        check("message clair quand il n'y a pas assez de texte", "state=message" in get() or "state=busy" in get())
        ui("tab", "digest", "0")

        print("\nRecette écrite en prose (modèle local)")
        ui("load", f"http://127.0.0.1:{PORT}/prose.html"); time.sleep(2.5)
        ui("tab", "digest", "0"); time.sleep(2)
        out = get()
        if "state=message" in out and "Apple Intelligence" in out:
            print("  ignoré : modèle local indisponible")
        else:
            check("le modèle travaille (écran d'attente)", "state=busy" in out or "state=ready" in out)
            done = wait_for(lambda: "state=busy" not in get(), 170)
            out = get(); print("  ", out[:420])
            check("le résumé s'affiche", done and "state=ready" in out)
            check("les ingrédients de la page y sont", "pommes de terre" in out and "crème" in out)
            check("les étapes de la page y sont", "ail" in out and ("rondelles" in out or "160" in out))
            check("le blabla n'y est pas", "cigales" not in out)
        ui("tab", "digest", "0")
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
