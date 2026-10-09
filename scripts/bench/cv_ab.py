#!/usr/bin/env python3
"""A/B of CSS `content-visibility: auto` on a long, infinite-scroll page (memory of the page process)."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SITE = sys.argv[1] if len(sys.argv) > 1 else "www.youtube.com"
ITEM = sys.argv[2] if len(sys.argv) > 2 else "ytd-rich-item-renderer"
RUNS = int(sys.argv[3]) if len(sys.argv) > 3 else 2
CSS = f"{ITEM}{{content-visibility:auto;contain-intrinsic-size:auto 300px}}"
for run in range(RUNS):
    for apply in (False, True):
        before = {p for p, _, _ in bench.procs()}
        subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/Oree.app", "--args", "--automation"])
        while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
        time.sleep(1.5)
        for _ in range(10):
            ui("front"); time.sleep(0.5)
            if ui("eval", "document.visibilityState") == "visible": break
        ui("action", "newTabAction"); time.sleep(0.5); ui("type", SITE); ui("key", "return"); time.sleep(18)
        if apply:
            ui("eval", f"var s=document.createElement('style'); s.textContent='{CSS}'; document.head.appendChild(s); 1")
        for _ in range(14):                                   # scroll down to make the page load many items
            ui("eval", "window.scrollBy(0, 1800); 1"); time.sleep(1.2)
        ui("eval", "window.scrollTo(0, 0); 1"); time.sleep(12)
        procs = [p for p, _, c in bench.procs() if p not in before and "WebContent" in c]
        big = max(procs, key=lambda p: bench.footprint_mb([p]))
        info = ui("eval", f"document.querySelectorAll('{ITEM}').length + ' items, hauteur ' + document.body.scrollHeight")
        print(f"run {run+1} {'AVEC' if apply else 'SANS'} content-visibility : {round(bench.footprint_mb([big]))} Mo  ({info})"); sys.stdout.flush()
        subprocess.run(["pkill", "-x", "Oree"]); time.sleep(1.5)
        bench.kill([p for p, _, c in bench.procs() if p not in before and ("Oree.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
