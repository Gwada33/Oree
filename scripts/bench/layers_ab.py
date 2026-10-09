#!/usr/bin/env python3
import os, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
for run in range(1):
    for off in (False, "none"):
        before = {p for p, _, _ in bench.procs()}
        subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
        while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
        time.sleep(1.5)
        for _ in range(10):
            ui("front"); time.sleep(0.5)
            if ui("eval", "document.visibilityState") == "visible": break
        ui("action", "newTabAction"); time.sleep(0.5); ui("type", "s1.localhost:8777/layers.html" + ("#none" if off else "")); ui("key", "return"); time.sleep(12)
        rows = {}
        for p, _, c in bench.procs():
            if p in before: continue
            kind = "page" if "WebContent" in c else "gpu" if "GPU" in c else None
            if kind: rows[kind] = rows.get(kind, 0) + bench.footprint_mb([p])
        layers_ok = ui("eval", "document.querySelectorAll('.l').length")
        print(f"run {run+1} calques GPU {'RETIRÉS   ' if off else 'conservés '}: page {rows.get('page',0):4.0f} Mo + processus graphique {rows.get('gpu',0):4.0f} Mo = {rows.get('page',0)+rows.get('gpu',0):4.0f} Mo ({layers_ok} cartes)"); sys.stdout.flush()
        subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5)
        bench.kill([p for p, _, c in bench.procs() if p not in before and ("HyperBrowser.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
