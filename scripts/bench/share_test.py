#!/usr/bin/env python3
"""Memory of two real sites open together: separate processes (default) vs one shared process."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SITES = sys.argv[1:] or ["https://www.youtube.com", "https://x.com"]
for name, env in [("processus séparés (défaut)", {}), ("un seul processus partagé", {"HB_WK_POOL": "usesSingleWebProcess=1"})]:
    for run in (1, 2):
        before = {p for p, _, _ in bench.procs()}
        full = {"HB_FRESH_SESSION": "1", **env}
        subprocess.run(["open", "-g", "-n"] + sum([["--env", f"{k}={v}"] for k, v in full.items()] , []) + [f"{HB}/Oree.app", "--args", "--automation"])
        while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.1)
        time.sleep(1.5)
        for _ in range(10):
            ui("front"); time.sleep(0.5)
            if ui("eval", "document.visibilityState") == "visible": break
        for u in SITES:
            ui("action", "newTabAction"); time.sleep(0.5); ui("type", u.replace("https://", "")); ui("key", "return"); time.sleep(6)
        time.sleep(15)
        pids = [p for p, _, cmd in bench.procs() if p not in before and ("Oree.app" in cmd or bench.WEBKIT_HELPER.search(cmd))]
        print(json.dumps({"config": name, "run": run, "mem_mb": round(bench.footprint_mb(pids)), "procs": len(pids), "webkit": ui("webkit").split(" ")[0]})); sys.stdout.flush()
        subprocess.run(["pkill", "-x", "Oree"]); time.sleep(1.5); bench.kill(pids); time.sleep(2)
