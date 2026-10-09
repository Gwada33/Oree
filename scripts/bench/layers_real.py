#!/usr/bin/env python3
"""Do real sites abuse GPU-layer hints? Counts promoted elements, then neutralises them in place and re-measures the page."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SITES = sys.argv[1:] or ["www.apple.com/fr/macbook-pro/", "stripe.com", "www.nytimes.com", "www.theverge.com"]
COUNT = """(() => { let willChange = 0, identity3d = 0;
  for (const e of document.querySelectorAll('*')) { const c = getComputedStyle(e);
    if (c.willChange && c.willChange !== 'auto') willChange++;
    if (c.transform === 'matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)') identity3d++; }
  return JSON.stringify({ willChange, identity3d, elements: document.getElementsByTagName('*').length }); })()"""
FIX = """(() => { let n = 0; const s = document.createElement('style'); s.textContent = '*{will-change:auto !important}'; document.documentElement.appendChild(s);
  for (const e of document.querySelectorAll('*')) { if (getComputedStyle(e).transform === 'matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)') { e.style.setProperty('transform', 'none', 'important'); n++; } }
  return n; })()"""
for site in SITES:
    before = {p for p, _, _ in bench.procs()}
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
    while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
    time.sleep(1.5)
    for _ in range(10):
        ui("front"); time.sleep(0.5)
        if ui("eval", "document.visibilityState") == "visible": break
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", site); ui("key", "return"); time.sleep(14)
    def measure():
        tot = 0
        for p, _, c in bench.procs():
            if p not in before and ("WebContent" in c or "GPU" in c): tot += bench.footprint_mb([p])
        return round(tot)
    for _ in range(4): ui("eval", "window.scrollBy(0, 900); 1"); time.sleep(1.2)
    ui("eval", "window.scrollTo(0, 0); 1"); time.sleep(4)
    info = json.loads(ui("eval", COUNT) or "{}")
    m0 = measure()
    fixed = ui("eval", FIX); time.sleep(8)
    m1 = measure()
    print(f"{site:34s} will-change: {info.get('willChange'):>4}, translateZ(0): {info.get('identity3d'):>4} sur {info.get('elements'):>5} éléments | page+GPU {m0:4d} Mo -> {m1:4d} Mo après neutralisation"); sys.stdout.flush()
    subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5)
    bench.kill([p for p, _, c in bench.procs() if p not in before and ("HyperBrowser.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
