#!/usr/bin/env python3
"""Agrandissement des vidéos dans Orée : repérage, bascule par vidéo, mode automatique, vidéo d'une autre origine (refusée par WebGL), sur une petite vidéo locale (320×180 affichée en 960×540).

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/video_upscale_check.py
"""
import functools, http.server, os, re, subprocess, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "video_fixture")

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

class RangeHandler(http.server.SimpleHTTPRequestHandler):
    """WebKit lit les vidéos par morceaux : le serveur doit savoir répondre aux requêtes « Range »."""
    def log_message(self, *a): pass
    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path): return super().send_head()
        size = os.path.getsize(path); rng = self.headers.get("Range"); start, end = 0, size - 1
        if rng and (m := re.match(r"bytes=(\d*)-(\d*)", rng)):
            start = int(m.group(1) or 0); end = int(m.group(2)) if m.group(2) else size - 1
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else: self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path)); self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(end - start + 1)); self.end_headers()
        f = open(path, "rb"); f.seek(start); self._remaining = end - start + 1; return f
    def copyfile(self, source, outputfile):
        left = getattr(self, "_remaining", None)
        while left is None or left > 0:
            chunk = source.read(min(65536, left) if left is not None else 65536)
            if not chunk: break
            try: outputfile.write(chunk)
            except Exception: break
            if left is not None: left -= len(chunk)

def serve(port):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(RangeHandler, directory=FIXTURE))
    threading.Thread(target=server.serve_forever, daemon=True).start()

def launch(auto):
    tmp = tempfile.mkdtemp(prefix="vidup-"); auto_dir = os.path.join(tmp, "auto")
    for d in (auto_dir, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto_dir, HB_AI_NO_AGENT="1",
               HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"), HB_VIDEO_UPSCALE="1" if auto else "0", HB_VIDEO_UPSCALE_FORCE="1")
    os.environ["HB_AUTOMATION_DIR"] = auto_dir
    return subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

PROBE = """(function(){ var c=document.querySelector('canvas[data-oree-upscale]'); if(!c) return 'aucun canevas';
  var t=document.createElement('canvas'); t.width=32; t.height=18; var x=t.getContext('2d'); x.drawImage(c,0,0,32,18); var d=x.getImageData(0,0,32,18).data, s=0; for(var i=0;i<d.length;i+=4) s+=d[i]+d[i+1]+d[i+2];
  var v=document.getElementById('v'); var u=document.createElement('canvas'); u.width=32; u.height=18; var y=u.getContext('2d'); y.drawImage(v,0,0,32,18); var e=y.getImageData(0,0,32,18).data, r=0; for(var j=0;j<e.length;j+=4) r+=e[j]+e[j+1]+e[j+2];
  return 'canevas '+c.width+'x'+c.height+' luminosité='+Math.round(s/(32*18*3))+' vidéo='+Math.round(r/(32*18*3)); })()"""

def main():
    serve(8805); serve(8806)
    results = []
    def check(name, ok): results.append(bool(ok)); print(("  ok     " if ok else "  ÉCHEC  ") + name)
    def wait(pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pred(): return True
            time.sleep(0.5)
        return False

    print("Vidéo locale, mode « vidéo par vidéo »")
    p = launch(auto=False)
    try:
        time.sleep(9); ui("load", "http://127.0.0.1:8805/page.html"); time.sleep(4)
        check("la vidéo lue est repérée comme agrandissable (menu du clic droit)", wait(lambda: "on=false" in ui("tab", "upscale", "0") and "320x180" in ui("tab", "upscale", "0"), 12))
        print("  ", ui("tab", "upscale", "0"))
        check("sans choix, rien n'est dessiné sur la vidéo", ui("eval", PROBE) == "aucun canevas")
        open("/tmp/oree-upscale.txt", "w").write("toggle"); ui("tab", "upscale", "0"); open("/tmp/oree-upscale.txt", "w").write("")
        check("« Améliorer cette vidéo » : un canevas apparaît et l'image n'est pas noire", wait(lambda: (lambda r: r.startswith("canevas") and int(r.split("luminosité=")[1].split()[0]) > 5)(ui("eval", PROBE)), 12))
        print("  ", ui("eval", PROBE))
        check("le menu propose maintenant de revenir à l'original", "on=true" in ui("tab", "upscale", "0"))
        open("/tmp/oree-upscale.txt", "w").write("toggle"); ui("tab", "upscale", "0"); open("/tmp/oree-upscale.txt", "w").write("")
        check("en revenant à l'original, le canevas disparaît", wait(lambda: ui("eval", PROBE) == "aucun canevas", 8))
    finally:
        p.terminate(); time.sleep(1); p.poll() is None and p.kill()

    print("Mode automatique")
    p = launch(auto=True)
    try:
        time.sleep(9); ui("load", "http://127.0.0.1:8805/page.html"); time.sleep(4)
        check("réglage activé : la vidéo est agrandie sans rien demander", wait(lambda: ui("eval", PROBE).startswith("canevas"), 15))
    finally:
        p.terminate(); time.sleep(1); p.poll() is None and p.kill()

    print("Vidéo d'une autre origine (sans autorisation CORS)")
    p = launch(auto=True)
    try:
        time.sleep(9); ui("load", "http://127.0.0.1:8805/cross.html"); time.sleep(5)
        s = ""
        for _ in range(30):
            s = ui("tab", "upscale", "0")
            if "SecurityError" in s: break
            time.sleep(0.5)
        print("  ", s)
        check("WebGL refuse de lire la vidéo : Orée la laisse telle quelle et le dit", "SecurityError" in s and ui("eval", PROBE) == "aucun canevas")
    finally:
        p.terminate(); time.sleep(1); p.poll() is None and p.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
