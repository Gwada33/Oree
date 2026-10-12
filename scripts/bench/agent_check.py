#!/usr/bin/env python3
"""End-to-end check of the agent loop (step 4 of Docs/ia.md) in a separate Orée instance (debug build only): the model's replies are
scripted (/tmp/oree-ai-script.json), everything else is real: the page, the executor, the trace, the confirmation card, the
question card, Stop. The service only has to be reachable (own Mach name, removed at the end). Exit 1 on any failure.

  python3 scripts/bench/agent_check.py
"""
import functools, http.server, json, os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hands_fixture")
MODEL = os.path.expanduser("~/Library/Application Support/HyperBrowser/Models/Qwen3.5-4B-Q4_K_M.gguf")
MACH = "com.nolhan.hyperbrowser.ai-agent-test"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{MACH}.plist")
PORT = 8791
TRACE = "/tmp/oree-agent-trace.txt"

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def state(): return ui("tab", "aistate", "0")

def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate(): return True
        time.sleep(0.4)
    return False

def script(*replies): json.dump(list(replies), open("/tmp/oree-ai-script.json", "w"))

def ask(text):
    open("/tmp/oree-ai-query.txt", "w").write(text); ui("tab", "aiquery", "0")

def js(expr): return ui("eval", expr)

def shot(name):
    """AI_SHOTS=<dossier> : une capture de la fenêtre de test (pour relire le design)."""
    out = os.environ.get("AI_SHOTS")
    if out: os.makedirs(out, exist_ok=True); time.sleep(1.2); ui("snapshot", os.path.join(out, name + ".png"))

def resolve(text):
    open("/tmp/oree-ai-query.txt", "w").write(text); ui("tab", "airesolve", "0")

