#!/usr/bin/env python3
import os, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
for run in range(2):
    for cv in (False, True):
        before = {p for p, _, _ in bench.procs()}
        subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
        while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
        time.sleep(1.5)
        for _ in range(10):
            ui("front"); time.sleep(0.5)
            if ui("eval", "document.visibilityState") == "visible": break
        ui("action", "newTabAction"); time.sleep(0.5); ui("type", "s1.localhost:8777/longlist.html" + ("#cv" if cv else "")); ui("key", "return"); time.sleep(10)
        for _ in range(6): ui("eval", "window.scrollBy(0, 3000); 1"); time.sleep(0.8)
        ui("eval", "window.scrollTo(0, 0); 1"); time.sleep(8)
        big = max([p for p, _, c in bench.procs() if p not in before and "WebContent" in c], key=lambda p: bench.footprint_mb([p]))
        ms = ui("eval", "(() => { const t = performance.now(); document.body.style.zoom = 1.001; document.body.offsetHeight; document.body.style.zoom = 1; document.body.offsetHeight; return Math.round(performance.now() - t); })()")
        print(f"run {run+1} {'AVEC' if cv else 'SANS'} content-visibility : {round(bench.footprint_mb([big]))} Mo, relayout complet {ms} ms"); sys.stdout.flush()
        subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5)
        bench.kill([p for p, _, c in bench.procs() if p not in before and ("HyperBrowser.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
