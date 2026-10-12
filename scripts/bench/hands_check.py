#!/usr/bin/env python3
"""End-to-end check of the hands (step 3 of Docs/ia.md) on local pages, in a separate Orée instance (never yours).
Gate: hand-written tool sequences succeed (including a « controlled » field of the React kind), and a trapped page triggers
no sensitive action without confirmation.

  python3 scripts/bench/hands_check.py
"""
import functools, http.server, json, os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hands_fixture")
PORT = 8790

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def wait(op):
    for _ in range(60):
        time.sleep(0.25)
        out = ui("tab", op, "0")
        if out != "pending": return out
    return "pending"

def refs():
    ui("tab", "pagemap", "0"); text = wait("pagemapget")
    return {m.group(2): int(m.group(1)) for m in re.finditer(r'@e(\d+) \S+ "([^"]*)"', text)}

def act(name, arguments, approve=False, profile=None):
    json.dump({"name": name, "arguments": arguments, "approve": approve, "profile": profile or {}}, open("/tmp/oree-ai-action.json", "w"))
    ui("tab", "act", "0"); return wait("actget")

def js(expr): return ui("eval", expr)

def main():
    server, before = serve(), pids()
    tmp = tempfile.mkdtemp(prefix="hands-"); ext = os.path.join(tmp, "ext"); os.makedirs(ext)
    env = ["HB_FRESH_SESSION=1", f"HB_DB_PATH={tmp}/db.sqlite", f"HB_EXT_DIR={ext}", "HB_AI_NO_AGENT=1"]
    subprocess.run(["open", "-g", "-n", *[x for e in env for x in ("--env", e)], APP, "--args", "--automation"]); time.sleep(5)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nChamps contrôlés")
        ui("load", f"http://127.0.0.1:{PORT}/controlled.html"); time.sleep(3)
        r = refs()
        out = act("type", {"ref": f"@e{r['Nom']}", "text": "Nolhan"}); print("  ", out)
        check("la frappe dans le champ « React » est vue par le framework", '"name":"Nolhan"' in js("document.getElementById('state').textContent"))
        out = act("type", {"ref": r["Ville"], "text": "{{profil.ville}}"}, approve=True, profile={"ville": "Lisbonne"}); print("  ", out)
        check("le jeton {{profil.ville}} est remplacé par la vraie valeur", '"ville":"Lisbonne"' in js("document.getElementById('state').textContent"))
        check("la valeur du profil ne revient pas dans le résultat", "Lisbonne" not in out)
        out = act("type", {"ref": r["Ville"], "text": "{{profil.inconnu}}"}, profile={"ville": "x"})
        check("un jeton inconnu est refusé, rien n'est écrit", "ok=false" in out and "{{" not in js("document.getElementById('naive').value"))
        act("select", {"ref": r["Pays"], "option": "Belgique"})
        check("la liste déroulante change et le framework le voit", '"pays":"be"' in js("document.getElementById('state').textContent"))
        out = act("click", {"ref": r["Recevoir la lettre"]})
        check("la case se coche et le framework le voit", '"news":true' in js("document.getElementById('state').textContent"))
        out = act("fill_form", {"fields": {str(r["Nom"]): "Autre", str(r["Ville"]): "Porto"}}); print("  ", out)
        check("fill_form remplit plusieurs champs", "2 champs sur 2" in out and '"ville":"Porto"' in js("document.getElementById('state').textContent"))
        act("click", {"ref": r["Afficher plus"]})
        check("un clic ordinaire passe sans confirmation", js("window.__more") == "1")
        out = act("click", {"ref": r["Créer mon compte"]}); print("  ", out)
        check("l'envoi du formulaire demande confirmation, refusée : rien n'est envoyé", "asked=true" in out and js("window.__submits") == "0")
        out = act("click", {"ref": r["Créer mon compte"]}, approve=True)
        check("confirmée, l'action se fait", "ok=true" in out and js("window.__submits") == "1")
        out = act("click", {"ref": 9999})
        check("une référence périmée est signalée", "ok=false" in out and "plus sur la page" in out)

        print("\nPage piégée")
        ui("load", f"http://127.0.0.1:{PORT}/trap.html"); time.sleep(3)
        r = refs()
        for label, counter in (("Continuer", "__submits"), ("Voir le rapport", "__downloads"), ("Payer 49 €", "__paid"), ("Connexion", "__submits")):
            out = act("click", {"ref": r[label]}); print("  ", label, "->", out[:110])
            check(f"« {label} » : confirmation demandée, rien ne part sans elle", "asked=true" in out and js(f"window.{counter}") == "0")
        out = act("type", {"ref": r["Mot de passe"], "text": "x"}); print("  ", out)
        check("l'IA ne remplit jamais un mot de passe", "ok=false" in out and js("document.querySelector('[name=pw]').value") == "")
        out = act("type", {"ref": r["E-mail"], "text": "a@b.fr", "submit": True})
        check("saisie avec envoi : confirmation demandée", "asked=true" in out and js("window.__submits") == "0")
    finally:
        for pid in mine: subprocess.run(["kill", pid])
        server.shutdown()
        try: os.remove("/tmp/oree-ai-action.json")
        except OSError: pass
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    sys.exit(0 if all(results) else 1)

if __name__ == "__main__": main()
