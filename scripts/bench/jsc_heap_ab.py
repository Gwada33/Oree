#!/usr/bin/env python3
"""JavaScript heap growth factors (reachable through __XPC_JSC_* environment variables) under allocation churn."""
import os, subprocess, sys, threading, time, statistics
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
TIGHT = {"__XPC_JSC_smallHeapGrowthFactor": "1.15", "__XPC_JSC_mediumHeapGrowthFactor": "1.1", "__XPC_JSC_largeHeapGrowthFactor": "1.05"}
configs = [("défaut", {}), ("tas serré", TIGHT)] * int(sys.argv[1] if len(sys.argv) > 1 else 2)
for name, env in configs:
    before = {p for p, _, _ in bench.procs()}
    full = {"HB_FRESH_SESSION": "1", **env}
    subprocess.run(["open", "-g", "-n"] + sum([["--env", f"{k}={v}"] for k, v in full.items()], []) + [f"{HB}/Oree.app", "--args", "--automation"])
    while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
    time.sleep(1.5)
    for _ in range(10):
        ui("front"); time.sleep(0.5)
        if ui("eval", "document.visibilityState") == "visible": break
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", "s1.localhost:8777/churn.html"); ui("key", "return")
    time.sleep(3)
    big = max([p for p, _, c in bench.procs() if p not in before and "WebContent" in c], key=lambda p: bench.footprint_mb([p]))
    samples = []
    for _ in range(9):
        time.sleep(2.2); samples.append(bench.footprint_mb([big]))
    time.sleep(3)
    ops = ui("eval", "window.__ops")
    if not ops.isdigit(): print(name, "page state lost:", ui("state")[:120]); ops = "0"
    print(f"{name:10s} mémoire de la page : moyenne {statistics.mean(samples):4.0f} Mo, pic {max(samples):4.0f} Mo | débit : {int(ops)//1000000:>5} M objets sur 20 s"); sys.stdout.flush()
    subprocess.run(["pkill", "-x", "Oree"]); time.sleep(1.5)
    bench.kill([p for p, _, c in bench.procs() if p not in before and ("Oree.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
