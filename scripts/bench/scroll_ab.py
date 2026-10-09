#!/usr/bin/env python3
"""In-page smoothness A/B: scroll a heavy page for 4 s and read requestAnimationFrame stats.
Each config is a fresh HyperBrowser launch (env + settings toggles); results are medians over runs."""
import json, os, subprocess, sys, time, statistics, threading
sys.path.insert(0, os.path.dirname(__file__))
import bench

HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"; BID = "com.nolhan.hyperbrowser"
URL = sys.argv[2] if len(sys.argv) > 2 else f"http://localhost:{bench.PORT}/scroll.html"

def setting(key, value): subprocess.run(["defaults", "write", BID, key, "-bool", "true" if value else "false"])
CONFIGS = {
    "baseline":        dict(env={}, fp=True, ads=True),
    "no-fingerprint":  dict(env={}, fp=False, ads=True),
    "no-adblock":      dict(env={}, fp=True, ads=False),
    "no-card-shadow":  dict(env={"HB_NO_CARD_SHADOW": "1"}, fp=True, ads=True),
    "no-card-mask":    dict(env={"HB_NO_CARD_MASK": "1", "HB_NO_CARD_SHADOW": "1"}, fp=True, ads=True),
    "everything-off":  dict(env={"HB_NO_CARD_MASK": "1", "HB_NO_CARD_SHADOW": "1"}, fp=False, ads=False),
}

def ui(*a): return subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

def run(cfg):
    setting("settings.fingerprintProtection", cfg["fp"]); setting("settings.adBlockEnabled", cfg["ads"])
    env = {"HB_FRESH_SESSION": "1", **cfg["env"]}
    subprocess.run(["open", "-g", "-n"] + sum([["--env", f"{k}={v}"] for k, v in env.items()], []) + [f"{HB}/HyperBrowser.app", "--args", "--automation"])
    while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.1)
    time.sleep(1.5)
    ui("front"); time.sleep(0.5)   # a scripted launch is occluded -> page "hidden" -> throttled
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", URL.replace("http://", "")); ui("key", "return")
    time.sleep(8)
    for _ in range(10):                 # occlusion state takes a moment to update
        ui("front"); time.sleep(0.7)
        if ui("eval", "document.visibilityState") == "visible": break
    else:
        raise SystemExit("page never became visible: results would be meaningless")
    ui("eval", "document.body.focus(); runScroll(4000); 1"); time.sleep(6)
    res = json.loads(ui("eval", "JSON.stringify(window.__res)") or "null")
    subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(2.5)
    return res

if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    names = sys.argv[3:] or list(CONFIGS)
    srv = bench.ThreadingHTTPServer(("127.0.0.1", bench.PORT), bench.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    summary = {}
    try:
        for name in names:
            rs = [r for r in (run(CONFIGS[name]) for _ in range(runs)) if r]
            summary[name] = rs
            print(name, json.dumps(rs)); sys.stdout.flush()
    finally:
        for k in ("settings.fingerprintProtection", "settings.adBlockEnabled"): setting(k, True)   # restore defaults
    print("\nconfig            fps(median)  p95ms  max ms  frames>20ms")
    for name, rs in summary.items():
        if rs: print(f"{name:16s}  {statistics.median(r['fps'] for r in rs):8.1f}  {statistics.median(r['p95Ms'] for r in rs):7.1f}  {statistics.median(r['maxMs'] for r in rs):6.1f}  {statistics.median(r['over20'] for r in rs):6.0f}")
