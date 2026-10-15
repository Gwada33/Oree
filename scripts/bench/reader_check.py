#!/usr/bin/env python3
"""Reader mode (⇧⌘R) on local pages: an article is extracted without its menus, ads, comments and scripts, a shop page is refused, and the
command brings the original page back. Starts its own Orée instance on a throw-away database.

  python3 scripts/bench/reader_check.py
"""
import functools, http.server, json, os, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reader_fixture")
PORT = 8794

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def js(expr):
    out = ui("eval", f"JSON.stringify({expr})")
    try: return json.loads(out.splitlines()[-1])
    except Exception: return None

def pids(): return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    s = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Quiet, directory=FIXTURE))
    threading.Thread(target=s.serve_forever, daemon=True).start(); return s

def main():
    server, before = serve(), pids()
    tmp = tempfile.mkdtemp(prefix="reader-"); os.makedirs(tmp + "/ext")
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_AI_NO_AGENT=1", "--env", f"HB_DB_PATH={tmp}/db.sqlite",
                    "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"]); time.sleep(7)
    mine = pids() - before
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    try:
        print("\nArticle")
        ui("load", f"http://127.0.0.1:{PORT}/news.html"); time.sleep(3)
        ui("tab", "reader", "0"); time.sleep(3)
        body = js("document.body.innerText") or ""
        check("le titre de l'article est affiché", "Lisbonne, la ville blanche" in body)
        check("le texte de l'article est là (10 paragraphes)", sum(f"Paragraphe {i} :" in body for i in range(1, 11)) == 10)
        check("l'intertitre est gardé", "Une capitale à taille humaine" in body)
        check("l'auteur et le site sont indiqués", "Marie Dupont" in body and "Le Journal" in body)
        check("le temps de lecture est indiqué", "min de lecture" in body)
        for junk in ["Accueil", "Les plus lus", "Publicité", "Nous utilisons des cookies", "TEXTE-CACHE", "Abonnez-vous", "Commentaires", "Mentions légales"]:
            check(f"« {junk} » n'est pas dans la page de lecture", junk not in body)
        check("le lien utile est gardé", js("[...document.querySelectorAll('main a')].some(a => a.href.includes('wikipedia.org/wiki/Lisbonne'))") is True)
        check("l'image est gardée", js("document.querySelectorAll('main img').length") == 1)
        check("aucun script ni cadre dans la page de lecture", js("document.querySelectorAll('script, iframe, form').length") == 0)
        check("la page a une politique de sécurité qui interdit les scripts", "default-src 'none'" in (js("document.querySelector('meta[http-equiv=Content-Security-Policy]').content") or ""))
        check("le script de la page d'origine ne s'est pas exécuté", "script exécuté" not in (js("document.title") or ""))
        ui("tab", "reader", "0"); time.sleep(3)
        check("la même commande ramène la page d'origine", "Nous utilisons des cookies" in (js("document.body.innerText") or ""))

        print("\nPage qui n'est pas un article")
        ui("load", f"http://127.0.0.1:{PORT}/shop.html"); time.sleep(3)
        ui("tab", "reader", "0"); time.sleep(2)
        check("une page de boutique reste telle quelle", "Produit 29" in (js("document.body.innerText") or "") and js("document.querySelector('meta[name=oree-reader]')") is None)
    finally:
        for p in mine: subprocess.run(["kill", p])
        server.shutdown()
    print(f"\n{sum(results)}/{len(results)} vérifications passent")
    return 0 if all(results) else 1

if __name__ == "__main__":
    sys.exit(main())
