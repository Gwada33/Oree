#!/usr/bin/env python3
"""A/B of the hidden-tab JavaScript cleanup on a page full of dead objects."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"; BID = "com.nolhan.hyperbrowser"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
import threading
srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
for enabled in (False, True):
    subprocess.run(["defaults", "write", BID, "settings.backgroundCleanup", "-bool", "true" if enabled else "false"])
    before = {p for p, _, _ in bench.procs()}
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
    while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
    time.sleep(1.5)
    for _ in range(10):
        ui("front"); time.sleep(0.5)
        if ui("eval", "document.visibilityState") == "visible": break
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", "s1.localhost:8777/garbage.html"); ui("key", "return"); time.sleep(8)
    procs = [p for p, _, c in bench.procs() if p not in before and "WebContent" in c]
    big = max(procs, key=lambda p: bench.footprint_mb([p])); mb = lambda: round(bench.footprint_mb([big]))
    active = mb()
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", "example.com"); ui("key", "return"); t0 = time.time()
    row = []
    for wait in (5, 50, 90, 130):
        time.sleep(max(0, wait - (time.time() - t0))); row.append(f"{wait}s={mb()}")
    print(f"nettoyage {'ACTIVÉ ' if enabled else 'désactivé'} : actif {active} Mo | caché : " + "  ".join(row), "Mo"); sys.stdout.flush()
    subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5); bench.kill([p for p, _, c in bench.procs() if p not in before and ("HyperBrowser.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
subprocess.run(["defaults", "delete", BID, "settings.backgroundCleanup"])
