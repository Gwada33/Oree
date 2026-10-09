#!/usr/bin/env python3
"""Does WebKit already release memory from a hidden tab? And does a forced GC help?
Opens a real heavy site, hides it behind another tab, samples its process footprint over time."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SITE = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "www.youtube.com"
AUTO = "--auto" in sys.argv   # rely on the app's own cleanup instead of forcing one
before = {p for p, _, _ in bench.procs()}
subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/Oree.app", "--args", "--automation"])
while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
time.sleep(1.5)
for _ in range(10):
    ui("front"); time.sleep(0.5)
    if ui("eval", "document.visibilityState") == "visible": break
ui("action", "newTabAction"); time.sleep(0.5); ui("type", SITE); ui("key", "return"); time.sleep(25)
procs = [p for p, _, cmd in bench.procs() if p not in before and "WebContent" in cmd]
big = max(procs, key=lambda p: bench.footprint_mb([p]))
mb = lambda: round(bench.footprint_mb([big]))
print(f"{SITE}: processus {big}, actif : {mb()} Mo")
ui("action", "newTabAction"); time.sleep(0.5); ui("type", "example.com"); ui("key", "return")   # hides the heavy tab
t0 = time.time()
for wait in ((5, 30, 60, 90, 120) if AUTO else (5, 30, 60, 90)):
    time.sleep(max(0, wait - (time.time() - t0)))
    print(f"caché depuis {wait:3d} s : {mb()} Mo")
if not AUTO:
    print("GC forcé :", ui("gc")); time.sleep(10)
    print(f"10 s après le GC     : {mb()} Mo")
subprocess.run(["pkill", "-x", "Oree"]); time.sleep(1.5); bench.kill([p for p, _, c in bench.procs() if p not in before and ("Oree.app" in c or bench.WEBKIT_HELPER.search(c))])
