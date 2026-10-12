#!/usr/bin/env python3
"""Vérification de bout en bout avec un fournisseur en nuage (argument : groq, par défaut, ou mistral) (vrai réseau, vraie clé du Trousseau) dans une instance séparée : une question simple, une recherche web,
puis une tâche sur une page locale (saisie + envoi avec carte « à valider »). Ignoré si aucune clé n'est dans le Trousseau.

  python3 scripts/bench/groq_check.py
"""
import functools, http.server, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hands_fixture")
PORT = 8792
PROVIDER = sys.argv[1] if len(sys.argv) > 1 else "groq"

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()
def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())
def state(): return ui("tab", "aistate", "0")
def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.5)
    return False
def ask(text):
    open("/tmp/oree-ai-query.txt", "w").write(text); ui("tab", "aiquery", "0")

def main():
    if subprocess.run(["security", "find-generic-password", "-s", f"com.nolhan.hyperbrowser.{PROVIDER}", "-a", "api-key"], capture_output=True).returncode != 0:
        print(f"ignoré : pas de clé {PROVIDER} dans le Trousseau"); return 0
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    before = pids(); tmp = tempfile.mkdtemp(prefix="groqcheck-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_AI_NO_AGENT=1", f"HB_AI_PROVIDER={PROVIDER}", "HB_AI_TRACE=/tmp/oree-groq-trace.txt"]
    if os.path.exists("/tmp/oree-groq-trace.txt"): os.remove("/tmp/oree-groq-trace.txt")
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        ui("load", f"http://127.0.0.1:{PORT}/controlled.html"); time.sleep(3)
        ui("tab", "aibar", "0")
        check("le panneau est prêt avec Groq", wait_for(lambda: "state=ready" in state(), 10))
        ask("Quelle est la capitale du Portugal ? Réponds en un mot.")
        check("une question simple reçoit une réponse", wait_for(lambda: "running=false" in state() and "Lisbonne" in state(), 60))
        print("  ", state()[-120:])
        ask("Cherche sur le web la population de Lisbonne et donne-moi le chiffre.")
        check("la recherche web est lancée (trace)", wait_for(lambda: "Recherche" in state(), 60))
        check("la tâche se termine", wait_for(lambda: "running=false" in state(), 90))
        print("  ", state()[-260:])
        ui("load", f"http://127.0.0.1:{PORT}/controlled.html"); time.sleep(3)      # la recherche a pu ouvrir une autre page dans l'onglet
        ask("Écris Nolhan dans le champ Nom de cette page puis envoie le formulaire.")
        check("une carte « à valider » apparaît avant l'envoi", wait_for(lambda: "pending=confirm" in state(), 90))
        check("rien n'est parti", ui("eval", "window.__submits") == "0")
        open("/tmp/oree-ai-query.txt", "w").write("no"); ui("tab", "airesolve", "0")
        check("refusée, la tâche se termine", wait_for(lambda: "running=false" in state(), 90))
        check("le champ a été rempli", "Nolhan" in ui("eval", "document.getElementById('name').value"))
        check("toujours rien d'envoyé", ui("eval", "window.__submits") != "1")      # un modèle capricieux peut quitter la page : l'essentiel est que rien ne soit parti
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
