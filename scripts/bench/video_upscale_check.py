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

def launch(auto, engine="webgl"):
    tmp = tempfile.mkdtemp(prefix="vidup-"); auto_dir = os.path.join(tmp, "auto")
    for d in (auto_dir, os.path.join(tmp, "ext")): os.makedirs(d)
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto_dir, HB_AI_NO_AGENT="1",
               HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"), HB_VIDEO_UPSCALE="1" if auto else "0", HB_VIDEO_UPSCALE_FORCE="1", HB_VIDEO_ENGINE=engine)
    os.environ["HB_AUTOMATION_DIR"] = auto_dir
    return subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

PROBE = """(function(){ var c=document.querySelector('canvas[data-oree-upscale]'); if(!c) return 'aucun canevas';
  var t=document.createElement('canvas'); t.width=32; t.height=18; var x=t.getContext('2d'); x.drawImage(c,0,0,32,18); var d=x.getImageData(0,0,32,18).data, s=0; for(var i=0;i<d.length;i+=4) s+=d[i]+d[i+1]+d[i+2];
  var v=document.getElementById('v'); var u=document.createElement('canvas'); u.width=32; u.height=18; var y=u.getContext('2d'); y.drawImage(v,0,0,32,18); var e=y.getImageData(0,0,32,18).data, r=0; for(var j=0;j<e.length;j+=4) r+=e[j]+e[j+1]+e[j+2];
  return 'canevas '+c.width+'x'+c.height+' luminosité='+Math.round(s/(32*18*3))+' vidéo='+Math.round(r/(32*18*3)); })()"""

