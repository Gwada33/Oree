#!/usr/bin/env python3
"""The shipped long-page heuristic on a plain long list (no hand-written CSS)."""
import os, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"; BID = "com.nolhan.hyperbrowser"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
try:
    for run in range(2):
        for on in (False, True):
            subprocess.run(["defaults", "write", BID, "settings.lightLongPages", "-bool", "true" if on else "false"])
            before = {p for p, _, _ in bench.procs()}
            subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/Oree.app", "--args", "--automation"])
            while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
            time.sleep(1.5)
            for _ in range(10):
                ui("front"); time.sleep(0.5)
                if ui("eval", "document.visibilityState") == "visible": break
            ui("action", "newTabAction"); time.sleep(0.5); ui("type", "s1.localhost:8777/longlist.html"); ui("key", "return"); time.sleep(3)
            h0 = int(ui("eval", "document.documentElement.scrollHeight"))
            time.sleep(10)
            h1 = int(ui("eval", "document.documentElement.scrollHeight"))
            applied = ui("eval", "[...document.querySelectorAll('.c')].filter(e => getComputedStyle(e).contentVisibility === 'auto').length")
            for _ in range(6): ui("eval", "window.scrollBy(0, 3000); 1"); time.sleep(0.8)
            ui("eval", "window.scrollTo(0, 0); 1"); time.sleep(8)
            big = max([p for p, _, c in bench.procs() if p not in before and "WebContent" in c], key=lambda p: bench.footprint_mb([p]))
            ms = ui("eval", "(() => { const t = performance.now(); document.body.style.zoom = 1.001; document.body.offsetHeight; document.body.style.zoom = 1; document.body.offsetHeight; return Math.round(performance.now() - t); })()")
            print(f"run {run+1} {'ACTIVÉ   ' if on else 'désactivé'} : {round(bench.footprint_mb([big]))} Mo, relayout {ms} ms, hauteur de page {h0} -> {h1} px, blocs traités : {applied}"); sys.stdout.flush()
            subprocess.run(["pkill", "-x", "Oree"]); time.sleep(1.5)
            bench.kill([p for p, _, c in bench.procs() if p not in before and ("Oree.app" in c or bench.WEBKIT_HELPER.search(c))]); time.sleep(2)
finally:
    subprocess.run(["defaults", "delete", BID, "settings.lightLongPages"])
