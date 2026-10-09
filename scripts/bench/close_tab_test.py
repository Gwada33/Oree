#!/usr/bin/env python3
"""Regression: closing a tab must stop its page and free it.
Opens a page that heartbeats the server; after closing the tab, the heartbeat must stop
and the Tab object must be gone (liveTabs back to its previous value)."""
import os, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
beats = lambda: sum(1 for _, k, d in bench.events if k == "beacon" and d.get("kind") == "beat")
live = lambda: int(ui("state").split("liveTabs=")[1].split()[0])

srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.1)
ui("front"); time.sleep(1)
base_live = live()
ui("action", "newTabAction"); time.sleep(0.5); ui("type", "localhost:8777/beat.html"); ui("key", "return"); time.sleep(3)
b0 = beats(); time.sleep(2); running = beats() - b0
live_open = live()
ui("action", "closeActiveTabAction"); time.sleep(1)
b1 = beats(); time.sleep(3); after = beats() - b1
live_closed = live()
subprocess.run(["pkill", "-x", "HyperBrowser"])
print(f"heartbeats while open (2 s): {running}   after closing (3 s): {after}")
print(f"live tabs: before={base_live} open={live_open} closed={live_closed}")
ok = running > 3 and after == 0 and live_closed == base_live
print("PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