def play():
    """Une fenêtre d'essai n'est pas visible : la page est « cachée » et n'autoplay pas ; on lance la lecture, dans la page et dans une éventuelle iframe."""
    ui("eval", "(function(){ var all = [document].concat(Array.from(document.querySelectorAll('iframe')).map(function(f){ try { return f.contentDocument } catch (e) { return null } })); all.forEach(function(d){ if (d) { var v = d.getElementById('v'); if (v) v.play(); } }); return 1 })()")

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
        time.sleep(9); ui("load", "http://127.0.0.1:8805/page.html"); time.sleep(3); play(); time.sleep(2)
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
        time.sleep(9); ui("load", "http://127.0.0.1:8805/page.html"); time.sleep(3); play(); time.sleep(2)
        check("réglage activé : la vidéo est agrandie sans rien demander", wait(lambda: ui("eval", PROBE).startswith("canevas"), 15))
    finally:
        p.terminate(); time.sleep(1); p.poll() is None and p.kill()

    print("Vidéo d'une autre origine (sans autorisation CORS)")
    p = launch(auto=True)
    try:
        time.sleep(9); ui("load", "http://127.0.0.1:8805/cross.html"); time.sleep(3); play(); time.sleep(3)
        s = ""
        for _ in range(30):
            s = ui("tab", "upscale", "0")
            if "SecurityError" in s: break
            time.sleep(0.5)
        print("  ", s)
        check("WebGL refuse de lire la vidéo : Orée la laisse telle quelle et le dit", "SecurityError" in s and ui("eval", PROBE) == "aucun canevas")
    finally:
        p.terminate(); time.sleep(1); p.poll() is None and p.kill()
    # --- Le moteur d'Apple, par-dessus la vidéo
    import re as _re
    def stats():
        if os.path.exists("/tmp/oree-upscale-stats.txt"): os.remove("/tmp/oree-upscale-stats.txt")
        ui("tab", "upscalestats", "0"); time.sleep(1.0)
        return open("/tmp/oree-upscale-stats.txt").read() if os.path.exists("/tmp/oree-upscale-stats.txt") else ""
    def number(text, key):
        m = _re.search(key + r"=([\d.]+)", text); return float(m.group(1)) if m else float("nan")
    for scenario, url in (("Moteur Apple, vidéo dans la page", "page.html"), ("Moteur Apple, lecteur dans une iframe (page défilée)", "iframe.html")):
        print(scenario)
        p = launch(auto=False, engine="apple")
        try:
            time.sleep(9); ui("load", f"http://127.0.0.1:8805/{url}"); time.sleep(4); play(); time.sleep(2)
            if "iframe" in url: ui("eval", "window.scrollTo(0, 0); 1"); time.sleep(1.5)
            for _ in range(24):                                  # d'abord attendre que la vidéo soit repérée (sans rien basculer)
                if "on=false" in ui("tab", "upscale", "0"): break
                time.sleep(0.5)
            open("/tmp/oree-upscale.txt", "w").write("toggle"); ui("tab", "upscale", "0"); open("/tmp/oree-upscale.txt", "w").write("")
            time.sleep(6)
            if os.path.exists("/tmp/oree-upscale-eval.txt"): os.remove("/tmp/oree-upscale-eval.txt")
            open("/tmp/oree-upscale-eval.js", "w").write("return await window.__oreeUpscale.measureEncode(60)"); ui("tab", "upscalecall", "0")
            for _ in range(30):
                if os.path.exists("/tmp/oree-upscale-eval.txt"): break
                time.sleep(0.5)
            enc = open("/tmp/oree-upscale-eval.txt").read() if os.path.exists("/tmp/oree-upscale-eval.txt") else ""
            print("   coût côté page (copie + JPEG + base64) :", enc)
            m = _re.search(r'"ms":([\d.]+)', enc)
            if "iframe" not in url: check("côté page, copier + encoder une image 320×180 coûte moins de 12 ms", bool(m) and float(m.group(1)) < 12)
            st0 = stats(); print("   (page cachée, minuteurs freinés :", st0[:60], ")")
            # Une fenêtre d'essai cachée freine la page : on rejoue l'image reçue à 30 images/s directement dans la chaîne native.
            lost0 = number(st0, "perdues") if "perdues" in st0 else 0
            open("/tmp/oree-upscale-feed.txt", "w").write("150 30"); ui("tab", "upscalefeed", "0"); time.sleep(3)
            mid = stats(); time.sleep(4.5)
            st = stats(); print("  ", st)
            check("pendant la lecture, la vue d'Orée est affichée par-dessus la vidéo", "visible=true" in mid)
            check("150 images rejouées à 30/s : toutes agrandies par l'upscaler d'Apple (au moins 140)", number(st, "out") >= 140)
            check("le moteur n'a pas d'échec", "échec" not in st)
            check("aucune image perdue à 30 images/s (150 rejouées)", number(st, "perdues") - lost0 <= 3)
            check("la latence image → écran reste sous 150 ms", number(st, "latence_ms") < 150)
            check("l'agrandissement lui-même prend moins de 10 ms par image", number(st, "agrandissement_ms") < 10)
            if "iframe" not in url:
                m = _re.search(r"rect=(-?\d+),(-?\d+),(\d+)x(\d+)", st)
                check("la vue couvre la vidéo (960×540, à 20 px du bord)", bool(m) and abs(int(m.group(3)) - 960) <= 4 and abs(int(m.group(4)) - 540) <= 4 and abs(int(m.group(1)) - 20) <= 4)
                ui("tab", "upscaledump", "0")
                from PIL import Image; import numpy as np
                out = Image.open("/tmp/oree-upscale-out.png").convert("L"); a = np.asarray(out, dtype=float)
                check("l'image agrandie fait 2× la source (640×360) et n'est pas noire", out.size == (640, 360) and a.mean() > 5)
            else:
                m = _re.search(r"rect=(-?\d+),(-?\d+),(\d+)x(\d+)", st)
                check("dans l'iframe, la vue est au bon endroit (iframe à 100,60 + vidéo à 20,20 → ≈ 120,80)", bool(m) and abs(int(m.group(1)) - 120) <= 6 and abs(int(m.group(2)) - 80) <= 6)
        finally:
            p.terminate(); time.sleep(1); p.poll() is None and p.kill()
    ok = sum(results); print(f"\n{ok}/{len(results)} vérifications passent"); raise SystemExit(0 if ok == len(results) else 1)

main()
