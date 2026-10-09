#!/usr/bin/env python3
"""A/B: launch with 8 saved tabs, eager restore (old behaviour) vs lazy (new).
Uses a throwaway database (HB_DB_PATH), so the real session is never touched."""
import os, sqlite3, subprocess, sys, tempfile, time, json, statistics, threading
sys.path.insert(0, os.path.dirname(__file__))
import bench

HB = os.path.expanduser("~/HyperBrowser")
UI = f"{HB}/scripts/ui.sh"
TABS = 8

def launch(db, eager):
    env = {"HB_DB_PATH": db, **({"HB_EAGER_RESTORE": "1"} if eager else {})}
    args = ["open", "-g", "-n"] + sum([["--env", f"{k}={v}"] for k, v in env.items()], []) + [f"{HB}/HyperBrowser.app", "--args", "--automation"]
    subprocess.run(args)

def ready(timeout=30):
    t = time.time()
    while time.time() - t < timeout:
        if subprocess.run([UI, "state"], capture_output=True).returncode == 0: return time.time() - t
        time.sleep(0.05)
    return None

def run(db, eager):
    with bench.lock: bench.events.clear()
    before = {p for p, _, _ in bench.procs()}
    t0 = time.time()
    launch(db, eager)
    r = ready()
    t_ready = time.time() - t0
    time.sleep(20)
    with bench.lock:
        loaded = sum(1 for _, k, d in bench.events if k == "beacon" and d.get("kind") == "done")
    mine = [p for p, _, cmd in bench.procs() if p not in before and ("HyperBrowser.app" in cmd or bench.WEBKIT_HELPER.search(cmd))]
    mem = bench.footprint_mb(mine)
    bench.kill(mine); time.sleep(3)
    return {"mode": "eager" if eager else "lazy", "ready_s": round(t_ready, 2), "pages_loaded": loaded, "mem_mb": round(mem), "procs": len(mine)}

if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    db = tempfile.mktemp(suffix=".sqlite")
    # Let the app create the schema once, then seed the saved session.
    launch(db, False); ready(); time.sleep(2); subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(3)
    con = sqlite3.connect(db)
    for i, url in enumerate(bench.urls(TABS)):
        con.execute("INSERT INTO tabSessions (orderIndex, url, isPrivate, interactionState, updatedAt) VALUES (?,?,0,NULL,datetime('now'))", (i, url))
    con.commit(); con.close()
    results = []
    for r in range(runs):
        for eager in (True, False):
            res = run(db, eager); results.append(res); print(json.dumps(res)); sys.stdout.flush()
    for mode in ("eager", "lazy"):
        rs = [x for x in results if x["mode"] == mode]
        print(mode, "median ready %.2fs, mem %d MB, pages loaded %d" % (statistics.median(x["ready_s"] for x in rs), statistics.median(x["mem_mb"] for x in rs), statistics.median(x["pages_loaded"] for x in rs)))