def main():
    if not os.path.exists(MODEL):
        print("ignoré : le modèle n'est pas sur le disque (le service doit répondre « prêt »)"); return 0
    server, before = serve(), pids()
    tmp = tempfile.mkdtemp(prefix="agentcheck-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    if os.path.exists(TRACE): os.remove(TRACE)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_NO_AGENT=1", f"HB_AI_MACH_NAME={MACH}", f"HB_AI_TRACE={TRACE}"]
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        ui("load", f"http://127.0.0.1:{PORT}/controlled.html"); time.sleep(3)
        ui("tab", "aibar", "0")
        check("le service est prêt", wait_for(lambda: "state=ready" in state(), 40))
        shot("agent-empty")

        print("\nTâche avec une action sensible")
        script('{"tool":"type","ref":"@e1","text":"Zébulon"}', '{"tool":"click","ref":"@e5"}', '{"tool":"done","answer":"Formulaire envoyé."}')
        ask("Inscris-moi")
        check("une carte « à valider » apparaît avant l'envoi", wait_for(lambda: "pending=confirm" in state(), 25))
        s = state(); print("  ", s[:300]); shot("agent-confirm")
        check("la carte dit ce qui va être envoyé", "Créer mon compte" in s)
        check("Luciole est allée jusqu'au bouton et y reste pendant la validation", "cursor=[at=" in s and "pose=wait" in s)
        check("rien n'est envoyé tant qu'on n'a pas validé", js("window.__submits") == "0")
        check("la saisie déjà faite est visible dans la trace", "done:Saisie dans" in s)
        resolve("yes")
        check("validée, la tâche se termine avec la réponse", wait_for(lambda: "running=false" in state() and "Formulaire envoyé." in state(), 25))
        check("le formulaire a bien été envoyé une fois", js("window.__submits") == "1")
        check("la trace garde les deux actions", state().count("done:") == 2)

        print("\nRefus à la carte")
        script('{"tool":"click","ref":"@e5"}', '{"tool":"done","answer":"Annulé."}')
        ask("Renvoie")
        check("la carte apparaît de nouveau", wait_for(lambda: "pending=confirm" in state(), 25))
        resolve("no")
        check("refusée : la tâche continue, rien n'est envoyé", wait_for(lambda: "running=false" in state(), 25) and js("window.__submits") == "1")
        check("l'échec est dit dans la trace", "failed:Clic sur @e5 — La personne a refusé" in state())

        print("\nStop pendant une confirmation")
        script('{"tool":"click","ref":"@e5"}', '{"tool":"done","answer":"jamais"}')
        ask("Encore")
        check("la carte apparaît", wait_for(lambda: "pending=confirm" in state(), 25))
        ui("tab", "aistop", "0")
        s = state()
        check("Stop libère tout de suite et ferme la carte", "running=false" in s and "pending=none" in s)
        time.sleep(1.5)
        check("rien n'est envoyé après Stop", js("window.__submits") == "1" and "jamais" not in state())

        print("\nQuestion de l'IA")
        script('{"tool":"ask_user","question":"Quel est votre prénom ?"}', '{"tool":"done","answer":"Merci Nolhan."}')
        ask("Salue-moi")
        check("la carte de question apparaît", wait_for(lambda: "pending=question" in state(), 25))
        shot("agent-question")
        resolve("Nolhan")
        check("la réponse de la personne revient au modèle", wait_for(lambda: "Merci Nolhan." in state(), 25))
        check("elle est dans le tour suivant du modèle", "Réponse de la personne : Nolhan" in open(TRACE).read())

        print("\nSécurité")
        script('{"tool":"open_url","url":"file:///etc/passwd"}', '{"tool":"done","answer":"fini"}')
        ask("Ouvre ça")
        check("une adresse file:// est refusée", wait_for(lambda: "running=false" in state(), 25) and "failed:Ouverture de file:///etc/passwd — Adresse refusée" in state())
        script('{"tool":"type","ref":"@e1","text":"{{profil.inconnu}}"}', '{"tool":"done","answer":"fini"}')
        ask("Écris mon profil")
        check("un jeton de profil inconnu échoue sans rien écrire", wait_for(lambda: "running=false" in state(), 25) and "{{" not in js("document.getElementById('name').value"))

        print("\nDiscussion et liens")
        script('{"tool":"done","answer":"Voici la réponse à garder."}')
        ask("Dis quelque chose")
        wait_for(lambda: "Voici la réponse à garder." in state(), 25)
        open("/tmp/oree-ai-query.txt", "w").write(f"http://127.0.0.1:{PORT}/trap.html"); ui("tab", "aiopensource", "0"); time.sleep(2)
        after = state()
        check("ouvrir une source garde la discussion dans le nouvel onglet", "Voici la réponse à garder." in after)
        check("et n'affiche aucune erreur", "line=|" in after)

        print("\nMémoire")
        memfile = os.path.join(tmp, "Luciole", "memoire.json")
        check("la discussion et le journal sont enregistrés sur disque", wait_for(lambda: os.path.exists(memfile) and "Inscris-moi" in open(memfile).read(), 10))
        data = open(memfile).read() if os.path.exists(memfile) else ""
        check("ce que Luciole a fait est gardé (libellés)", "Saisie dans" in data)
        check("la valeur saisie n'est jamais gardée", "Zébulon" not in data)
        check("ce que la personne a appris à Luciole est gardé", "Quel est votre prénom ?" in data)
        script('{"tool":"done","answer":"ok"}')
        ask("Tu te souviens ?")
        wait_for(lambda: "running=false" in state(), 25)
        check("la mémoire est donnée au modèle au tour suivant", "CE DONT TU TE SOUVIENS" in open(TRACE).read().split("=== PROMPT")[-1])

        print("\nPlafond d'étapes")
        script(*['{"tool":"scroll","direction":"down"}', '{"tool":"scroll","direction":"up"}'] * 8)
        ask("Défile sans fin")
        check("après 15 étapes, l'IA s'arrête et le dit", wait_for(lambda: "running=false" in state() and "limite de 15 étapes" in state(), 120))
        shot("agent-cap")
        os.remove("/tmp/oree-ai-script.json") if os.path.exists("/tmp/oree-ai-script.json") else None
    finally:
        for p in mine: subprocess.run(["kill", p])
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{MACH}"], capture_output=True)
        if os.path.exists(PLIST): os.remove(PLIST)
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
