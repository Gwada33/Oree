#!/usr/bin/env python3
"""Everyday web flows on local pages: links that open tabs, window.open and the popup blocker, a sign-in style popup that talks to its opener and closes itself,
downloads (server attachment and blob), form posts, cookies, local storage, redirects, back/forward. Starts its own Orée instance on a throw-away database,
and downloads into a throw-away folder (HB_DOWNLOAD_DIR). Fullscreen is tried and reported, but not required: a hidden test window may refuse it.

  python3 scripts/bench/daily_check.py
"""
import http.server, json, os, subprocess, sys, tempfile, threading, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
PORT = 8797

PAGES = {
 "/index.html": """<!doctype html><meta charset=utf-8><title>Accueil</title>
<a id=blank href="/cible.html" target="_blank">ouvrir</a>
<a id=file href="/rapport.txt">télécharger</a>
<button id=blobbtn onclick="var b=new Blob(['contenu du blob'],{type:'text/plain'});var a=document.createElement('a');a.href=window.URL.createObjectURL(b);a.download='blob.txt';document.body.appendChild(a);a.click()">blob</button>
<form id=f method=post action="/echo"><input name=nom value=Nolhan><button>envoyer</button></form>
<script>window.addEventListener('message', e => { window.__msg = e.data })</script>""",
 "/cible.html": "<!doctype html><title>Cible</title><p>Page cible</p>",
 "/popup.html": "<!doctype html><title>Popup</title><script>window.opener.postMessage('connecté','*'); window.close()</script>",
 "/storage.html": "<!doctype html><title>Stockage</title><script>localStorage.setItem('k', (localStorage.getItem('k')||'')+'x'); document.title='k='+localStorage.getItem('k')</script>",
 "/cookie.html": "<!doctype html><title>Cookie</title><p id=c></p><script>document.getElementById('c').textContent=document.cookie</script>",
 "/fin.html": "<!doctype html><title>Fin</title><p>arrivée</p>",
}

class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body, ctype="text/html; charset=utf-8", extra=()):
        data = body.encode(); self.send_response(code)
        for k, v in extra: self.send_header(k, v)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/rapport.txt": return self.send(200, "rapport annuel", "text/plain", [("Content-Disposition", 'attachment; filename="rapport.txt"')])
        if path == "/setcookie": return self.send(200, "<title>ok</title>", extra=[("Set-Cookie", "session=abc123; Path=/")])
        if path == "/redirige": return self.send(302, "", extra=[("Location", "/fin.html")])
        if path in PAGES: return self.send(200, PAGES[path])
        self.send(404, "<title>Introuvable</title><p>Rien ici</p>")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        self.send(200, f"<title>Reçu</title><p id=r>reçu : {urllib.parse.unquote_plus(body)}</p>")
    def log_message(self, *a): pass

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); out = (r.stdout + r.stderr).strip()
    return out.splitlines()[-1] if out else ""

def js(expr):
    try: return json.loads(ui("eval", f"JSON.stringify({expr})"))
    except Exception: return None

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())
def tabs(): 
    line = ui("tab", "windows", "0"); import re
    m = re.search(r"primary tabs=(\d+) active=(\S*)", line); return (int(m.group(1)), m.group(2)) if m else (0, "")
def url(p): return f"http://127.0.0.1:{PORT}{p}"

