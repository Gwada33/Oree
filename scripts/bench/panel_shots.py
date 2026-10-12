#!/usr/bin/env python3
"""Images du panneau Luciole seul, état par état, clair et sombre, pour les comparer à la fiche de design (build de debug, instance séparée).

  python3 scripts/bench/panel_shots.py <dossier de sortie> [clair|sombre]
"""
import functools, http.server, json, os, shutil, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hands_fixture")
PORT = 8794

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()
def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())
def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.4)
    return False

def session(out, name, env_extra, dark, steps):
    before = pids(); tmp = tempfile.mkdtemp(prefix="shots-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_AI_NO_AGENT=1", "HB_AI_PROVIDER=groq"] + env_extra
    args = ["--automation"] + (["-AppleInterfaceStyle", "Dark"] if dark else [])
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", *args]); time.sleep(5)
    mine = pids() - before
    try:
        ui("load", f"http://127.0.0.1:{PORT}/controlled.html"); time.sleep(3)
        ui("tab", "aibar", "0"); time.sleep(1.5)
        steps()
        time.sleep(1.2)
        if os.path.exists("/tmp/oree-panel.png"): os.remove("/tmp/oree-panel.png")
        ui("tab", "aipanelshot", "0")
        if os.path.exists("/tmp/oree-panel.png"): shutil.move("/tmp/oree-panel.png", os.path.join(out, name + ".png"))
        else: print("pas d'image pour", name)
    finally:
        for p in mine: subprocess.run(["kill", p])
        time.sleep(1)

def ask(text):
    open("/tmp/oree-ai-query.txt", "w").write(text); ui("tab", "aiquery", "0")
def script(*r): json.dump(list(r), open("/tmp/oree-ai-script.json", "w"))
def state(): return ui("tab", "aistate", "0")

def main():
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    dark = len(sys.argv) > 2 and sys.argv[2] == "sombre"
    suffix = "-sombre" if dark else ""
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        session(out, "vide" + suffix, [], dark, lambda: None)
        for fake in ["needsModel", "downloading", "verifying", "corrupt", "connecting", "unreachable"]:
            session(out, fake + suffix, [f"HB_AI_FAKE_STATE={fake}"], dark, lambda: None)
        def conversation():
            script('{"tool":"done","answer":"Ce formulaire demande un nom, une ville, un pays et propose une lettre d\'information."}')
            ask("Résume cette page"); wait_for(lambda: "running=false" in state() and "formulaire" in state(), 30)
        session(out, "reponse" + suffix, [], dark, conversation)
        def confirm():
            script('{"tool":"type","ref":"@e1","text":"Nolhan"}', '{"tool":"click","ref":"@e5"}', '{"tool":"done","answer":"ok"}')
            ask("Inscris-moi avec le nom Nolhan"); wait_for(lambda: "pending=confirm" in state(), 30)
        session(out, "confirmation" + suffix, [], dark, confirm)
        def question():
            script('{"tool":"ask_user","question":"Quel est votre prénom ?"}', '{"tool":"done","answer":"Merci."}')
            ask("Salue-moi"); wait_for(lambda: "pending=question" in state(), 30)
        session(out, "question" + suffix, [], dark, question)
        def cap():
            script(*['{"tool":"scroll","direction":"down"}', '{"tool":"scroll","direction":"up"}'] * 8)
            ask("Défile sans fin"); wait_for(lambda: "running=false" in state(), 90)
        session(out, "plafond" + suffix, [], dark, cap)
    finally:
        server.shutdown()
        if os.path.exists("/tmp/oree-ai-script.json"): os.remove("/tmp/oree-ai-script.json")

if __name__ == "__main__":
    main()
