#!/usr/bin/env python3
"""Qualité de l'agrandissement vidéo d'Orée (bicubique + netteté CAS, WebGL) contre l'agrandissement du navigateur (bilinéaire), sur des images de référence.

  OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/upscale_check.py

Méthode : cinq images en 1920×1080 (quatre morceaux d'une photo aérienne du système, une capture d'interface avec du texte) servent de vérité. Chacune est réduite en 960×540 (la « source »),
puis, pour la variante « compressée », passée dans x264 (CRF 28) comme un vrai flux. Le moteur WebGL de la page (le bloc `core` de VideoUpscaleScript.swift) l'agrandit ×2 dans l'instance d'essai ;
ffmpeg compare à la vérité (PSNR, SSIM). « Netteté » = variance du laplacien de l'image agrandie ÷ celle de la vérité (1,0 = autant de contours qu'à l'origine).
Limites : des images fixes, pas une vidéo (pas de mesure du scintillement d'une image à l'autre) ; la photo n'est pas du sport en direct.
"""
import functools, http.server, json, os, re, shutil, subprocess, sys, tempfile, threading, time
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "upscale_fixture")
SWIFT = os.path.join(ROOT, "Sources", "BrowserUI", "VideoUpscaleScript.swift")
PORT = 8802

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def ff(*args):
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], capture_output=True, text=True)

def metrics(a, b):
    """PSNR et SSIM moyens de a (agrandie) contre b (vérité), par ffmpeg."""
    out = subprocess.run(["ffmpeg", "-hide_banner", "-i", a, "-i", b, "-lavfi", "[0][1]psnr;[0][1]ssim", "-f", "null", "-"], capture_output=True, text=True).stderr
    psnr = float(re.search(r"PSNR.*average:([\d.]+)", out).group(1)); ssim = float(re.search(r"SSIM.*All:([\d.]+)", out).group(1))
    return psnr, ssim

def sharpness(path):
    g = np.asarray(Image.open(path).convert("L"), dtype=np.float64)
    lap = g[1:-1, 1:-1] * 4 - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return lap.var()

def main():
    work = tempfile.mkdtemp(prefix="upscale-")
    # 1. Le moteur, extrait du fichier Swift (une seule source de vérité).
    core = re.search(r"// <core>.*?// </core>", open(SWIFT).read(), re.S).group(0)
    shutil.copy(os.path.join(FIXTURE, "index.html"), work); open(os.path.join(work, "core.js"), "w").write(core)
    # 2. Les images de référence.
    aerial = "/System/Library/Wallpapers/.default/DefaultAerial.jpg"
    truths = []
    for i, (x, y) in enumerate([(0, 0), (2048, 0), (0, 1080), (2048, 1080)]):
        t = os.path.join(work, f"truth{i}.png"); ff("-i", aerial, "-vf", f"crop=1920:1080:{x}:{y}", "-frames:v", "1", t); truths.append(t)
    shot = os.path.join(ROOT, "website", "assets", "shot-palette-light.webp")
    if os.path.exists(shot):
        t = os.path.join(work, "truth4.png"); ff("-i", shot, "-vf", "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080", "-frames:v", "1", t); truths.append(t)
    jobs = []
    for i, t in enumerate(truths):
        clean = os.path.join(work, f"clean{i}.png"); ff("-i", t, "-vf", "scale=960:540:flags=area", clean)
        mp4 = os.path.join(work, f"c{i}.mp4"); ff("-i", clean, "-c:v", "libx264", "-crf", "28", "-pix_fmt", "yuv420p", mp4)
        comp = os.path.join(work, f"comp{i}.png"); ff("-i", mp4, "-frames:v", "1", comp)
        jobs += [{"name": f"clean{i}", "src": f"clean{i}.png", "w": 1920, "h": 1080}, {"name": f"comp{i}", "src": f"comp{i}.png", "w": 1920, "h": 1080}]
    # 3. Le serveur : les fichiers, plus deux POST (« save » pour un PNG, « done » pour les temps).
    done = {}
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.path.startswith("/save"): open(os.path.join(work, re.search(r"name=([^&]+)", self.path).group(1)), "wb").write(body)
            elif self.path == "/done": done.update(json.loads(body))
            self.send_response(200); self.end_headers()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), functools.partial(Handler, directory=work))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # 4. L'instance d'essai.
    auto = os.path.join(work, "auto"); os.makedirs(auto); os.makedirs(os.path.join(work, "ext"))
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(work, "t.db"), HB_EXT_DIR=os.path.join(work, "ext"), HB_AUTOMATION_DIR=auto, HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(work, "keys"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(9); ui("load", f"http://127.0.0.1:{PORT}/index.html"); time.sleep(3)
        ui("eval", f"window.runAll({json.dumps(jobs)}); 1")
        end = time.time() + 240
        while not done and time.time() < end: time.sleep(1)
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    if not done: print("Le navigateur n'a rien rendu en 240 s."); raise SystemExit(1)
    # 4 bis. L'upscaler d'Apple (VideoToolbox, apprentissage), si l'outil `vtsr` est fourni (OREE_VTSR=/chemin/vtsr) : même images, même mesures.
    vt_ms = {}
    vtsr = os.environ.get("OREE_VTSR")
    if vtsr:
        for job in jobs:
            r = subprocess.run([vtsr, os.path.join(work, job["src"]), os.path.join(work, f"{job['name']}_vt.png"), "2", "60"], capture_output=True, text=True)
            m = re.search(r": ([\d.]+) ms/image", r.stdout)
            vt_ms[job["name"]] = float(m.group(1)) if m else float("nan")
            if not m: print(r.stdout[-300:], r.stderr[-300:])
        for name, ms in vt_ms.items(): done.setdefault(name, {})["vt"] = ms
    # 5. Mesures.
    modes = ["bilinear", "bicubic", "cas0.3", "cas0.6", "cas0.9"] + (["vt"] if vtsr else [])
    labels = {"bilinear": "navigateur (bilinéaire)", "bicubic": "bicubique", "cas0.3": "bicubique + netteté 0,3", "cas0.6": "bicubique + netteté 0,6", "cas0.9": "bicubique + netteté 0,9", "vt": "Apple VideoToolbox (IA)"}
    for kind, title in (("clean", "source propre (réduite à la moitié)"), ("comp", "source compressée (x264 CRF 28, comme un flux)")):
        print(f"\n{title}\n  {'méthode':<28} {'PSNR dB':>8} {'SSIM':>7} {'netteté':>8} {'ms/image':>9}")
        for mode in modes:
            p, s, h, ms = [], [], [], []
            for i, t in enumerate(truths):
                out = os.path.join(work, f"{kind}{i}_{mode}.png")
                a, b = metrics(out, t); p.append(a); s.append(b); h.append(sharpness(out) / sharpness(t)); ms.append(done[f"{kind}{i}"][mode])
            print(f"  {labels[mode]:<28} {np.mean(p):>8.2f} {np.mean(s):>7.4f} {np.mean(h):>8.2f} {np.mean(ms):>9.1f}")
    print(f"\nImages dans {work}")

main()
