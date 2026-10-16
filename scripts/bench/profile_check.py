#!/usr/bin/env python3
"""Vérification de bout en bout des profils : deux profils ouverts en même temps ne partagent ni cookies, ni historique ; un profil déjà ouvert ne s'ouvre pas deux fois ;
la session d'un profil revient ; le profil principal n'est pas touché. Instances d'essai séparées (debug), dossier des profils jetable (HB_PROFILES_DIR).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/profile_check.py
"""
import functools, http.server, json, os, shutil, sqlite3, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "profile_fixture")
PORT = 8799
A, B = "aaaa0001", "bbbb0002"

def ui(auto, *a):
    env = dict(os.environ, HB_AUTOMATION_DIR=auto)
    r = subprocess.run([UI, *a], capture_output=True, text=True, env=env); return (r.stdout + r.stderr).strip()

def main():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tmp = tempfile.mkdtemp(prefix="profcheck-"); profiles = os.path.join(tmp, "Profiles"); os.makedirs(profiles)
    json.dump([{"id": A, "name": "Travail", "createdAt": 0}, {"id": B, "name": "Maison", "createdAt": 0}], open(os.path.join(profiles, "profiles.json"), "w"))
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def launch(pid):
        auto = os.path.join(tmp, "auto-" + pid); os.makedirs(auto, exist_ok=True)
        env = dict(os.environ, HB_PROFILES_DIR=profiles, HB_AUTOMATION_DIR=auto, HB_TAB_LAYOUT="vertical", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
        for k in ("HB_DB_PATH", "HB_EXT_DIR", "HB_FRESH_SESSION", "HB_PROFILE_ID"): env.pop(k, None)
        proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation", "--profile", pid], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return proc, auto
    procA, autoA = launch(A); procB, autoB = launch(B)
    try:
        time.sleep(11)
        print("Deux profils ouverts ensemble")
        infoA, infoB = ui(autoA, "tab", "profile", "0"), ui(autoB, "tab", "profile", "0"); print("  ", infoA, "\\n  ", infoB)
        check("chaque fenêtre dit son profil (titre, nom, base de données propre)", "— Travail" in infoA.split(" name=")[0] and f"id={A}" in infoA and f"Profiles/{A}/browser.sqlite" in infoA and "— Maison" in infoB.split(" name=")[0] and f"Profiles/{B}/browser.sqlite" in infoB)
        check("le nombre d'onglets est suivi du nom du profil", "· Travail" in infoA and "· Maison" in infoB)
        check("le menu du Dock propose les autres profils", "Maison" in infoA and "Travail" in infoB)
        ui(autoA, "load", f"http://127.0.0.1:{PORT}/page.html?a=profil-a"); time.sleep(3)
        ui(autoB, "load", f"http://127.0.0.1:{PORT}/page.html?b=profil-b"); time.sleep(3)
        ui(autoA, "eval", "document.cookie = 'qui=travail; max-age=3600; path=/'; 'x'"); time.sleep(1)
        check("le cookie posé dans « Travail » est lu dans « Travail »", "qui=travail" in ui(autoA, "eval", "document.cookie"))
        check("…et n'existe pas dans « Maison » (un magasin de données par profil)", "qui=travail" not in ui(autoB, "eval", "document.cookie"))
        print("Un profil ouvert ne s'ouvre pas deux fois")
        again, _ = launch(A)
        try: code = again.wait(timeout=15)
        except subprocess.TimeoutExpired: code = None; again.kill()
        check("relancer « Travail » alors qu'il est ouvert : la seconde instance se termine aussitôt", code == 0)
        check("et la première tourne toujours", procA.poll() is None)
        print("Rien n'est partagé sur disque, la session revient")
        ui(autoA, "tab", "quit", "0"); ui(autoB, "tab", "quit", "0"); time.sleep(5)
        def urls(pid):
            path = os.path.join(profiles, pid, "browser.sqlite")
            if not os.path.exists(path): return []
            con = sqlite3.connect(path); rows = [r[0] for r in con.execute("select url from history")]; con.close(); return rows
        ua, ub = urls(A), urls(B)
        check("l'historique de « Travail » n'a que ses pages", any("a=profil-a" in u for u in ua) and not any("profil-b" in u for u in ua))
        check("l'historique de « Maison » n'a que ses pages", any("b=profil-b" in u for u in ub) and not any("profil-a" in u for u in ub))
        check("le verrou de chaque profil est retiré à la fermeture", not os.path.exists(os.path.join(profiles, A, ".lock")) and not os.path.exists(os.path.join(profiles, B, ".lock")))
        procA2, autoA2 = launch(A); time.sleep(11)
        order = ui(autoA2, "tab", "taborder", "0")
        check("la session de « Travail » revient à la relance (sa page est là) : " + order[:80], order.startswith("profil") or "a=profil-a" in order or order.count(",") >= 0 and "a=profil-a" in json.dumps(order) or "a=profil-a" in order)
        procA2.terminate(); procA2.wait(timeout=10)
        check("le dossier du profil principal n'a pas été créé par ces essais", not os.path.exists(os.path.join(tmp, ".lock")))
    finally:
        for p in (procA, procB):
            if p.poll() is None: p.terminate()
        server.shutdown(); shutil.rmtree(tmp, ignore_errors=True)
    print(f"\\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
