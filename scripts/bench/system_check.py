#!/usr/bin/env python3
"""Vérification de bout en bout des intégrations Mac (menu du Dock, menu Services, Spotlight), dans une instance d'essai séparée (debug).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/system_check.py
"""
import os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def main():
    tmp = tempfile.mkdtemp(prefix="syscheck-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext"))
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto, HB_SPOTLIGHT="1", HB_GESTURES="1")
    os.environ["HB_AUTOMATION_DIR"] = auto
    for f in ("/tmp/oree-spot.txt", "/tmp/oree-spot-found.txt"):
        if os.path.exists(f): os.remove(f)
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        time.sleep(9)
        print("Menu du Dock")
        menu = ui("tab", "dockmenu", "0"); print("  ", menu)
        check("nouvelle fenêtre, nouvel onglet, onglet privé", all(x in menu for x in ("Nouvelle fenêtre", "Nouvel onglet", "Nouvel onglet privé")))
        print("Menu Services")
        open("/tmp/oree-service.txt", "w").write("https://exemple.org/service-test"); out = ui("tab", "service", "0"); time.sleep(1.5)
        check("une adresse sélectionnée s'ouvre dans un nouvel onglet", "tabs 1→2" in out and "exemple.org/service-test" in out)
        open("/tmp/oree-service.txt", "w").write("météo à Lyon demain"); out = ui("tab", "service", "0"); time.sleep(1.5)
        check("un autre texte est cherché avec le moteur de recherche", "tabs 2→3" in out and "search" in out and "Lyon" in out)
        open("/tmp/oree-service.txt", "w").write("   "); out = ui("tab", "service", "0")
        check("un texte vide ne fait rien", "tabs 3→3" in out)
        check("le menu du Dock liste maintenant les onglets ouverts", "service-test" in ui("tab", "dockmenu", "0") or "exemple.org" in ui("tab", "dockmenu", "0"))
        print("Spotlight")
        ui("tab", "spotlightseed", "0"); time.sleep(4)
        check("l'indexation se termine sans erreur", open("/tmp/oree-spot.txt").read().strip() == "indexed error=nil" if os.path.exists("/tmp/oree-spot.txt") else False)
        found = ""
        for _ in range(4):
            ui("tab", "spotlightquery", "0"); time.sleep(6)
            found = open("/tmp/oree-spot-found.txt").read() if os.path.exists("/tmp/oree-spot-found.txt") else ""
            if found: break
        check("le favori et la page d'historique sont retrouvés par une recherche du système", "oree:https://exemple.org/spot" in found and "oree:https://exemple.net/hist" in found)
        ui("tab", "spotlightclear", "0")
        print("Mode responsive")
        ui("load", "https://example.com/"); time.sleep(4)
        def responsive(cmd):
            open("/tmp/oree-responsive.txt", "w").write(cmd); return ui("tab", "responsive", "2")      # le dernier onglet ouvert est l'onglet affiché
        out = responsive("1"); time.sleep(4); print("  ", out)
        check("l'appareil (iPhone 15) a sa largeur, avec sa barre, et se présente comme un iPhone", "slot=393x" in out and "bar=true" in out and "ua=iPhone" in out and "iPhone 15 · 393 × 852" in out)
        check("la page voit cette largeur et une identité d'iPhone", ui("eval", "innerWidth").strip() == "393" and "iPhone" in ui("eval", "navigator.userAgent"))
        out = responsive("rotate"); time.sleep(1)
        check("pivoter donne le paysage (réduit pour tenir si besoin)", "label=iPhone 15 · 852 × 393" in out and "slot=852x" in out)
        out = responsive("5"); time.sleep(3)
        check("un ordinateur garde l'identité de bureau", "ua=défaut" in out or "ua=autre" in out)
        out = responsive("off"); time.sleep(4)
        check("quitter rend toute la place à la page, sans barre", "bar=false" in out and out.split("slot=")[1].split()[0] == out.split("container=")[1].split()[0] and "iPhone" not in ui("eval", "navigator.userAgent"))
        print("Gestes de souris")
        def gesture(code):
            open("/tmp/oree-gesture.txt", "w").write(code); return ui("tab", "gesture", "2")
        ui("load", "https://example.com/"); time.sleep(3.5); ui("load", "https://www.iana.org/help/example-domains"); time.sleep(4)
        gesture("L"); time.sleep(3)
        check("← : page précédente", "example.com" in ui("eval", "location.href") and "iana" not in ui("eval", "location.href"))
        gesture("R"); time.sleep(3)
        check("→ : page suivante", "iana.org" in ui("eval", "location.href"))
        before = ui("tab", "dockmenu", "0").count("|")
        out = gesture("D"); time.sleep(1.5)
        check("↓ : nouvel onglet", "tabs=4" in out)
        out = gesture("DR"); time.sleep(1.5)
        check("↓→ : l'onglet se ferme", "tabs=3" in out)
    finally:
        proc.terminate(); proc.wait(timeout=10)
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