def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H); threading.Thread(target=server.serve_forever, daemon=True).start()
    before = pids(); tmp = tempfile.mkdtemp(prefix="daily-"); os.makedirs(tmp + "/ext"); os.makedirs(tmp + "/dl")
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_AI_NO_AGENT=1", "--env", "HB_NO_AGENT=1", "--env", f"HB_DOWNLOAD_DIR={tmp}/dl", "--env", f"HB_DOWNLOAD_STATE_DIR={tmp}/state",
                    "--env", f"HB_DB_PATH={tmp}/db.sqlite", "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"]); time.sleep(7)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        ui("load", url("/index.html")); time.sleep(2.5)

        print("\nOnglets et fenêtres de page")
        n0, _ = tabs()
        ui("eval", "document.getElementById('blank').click(); 'c'"); time.sleep(2.5)
        n1, active = tabs()
        check("un lien target=_blank ouvre un onglet", n1 == n0 + 1)
        check("cet onglet charge la bonne page", active.endswith("/cible.html"))
        ui("tab", "select", "0"); time.sleep(1)

        ui("eval", "window.open('/cible.html'); 'o'"); time.sleep(2.5)
        n2, _ = tabs()
        check("window.open lancé par un clic ouvre un onglet", n2 == n1 + 1)
        ui("tab", "select", "0"); time.sleep(1)

        ui("eval", "setTimeout(() => window.open('/cible.html'), 2600); 's'"); time.sleep(4.5)       # after the short window in which a click still counts
        n3, _ = tabs()
        check("window.open sans geste (publicité) est bloqué", n3 == n2)

        ui("eval", "window.__msg = null; window.open('/popup.html'); 'p'"); time.sleep(3)
        n4, _ = tabs()
        check("la fenêtre de connexion se referme d'elle-même (window.close)", n4 == n3)
        ui("tab", "select", "0"); time.sleep(1)
        check("elle a pu parler à la page qui l'a ouverte (window.opener)", js("window.__msg") == "connecté")

        print("\nTéléchargements")
        def blob_download(name):
            ui("load", url("/index.html")); time.sleep(2)
            ui("eval", "document.getElementById('blobbtn').click(); 'b'"); time.sleep(4)
            path = os.path.join(tmp, "dl", name)
            return os.path.exists(path) and open(path).read() == "contenu du blob"
        check("un fichier créé par la page (blob) est téléchargé", blob_download("blob.txt"))
        ui("load", url("/index.html")); time.sleep(2)
        ui("eval", "document.getElementById('file').click(); 'd'"); time.sleep(4)
        path = os.path.join(tmp, "dl", "rapport.txt")
        check("un fichier envoyé par le serveur est téléchargé", os.path.exists(path) and open(path).read() == "rapport annuel")
        check("un deuxième fichier créé par la page est téléchargé (« blob (1).txt » : le nom est déjà pris)",
              blob_download("blob (1).txt") or blob_download("blob-1.txt") or any(n.startswith("blob") and n != "blob.txt" for n in os.listdir(os.path.join(tmp, "dl"))))
        ui("load", url("/index.html")); time.sleep(2)

        print("\nFormulaires, cookies et stockage")
        ui("eval", "document.getElementById('f').submit(); 's'"); time.sleep(2.5)
        check("un formulaire envoyé en POST arrive au serveur", "nom=Nolhan" in (js("document.body.innerText") or ""))
        ui("load", url("/setcookie")); time.sleep(2)
        ui("load", url("/cookie.html")); time.sleep(2.5)
        check("un cookie du serveur est renvoyé à la page suivante", "session=abc123" in (js("document.body.innerText") or ""))
        ui("load", url("/storage.html")); time.sleep(2)
        ui("load", url("/storage.html")); time.sleep(2)
        title = js("document.title") or ""
        check(f"le stockage local survit au rechargement ({title})", title.startswith("k=xx"))

        print("\nNavigation")
        ui("load", url("/redirige")); time.sleep(2.5)
        check("une redirection mène à la page finale", tabs()[1].endswith("/fin.html"))
        ui("load", url("/introuvable")); time.sleep(2.5)
        check("une page 404 du serveur s'affiche", "Rien ici" in (js("document.body.innerText") or "") or "Introuvable" in (js("document.title") or ""))
        ui("load", url("/index.html")); time.sleep(2)
        ui("load", url("/fin.html")); time.sleep(2)
        ui("action", "goBack"); time.sleep(2)
        check("« Précédent » revient à la page d'avant", tabs()[1].endswith("/index.html"))
        ui("action", "goForward"); time.sleep(2)
        check("« Suivant » revient à la suivante", tabs()[1].endswith("/fin.html"))

        print("\nPlein écran (essayé, non exigé)")
        ui("load", url("/index.html")); time.sleep(2)
        ui("eval", "window.__fs = 'pending'; document.documentElement.requestFullscreen().then(() => { window.__fs = 'ok' }).catch(e => { window.__fs = e.name }); 'f'"); time.sleep(2)
        print("  info   requestFullscreen →", js("window.__fs"))
        ui("eval", "if (document.fullscreenElement) document.exitFullscreen(); 'x'")
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
