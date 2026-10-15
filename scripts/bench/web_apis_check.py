#!/usr/bin/env python3
"""App-side answers a web view needs: a site's username/password request (HTTP basic authentication) and links that belong to other
apps (blocked schemes, no handler). Starts its own Orée instance on a throw-away database. Mail, phone and call apps are NOT opened here:
only the cases that open nothing are driven.

  python3 scripts/bench/web_apis_check.py
"""
import base64, http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
PORT = 8796

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); out = (r.stdout + r.stderr).strip()
    return out.splitlines()[-1] if out else ""

def js(expr):
    try: return json.loads(ui("eval", f"JSON.stringify({expr})"))
    except Exception: return None

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

class Auth(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        expected = "Basic " + base64.b64encode(b"admin:secret").decode()
        if self.headers.get("Authorization") == expected:
            body, code = "<title>Admin</title><p id=m>Bienvenue admin</p>".encode(), 200
        else:
            body, code = "<title>Refusé</title><p id=m>Accès refusé</p>".encode(), 401
        self.send_response(code)
        if code == 401: self.send_header("WWW-Authenticate", 'Basic realm="Zone test"')
        self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Auth)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    before = pids(); tmp = tempfile.mkdtemp(prefix="webapis-"); os.makedirs(tmp + "/ext")
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_AI_NO_AGENT=1", "--env", f"HB_DB_PATH={tmp}/db.sqlite",
                    "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"]); time.sleep(7)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nMot de passe demandé par un site (HTTP basic)")
        ui("load", f"http://127.0.0.1:{PORT}/"); time.sleep(2.5)
        dialog = ui("tab", "dialog", "0")
        check("la fenêtre de connexion apparaît et nomme le site", "127.0.0.1" in dialog and "demande une connexion" in dialog)
        check("elle indique la zone protégée", "Zone test" in dialog)
        check("elle prévient que la connexion n'est pas chiffrée", "pas chiffrée" in dialog)
        check("elle a deux champs", "fields=2" in dialog)
        open("/tmp/oree-address.txt", "w").write("admin\nmauvais")
        ui("tab", "dialogok", "0"); time.sleep(2.5)
        dialog = ui("tab", "dialog", "0")
        check("un mauvais mot de passe : la fenêtre revient en le disant", "refusé" in dialog)
        open("/tmp/oree-address.txt", "w").write("admin\nsecret")
        ui("tab", "dialogok", "0"); time.sleep(2.5)
        check("le bon mot de passe ouvre la page", "Bienvenue admin" in (js("document.body.innerText") or ""))
        check("plus aucune fenêtre ouverte", ui("tab", "dialog", "0") == "(none)")
        ui("load", f"http://127.0.0.1:{PORT}/autre"); time.sleep(2.5)
        check("la même session n'est pas redemandée", "Bienvenue admin" in (js("document.body.innerText") or ""))

        print("\nAnnuler")
        ui("tab", "newwindow", "0"); time.sleep(0.5)
    finally:
        pass
    # a second instance for the cancel case, so that the session credential above does not hide it
    for p in mine: subprocess.run(["kill", p])
    time.sleep(2)
    before = pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_AI_NO_AGENT=1", "--env", f"HB_DB_PATH={tmp}/db2.sqlite",
                    "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"]); time.sleep(7)
    mine = pids() - before
    try:
        ui("load", f"http://127.0.0.1:{PORT}/"); time.sleep(2.5)
        ui("tab", "dialogcancel", "0"); time.sleep(2.5)
        check("Annuler laisse la page de refus du serveur", "Accès refusé" in (js("document.body.innerText") or ""))
        check("plus aucune fenêtre ouverte", ui("tab", "dialog", "0") == "(none)")

        print("\nLiens pour d'autres applications")
        for scheme, label in [("ssh://exemple.local", "ssh"), ("file:///etc/hosts", "file"), ("vnc://exemple.local", "vnc")]:
            ui("eval", f"var a=document.createElement('a'); a.href='{scheme}'; a.id='x'; document.body.appendChild(a); a.click(); 'clicked'"); time.sleep(1.5)
            check(f"un lien {label}:// est refusé et la page reste", "Accès refusé" in (js("document.body.innerText") or "") and "n’ouvre pas" in ui("tab", "notice", "0"))
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
        try: os.remove("/tmp/oree-address.txt")
        except FileNotFoundError: pass
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
