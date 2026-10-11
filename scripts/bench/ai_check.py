#!/usr/bin/env python3
"""End-to-end check of the AI bar with the REAL local service and model (no mocks), in a separate Orée instance:
the bar opens, the service starts on demand and wakes the model, a question gets its answer, Stop works and the service still
answers afterwards. Own Mach name (so the user's real agent is never touched); that test agent is removed at the end.
Skipped if the model file is not on disk (this script never downloads 1.3 GB). Exit 1 on any failure.

  python3 scripts/bench/ai_check.py
"""
import os, plistlib, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
MODEL = os.path.expanduser("~/Library/Application Support/HyperBrowser/Models/Qwen3.5-2B-Q4_K_M.gguf")
MACH = "com.nolhan.hyperbrowser.ai-test"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{MACH}.plist")

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(0.5)
    return False

def state(): return ui("tab", "aistate", "0")

def answer():
    s = state()
    return s.split("answer=", 1)[1] if "answer=" in s else ""

def ask(text):
    open("/tmp/oree-ai-query.txt", "w").write(text)
    return ui("tab", "aiquery", "0")

def main():
    if not os.path.exists(MODEL):
        print("ignoré : le modèle n'est pas sur le disque (ce script ne télécharge pas 1,3 Go)"); return 0
    tmp = tempfile.mkdtemp(prefix="aicheck-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    before = pids()
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_NO_AGENT=1", f"HB_AI_MACH_NAME={MACH}"]
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        check("avant l'ouverture, rien n'est lancé : pas d'agent IA installé", not os.path.exists(PLIST))
        print("\nOuverture de la barre")
        ui("tab", "aibar", "0")
        check("la barre s'ouvre, l'agent est installé à la demande", wait_for(lambda: os.path.exists(PLIST), 15) and "open=true" in state())
        ready = wait_for(lambda: "state=ready" in state(), 40)
        print("  ", state()[:200])
        check("le service répond et le modèle est prêt (vérifié par SHA-256)", ready)
        if not ready: return 1

        print("\nUne question")
        ask("Quelle est la capitale de la France ? Réponds en un seul mot.")
        # Une réponse d'un mot arrive en moins d'un demi-seconde : on ne peut pas toujours voir « running=true » entre deux relevés.
        check("la tâche démarre", wait_for(lambda: "running=true" in state() or len(answer().strip()) > 0, 5))
        check("la réponse se termine", wait_for(lambda: "running=false" in state(), 60))
        text = answer(); print("  réponse :", repr(text[:120]))
        check("elle n'est pas vide et nomme Paris", "paris" in text.lower())

        print("\nStop")
        ask("Écris un très long poème de quarante vers sur la mer, avec des détails.")
        check("une réponse longue commence à s'écrire", wait_for(lambda: "running=true" in state() and len(answer().strip()) > 20, 30))
        ui("tab", "aistop", "0")
        check("Stop arrête la tâche tout de suite", "running=false" in state())
        time.sleep(1.5)
        stopped = answer()
        time.sleep(2)
        check("rien ne s'écrit plus après Stop", answer() == stopped)
        ask("Quelle est la capitale de l'Italie ? Réponds en un seul mot.")
        ok = wait_for(lambda: "running=false" in state() and len(answer().strip()) > 0, 60)
        print("  réponse après Stop :", repr(answer()[:80]), "|", state()[:160])
        check("le service répond encore après un Stop", ok)

        print("\nFermeture")
        ui("tab", "aibar", "0")
        check("la barre se ferme", "open=false" in state())
    finally:
        for p in mine: subprocess.run(["kill", p])
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{MACH}"], capture_output=True)
        if os.path.exists(PLIST): os.remove(PLIST)
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
