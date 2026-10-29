#!/usr/bin/env python3
"""Applications (un site devient une application) : installation depuis la page ouverte, fenêtre sans onglets, raccourci « Nom.app » (Info.plist, lanceur, icône, signature),
ouverture par oree-app://, liens hors du site, retrait.

  OREE_TEST_APP=/chemin/OreeTest.app (construite avec ./build_app.sh --debug) python3 scripts/bench/webapp_check.py
"""
import json, os, plistlib, subprocess, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

if __name__ == "__main__":
    tmp = tempfile.mkdtemp(prefix="webapp-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.environ["HB_AUTOMATION_DIR"] = auto
    store, apps = os.path.join(tmp, "store"), os.path.join(tmp, "Applications"); os.makedirs(apps)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_EXT_CONTROLLER_ID=str(__import__("uuid").uuid4()).upper(), HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AI_NO_AGENT="1",
               HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"), HB_WEBAPPS_STORE=store, HB_WEBAPPS_APPLICATIONS_DIR=apps, HB_WEBAPPS_AUTOCONFIRM="1", HB_WEBAPPS_MODE=os.environ.get("MODE", "standalone"))
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok, detail=""): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name + (f"   [{detail}]" if detail and not ok else ""))
    try:
        time.sleep(8); ui("load", "https://example.com"); time.sleep(4)
        ui("action", "installWebAppAction"); time.sleep(7)
        listed = json.load(open(os.path.join(store, "apps.json"))) if os.path.exists(os.path.join(store, "apps.json")) else []
        check("l'application est enregistrée", len(listed) == 1 and listed[0]["startURL"].startswith("https://example.com"), str(listed))
        name = listed[0]["name"] if listed else "?"; aid = listed[0]["id"] if listed else "?"
        check("son icône est gardée (PNG)", os.path.exists(os.path.join(store, "icons", aid + ".png")) and open(os.path.join(store, "icons", aid + ".png"), "rb").read(8) == b"\x89PNG\r\n\x1a\n")
        bundle = os.path.join(apps, name + ".app")
        check("le raccourci « Nom.app » existe", os.path.isdir(bundle), str(os.listdir(apps)))
        plist = {}
        try: plist = plistlib.load(open(os.path.join(bundle, "Contents/Info.plist"), "rb"))
        except Exception as e: print("   plist :", e)
        standalone = os.environ.get("MODE", "standalone") == "standalone"
        want = "OreeWebApp" if standalone else "OreeAppLauncher"
        check(f"Info.plist : exécutable {want}, identifiant de l'application, chemin d'Orée", plist.get("CFBundleExecutable") == want and plist.get("OreeAppID") == aid and plist.get("OreePath", "").endswith(".app"), str(plist))
        exe = os.path.join(bundle, "Contents/MacOS/" + want)
        if standalone:
            check("indépendante : les règles de blocage et le CSS sont dans l'application", os.path.exists(os.path.join(bundle, "Contents/Resources/rules-0.json")) and os.path.exists(os.path.join(bundle, "Contents/Resources/cosmetic.css")), str(os.listdir(os.path.join(bundle, "Contents/Resources"))))
            sup = os.path.join(tmp, "support"); os.makedirs(sup)
            run = lambda: subprocess.run([exe, "--selftest"], capture_output=True, text=True, env=dict(os.environ, OREEWEBAPP_SUPPORT_DIR=sup), timeout=60).stdout.strip().splitlines()
            first = json.loads((run() or ["{}"])[-1]); second = json.loads((run() or ["{}"])[-1])
            print("   1er lancement :", first.get("timings")); print("   2e lancement  :", second.get("timings"))
            check("l'application indépendante se lance seule et charge son site", first.get("title") == "Example Domain", str(first))
            check("2e lancement : la dernière image est montrée avant la page", "imageMontree" in second.get("timings", {}) and second["timings"]["imageMontree"] < second["timings"].get("pageFinie", 1e9), str(second))
            check("2e lancement : la session de la page est restaurée", "etatRestaure" in second.get("timings", {}), str(second))
        check("le lanceur est exécutable", os.access(exe, os.X_OK))
        check("l'icône .icns est faite", os.path.exists(os.path.join(bundle, "Contents/Resources/AppIcon.icns")) and os.path.getsize(os.path.join(bundle, "Contents/Resources/AppIcon.icns")) > 1000)
        check("le raccourci est signé", subprocess.run(["codesign", "--verify", bundle], capture_output=True).returncode == 0)
        wins = ui("tab", "windows", "0"); print("   fenêtres :", wins[:200])
        if not standalone:
            check("une fenêtre d'application est ouverte", f"app:{name}" in wins, wins)
            check("elle n'a qu'un onglet", f"app:{name} tabs=1" in wins, wins)
            time.sleep(2)
            check("liens : le site reste, un autre site sort", "inScope=true outScope=true" in ui("tab", "appsend", "0"), ui("tab", "appsend", "0"))
        # on la ferme (fermeture de la fenêtre), puis on la rouvre par oree-app://
        ui("tab", "removeapp", "0") if False else None
        wins2 = wins
        if not standalone: print("   ouverture :", ui("tab", "openapp", "0")); time.sleep(2); wins2 = ui("tab", "windows", "0")
        if not standalone: check("oree-app:// ramène la fenêtre existante (pas de doublon)", wins2.count("app:") == 1, wins2)
        print("   retrait :", ui("tab", "removeapp", "0")); time.sleep(2)
        check("le retrait enlève l'application, son raccourci et sa fenêtre", json.load(open(os.path.join(store, "apps.json"))) == [] and not os.path.exists(bundle) and "app:" not in ui("tab", "windows", "0"))
    finally:
        p.terminate()
    print(f"\n{sum(results)}/{len(results)} vérifications réussies"); raise SystemExit(0 if all(results) else 1)
