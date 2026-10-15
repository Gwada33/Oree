#!/usr/bin/env python3
"""The windows a page can ask for: alert, confirm, prompt and the file chooser (<input type=file>), plus window.close().
Starts its own Orée instance on a throw-away database; the upload is answered by HB_TEST_UPLOAD_PATH (no clicking in a system panel).

  python3 scripts/bench/dialogs_check.py
"""
import functools, http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dialogs_fixture")
PORT = 8795

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else ""

def js(expr):
    out = ui("eval", f"JSON.stringify({expr})")
    try: return json.loads(out)
    except Exception: return None

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def main():
    server, before = serve(), pids()
    tmp = tempfile.mkdtemp(prefix="dialogs-"); os.makedirs(tmp + "/ext")
    upload = os.path.join(FIXTURE, "televerse.txt")
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_AI_NO_AGENT=1", "--env", f"HB_TEST_UPLOAD_PATH={upload}",
                    "--env", f"HB_DB_PATH={tmp}/db.sqlite", "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"]); time.sleep(7)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def ask(script):                      # the script blocks on a dialog, so it runs later; the dialog is read, answered, then the result is read
        ui("eval", f"window.__r='pending'; setTimeout(() => {{ window.__r = {script} }}, 50); 'scheduled'"); time.sleep(1.2)
    try:
        ui("load", f"http://127.0.0.1:{PORT}/page.html"); time.sleep(3)

        print("\nalert()")
        ask("(alert('Bonjour le monde'), 'closed')")
        dialog = ui("tab", "dialog", "0")
        check("la fenêtre apparaît avec le message", "Bonjour le monde" in dialog)
        check("elle nomme le site", "127.0.0.1" in dialog)
        check("elle n'a qu'un bouton", 'buttons=["OK"]' in dialog)
        ui("tab", "dialogok", "0"); time.sleep(1)
        check("la page reprend la main après OK", js("window.__r") == "closed")

        print("\nconfirm()")
        ask("confirm('Supprimer ?')")
        check("la fenêtre propose OK et Annuler", 'buttons=["OK", "Annuler"]' in ui("tab", "dialog", "0"))
        ui("tab", "dialogok", "0"); time.sleep(1)
        check("OK donne true", js("window.__r") is True)
        ask("confirm('Supprimer ?')")
        ui("tab", "dialogcancel", "0"); time.sleep(1)
        check("Annuler donne false", js("window.__r") is False)

        print("\nprompt()")
        open("/tmp/oree-address.txt", "w").write("Nolhan")
        ask("prompt('Ton prénom ?', 'ami')")
        check("la fenêtre a un champ de saisie", "field=true" in ui("tab", "dialog", "0"))
        ui("tab", "dialogok", "0"); time.sleep(1)
        check("OK donne le texte saisi", js("window.__r") == "Nolhan")
        ask("prompt('Ton prénom ?', 'ami')")
        ui("tab", "dialogcancel", "0"); time.sleep(1)
        check("Annuler donne null", js("window.__r") is None)

        print("\nChoisir un fichier")
        ui("eval", "document.getElementById('f').click(); 'clicked'"); time.sleep(2)
        check("le fichier choisi arrive à la page (nom et taille)", js("window.__file") == "televerse.txt:27")
        check("le champ contient bien un fichier", js("document.getElementById('f').files.length") == 1)
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
        try: os.remove("/tmp/oree-address.txt")
        except FileNotFoundError: pass
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
