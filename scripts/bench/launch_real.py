#!/usr/bin/env python3
"""Ouverture réelle : combien de temps entre `open` et la première fenêtre visible, en ouvrant un vrai site (aucun serveur local), pour Orée, Safari, Brave et Firefox.

  python3 scripts/bench/launch_real.py [passages] [navigateur ...]     # 10 passages + 1 d'échauffement jetée, tour à tour
Le temps est celui de la FENÊTRE (position publique, aucune autorisation) : il ne dit rien du chargement de la page du site.
Les navigateurs sont lancés avec un profil neuf (sauf Safari, qui n'en permet pas) ; ceux déjà ouverts par l'utilisateur ne sont jamais touchés.
Ne touchez pas au Mac pendant la mesure : les fenêtres passent au premier plan.
"""
import json, os, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = os.environ.get("WINWATCH") or os.path.join(HERE, "winwatch")
OREE = os.path.expanduser("~/HyperBrowser/Oree.app")
SITE = os.environ.get("SITE", "https://fr.wikipedia.org/wiki/Wikip%C3%A9dia:Accueil_principal")

def run(*a): return subprocess.run(a, capture_output=True, text=True)

class Browser:
    owner = ""
    def start(self, tmp): raise NotImplementedError
    def stop(self, pid, tmp): subprocess.run(["pkill", "-P", str(pid)]); os.kill(pid, 15); time.sleep(1.5); run("kill", "-9", str(pid))

class Oree(Browser):
    name, owner = "Orée", "oree"
    def start(self, tmp):
        run("open", "-n", "-a", OREE, "--env", "HB_FRESH_SESSION=1", "--env", f"HB_DB_PATH={tmp}/t.db", "--env", f"HB_TEST_KEYS_DIR={tmp}/keys", "--env", f"HB_EXT_DIR={tmp}/ext", "--args", SITE)
    def version(self): return run("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", f"{OREE}/Contents/Info.plist").stdout.strip()

class Safari(Browser):
    name, owner = "Safari", "safari"
    def start(self, tmp): run("open", "-a", "Safari", SITE)
    def stop(self, pid, tmp):
        run("osascript", "-e", 'tell application "Safari" to close every window'); run("osascript", "-e", 'tell application "Safari" to quit'); time.sleep(3)
    def version(self): return run("osascript", "-e", 'tell application "Safari" to get version').stdout.strip()

class Brave(Browser):
    name, owner = "Brave", "brave"
    def start(self, tmp): run("open", "-n", "-a", "Brave Browser", "--args", f"--user-data-dir={tmp}/brave", "--no-first-run", "--no-default-browser-check", "--disable-sync", SITE)
    def version(self): return run("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", "--version").stdout.strip()

class Firefox(Browser):
    name, owner = "Firefox", "firefox"
    def start(self, tmp):
        os.makedirs(f"{tmp}/ff", exist_ok=True)
        run("open", "-n", "-a", "Firefox", "--args", "-profile", f"{tmp}/ff", "-no-remote", "-new-window", SITE)
    def version(self): return run("/Applications/Firefox.app/Contents/MacOS/firefox", "--version").stdout.strip()

BROWSERS = {"oree": Oree(), "safari": Safari(), "brave": Brave(), "firefox": Firefox()}

def once(b):
    tmp = tempfile.mkdtemp(prefix="launchreal-")
    w = subprocess.Popen([WATCH, b.owner, "30"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    w.stdout.readline()                                # « prêt »
    w.stdin.write("\n"); w.stdin.flush()
    b.start(tmp)
    out = json.loads(w.stdout.readline() or '{"t": -1, "pid": 0}'); w.wait()
    time.sleep(2.5)                                    # laisse le navigateur finir de s'installer avant de le fermer
    if out["pid"]: b.stop(out["pid"], tmp)
    shutil.rmtree(tmp, ignore_errors=True); time.sleep(2)
    return out["t"]

if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    names = [n for n in sys.argv[2:] if n in BROWSERS] or list(BROWSERS)
    results = {n: [] for n in names}
    for i in range(runs + 1):
        for n in names:
            t = once(BROWSERS[n])
            if i == 0: print(f"  échauffement {n}: {t:.2f} s (jeté)"); continue
            results[n].append(t); print(f"  #{i} {n}: {t:.2f} s"); sys.stdout.flush()
    print(json.dumps({"site": SITE, "date": time.strftime("%Y-%m-%d"), "macos": run("sw_vers", "-productVersion").stdout.strip(),
                      "versions": {n: BROWSERS[n].version() for n in names},
                      "median_s": {n: round(statistics.median(v), 3) for n, v in results.items() if v}, "runs": results}, ensure_ascii=False))
