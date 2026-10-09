#!/usr/bin/env python3
"""A/B tests of WebKit internals against this app.
  python3 scripts/bench/webkit_ab.py bfcache     # memory + back-navigation speed with/without the back-forward cache
  python3 scripts/bench/webkit_ab.py hidden      # CPU of background tabs with timer-throttling features
"""
import json, os, re, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(__file__))
import bench

HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

def launch(env):
    full = {"HB_FRESH_SESSION": "1", **env}
    subprocess.run(["open", "-g", "-n"] + sum([["--env", f"{k}={v}"] for k, v in full.items()], []) + [f"{HB}/HyperBrowser.app", "--args", "--automation"])
    while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.1)
    time.sleep(1.5)
    for _ in range(10):
        ui("front"); time.sleep(0.5)
        if ui("eval", "document.visibilityState") == "visible": return
    raise SystemExit("window never became visible")

def my_pids(before):
    return [p for p, _, cmd in bench.procs() if p not in before and ("HyperBrowser.app" in cmd or bench.WEBKIT_HELPER.search(cmd))]

def cpu_seconds(pids):
    out = subprocess.run(["ps", "-o", "pid=,time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for line in out.splitlines():
        t = line.split()[-1]; m, s = t.split(":"); total += float(m) * 60 + float(s)
    return total

def shutdown(pids):
    subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5); bench.kill(pids); time.sleep(2)

def bfcache(configs, runs):
    for name, env in configs.items():
        for r in range(runs):
            before = {p for p, _, _ in bench.procs()}
            launch(env)
            ui("action", "newTabAction"); time.sleep(0.4); ui("type", "s0.localhost:8777/bench.html?id=0"); ui("key", "return"); time.sleep(2.5)
            for i in range(1, 6):
                ui("load", f"http://s{i}.localhost:8777/bench.html?id={i}"); time.sleep(2.5)
            time.sleep(15)
            pids = my_pids(before); mem = bench.footprint_mb(pids); report = ui("webkit")
            t0 = time.time(); ui("action", "goBack")
            while time.time() - t0 < 10 and "s4.localhost" not in ui("state"): time.sleep(0.02)
            back = time.time() - t0
            print(json.dumps({"config": name, "run": r + 1, "mem_mb": round(mem), "procs": len(pids), "back_s": round(back, 2), "webkit": report})); sys.stdout.flush()
            shutdown(pids)

def hidden(configs, runs):
    for name, env in configs.items():
        for r in range(runs):
            before = {p for p, _, _ in bench.procs()}
            launch(env)
            for i in range(5):
                ui("action", "newTabAction"); time.sleep(0.4); ui("type", f"s{i}.localhost:8777/timers.html"); ui("key", "return"); time.sleep(2)
            time.sleep(15)                      # let throttling settle
            pids = my_pids(before)
            c0 = cpu_seconds(pids); t0 = time.time(); time.sleep(45); c1 = cpu_seconds(pids)
            pct = 100 * (c1 - c0) / (time.time() - t0)
            print(json.dumps({"config": name, "run": r + 1, "cpu_percent_of_one_core": round(pct, 1), "procs": len(pids)})); sys.stdout.flush()
            shutdown(pids)

if __name__ == "__main__":
    mode = sys.argv[1]; runs = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    only = sys.argv[3:]
    pick = lambda d: {k: v for k, v in d.items() if not only or k in only}
    if mode == "bfcache":
        bfcache(pick({"baseline": {}, "page-cache-off": {"HB_WK_POOL": "pageCacheEnabled=0"}}), runs)
    elif mode == "hidden":
        hidden(pick({"baseline": {},
                "timers-auto-increase": {"HB_WK_FEATURES": "HiddenPageDOMTimerThrottlingAutoIncreases=1"},
                "near-suspended": {"HB_WK_FEATURES": "HiddenPageDOMTimerThrottlingAutoIncreases=1,ShouldTakeNearSuspendedAssertions=1"}}), runs)
