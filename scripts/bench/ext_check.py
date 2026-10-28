#!/usr/bin/env python3
"""Extensions dans Orée : 5 extensions d'essai (scripts/bench/ext/*) de formes différentes — popup MV3, popup MV2 + page de fond, script de contenu + pastille,
messages entre popup et service worker, options_ui — installées dans une instance de développement ; pour chacune on clique le bouton, on lit ce que le popup affiche
(rendu, taille) et on ouvre ses réglages.

  OREE_TEST_APP=/chemin/OreeTest.app (construite avec ./build_app.sh --debug) python3 scripts/bench/ext_check.py
"""
import json, os, subprocess, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

def jo(s):
    try: return json.loads(s)
    except Exception: return {"raw": s}

if __name__ == "__main__":
    tmp = tempfile.mkdtemp(prefix="ext-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext")); os.environ["HB_AUTOMATION_DIR"] = auto
    hosts = os.path.join(tmp, "hosts"); os.makedirs(hosts)
    cid = open(os.path.join(ROOT, "scripts/bench/ext/native-host/ID.txt")).read().strip()
    json.dump({"name": "com.oree.test_host", "description": "essai", "path": os.path.join(ROOT, "scripts/bench/ext/native-host/host.py"), "type": "stdio", "allowed_origins": [f"chrome-extension://{cid}/"]}, open(os.path.join(hosts, "com.oree.test_host.json"), "w"))
    env = dict(os.environ, HB_NATIVE_HOSTS_DIR=hosts, HB_FRESH_SESSION="1", HB_EXT_CONTROLLER_ID=str(__import__("uuid").uuid4()).upper(), HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"))
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    def check(name, ok, detail=""): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name + (f"   [{detail}]" if detail and not ok else ""))
    try:
        time.sleep(8); print("   page :", ui("load", "https://example.com")); time.sleep(4)
        names = ["popup-mv3", "popup-mv2", "content-badge", "messaging", "options-ui", "api-compat", "debugger-test", "native-apis", "system-apis", "native-host"]
        for n in names:
            r = ui("install", os.path.join(ROOT, "scripts/bench/ext", n)); time.sleep(1); check(f"installe {n}", r == "installed", r)
        time.sleep(3)
        print("   rapport :", ui("extensions")[:400])
        ui("load", "https://example.com"); time.sleep(3)
        check("le script de contenu a agi sur la page", ui("eval", "document.documentElement.getAttribute('data-ext-c')") == "injected")
        # l'ordre des extensions = l'ordre d'installation
        for i, (n, title, body) in enumerate([("popup-mv3", "POPUP-A", ""), ("popup-mv2", "POPUP-B", "bg=ready-B"), ("content-badge", None, None), ("messaging", "POPUP-D", "reponse=pong"), ("options-ui", "POPUP-E", "")]):
            r = jo(ui("extop", f"popup:{i}")); print("   popup", n, r)
            if title is None: check(f"{n} : pas de popup, pas de plantage ni de fenêtre vide", r.get("shown") is False, str(r)); continue
            check(f"{n} : le popup s'ouvre", r.get("shown") is True, str(r))
            check(f"{n} : le popup est rendu (titre {title})", r.get("title") == title, str(r))
            if body: check(f"{n} : le contenu dynamique est là ({body})", body in (r.get("body") or ""), str(r))
            w, _, h = (r.get("wanted") or r.get("size") or "0x0").partition("x"); check(f"{n} : le popover a une taille", int(w or 0) > 50 and int(h or 0) > 30, str(r))
        r = jo(ui("extop", "popup:5")); res = {}
        try: res = json.loads(r.get("title") or "{}")
        except Exception: pass
        print("   api-compat", res.get("__sw"))
        for name, v in res.items():
            if name != "__sw": check(f"API ajoutées : {name}", v is True, str(v))
        check("API ajoutées : le popup a bien rendu ses résultats", len(res) >= 8, str(r))
        ui("load", "https://example.com"); time.sleep(3)
        r = jo(ui("extop", "popup:6")); res = {}
        try: res = json.loads(r.get("title") or "{}")
        except Exception: pass
        for name, v in res.items(): check(f"chrome.debugger : {name}", v is True, str(v))
        check("chrome.debugger : le test s'est exécuté", len(res) >= 15, str(r)[:300])
        r = jo(ui("extop", "popup:7")); res = {}
        try: res = json.loads(r.get("title") or "{}")
        except Exception: pass
        for name, v in res.items(): check(f"API natives : {name}", v is True, str(v))
        check("API natives : le test s'est exécuté", len(res) >= 14, str(r)[:300])
        ui("load", "https://example.com"); time.sleep(3)
        ui("extop", "popupstart:8"); r = jo(ui("extop", "popupread:8")); res = {}
        try: res = json.loads(r.get("title") or "{}")
        except Exception: pass
        for name, v in res.items(): check(f"API système : {name}", v is True, str(v))
        check("API système : le test s'est exécuté", len(res) >= 14, str(r)[:300])
        ui("extop", "popupstart:9"); r = jo(ui("extop", "popupread:9")); res = {}
        try: res = json.loads(r.get("title") or "{}")
        except Exception: pass
        for name, v in res.items(): check(f"Messagerie native : {name}", v is True, str(v))
        check("Messagerie native : le test s'est exécuté", len(res) >= 3, str(r)[:300])
        for i, (n, title) in enumerate([("popup-mv3", "OPTIONS-A"), ("popup-mv2", "OPTIONS-B"), ("content-badge", None), ("messaging", None), ("options-ui", "OPTIONS-E")]):
            r = jo(ui("extop", f"options:{i}")); print("   options", n, r)
            if title is None: check(f"{n} : sans réglages, rien ne s'ouvre", r.get("opened") is False, str(r)); continue
            check(f"{n} : les réglages s'ouvrent et s'affichent ({title})", r.get("opened") is True and r.get("title") == title, str(r))
    finally:
        p.terminate()
    print(f"\n{sum(results)}/{len(results)} vérifications réussies"); raise SystemExit(0 if all(results) else 1)
