#!/usr/bin/env python3
"""Where does the memory go? Per-process footprint and top categories for the app's processes with real sites open."""
import json, os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(__file__))
import bench
HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()
SITES = sys.argv[1:] or ["https://www.youtube.com", "https://x.com"]
before = {p for p, _, _ in bench.procs()}
subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", f"{HB}/HyperBrowser.app", "--args", "--automation"])
while subprocess.run([UI, "state"], capture_output=True).returncode: time.sleep(0.2)
time.sleep(1.5)
for _ in range(10):
    ui("front"); time.sleep(0.5)
    if ui("eval", "document.visibilityState") == "visible": break
for u in SITES:
    ui("action", "newTabAction"); time.sleep(0.5); ui("type", u.replace("https://", "")); ui("key", "return"); time.sleep(7)
time.sleep(15)
rows = []
for pid, _, cmd in bench.procs():
    if pid in before or not ("HyperBrowser.app" in cmd or "com.apple.WebKit" in cmd): continue
    path = tempfile.mktemp(suffix=".json")
    subprocess.run(["/usr/bin/footprint", "-j", path, str(pid)], capture_output=True)
    try: d = json.load(open(path))["processes"][0]
    except Exception: continue
    os.unlink(path)
    name = re.sub(r".*/", "", cmd.split(" ")[0]).replace("com.apple.WebKit.", "")
    raw = d.get("categories", {})
    items = raw.items() if isinstance(raw, dict) else [(c.get("category", "?"), c) for c in raw if isinstance(c, dict)]
    cats = sorted(((v.get("dirty", 0) + v.get("swapped", 0) if isinstance(v, dict) else 0, k) for k, v in items), reverse=True)[:5]
    rows.append((d.get("footprint", 0), pid, name, cats))
rows.sort(reverse=True)
total = sum(r[0] for r in rows)
print(f"TOTAL {total/1048576:.0f} MB over {len(rows)} processes")
for fp, pid, name, cats in rows:
    print(f"{fp/1048576:7.0f} MB  {name:14s} pid {pid}   " + ", ".join(f"{c} {b/1048576:.0f}MB" for b, c in cats[:4]))
subprocess.run(["pkill", "-x", "HyperBrowser"]); time.sleep(1.5); bench.kill([r[1] for r in rows])
