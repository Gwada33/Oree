#!/usr/bin/env python3
"""Browser benchmark: launch -> first request, JS/DOM speed, and memory with N identical tabs open.

  python3 scripts/bench/bench.py hyperbrowser brave [safari orion firefox] [--tabs 5] [--runs 3]

Everything is served from a local server (no network variance). Memory is the
sum of `phys_footprint` (what Activity Monitor shows as "Mémoire") over the
browser's own processes: exact for Chromium (identified by its throwaway
profile dir); for WebKit apps, the main process plus every WebKit/Safari helper
that appeared after launch.
"""
import json, os, re, subprocess, sys, tempfile, threading, time, shutil, statistics
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

SITE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")
PORT = 8777
events = []          # (server_time, kind, payload)
lock = threading.Lock()

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=SITE, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        with lock: events.append((time.time(), "get", self.path))
        super().do_GET()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with lock: events.append((time.time(), "beacon", json.loads(body or b"{}")))
        self.send_response(204); self.end_headers()

def procs():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)", line)
        if m: res.append((int(m[1]), int(m[2]), m[3]))
    return res

def footprint_mb(pids):
    if not pids: return 0.0
    path = tempfile.mktemp(suffix=".json")
    subprocess.run(["/usr/bin/footprint", "-j", path] + [str(p) for p in pids], capture_output=True)
    try: data = json.load(open(path))
    except Exception: return 0.0
    os.unlink(path)
    total = 0
    for p in data.get("processes", []):
        total += p.get("footprint", 0)
    return total / 1048576

def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.25)
    return False

WEBKIT_HELPER = re.compile(r"com\.apple\.WebKit\.|com\.apple\.Safari|SafariPlatformSupport|Orion|OrionWebContent|Firefox|plugin-container|firefox")

class Target:
    def __init__(self, name, launch, matcher):
        self.name, self.launch, self.matcher = name, launch, matcher

# Distinct "sites" (each *.localhost is its own site): WebKit would otherwise put
# same-site tabs in one process and hide the real per-tab cost.
def urls(n): return [f"http://s{i}.localhost:{PORT}/bench.html?id={i}" for i in range(n)]

def run_one(t, tabs, idle):
    with lock: events.clear()
    before = {p for p, _, _ in procs()}
    t0 = time.time()
    ctx = t.launch(urls(tabs))
    def done(): 
        with lock: return sum(1 for _, k, d in events if k == "beacon" and d.get("kind") == "done")
    ok = wait_for(lambda: done() >= tabs, 90)
    t_all = time.time() - t0
    with lock:
        gets = [ts for ts, k, d in events if k == "get" and "bench.html" in d]
        beacons = [d for _, k, d in events if k == "beacon" and d.get("kind") == "done"]
    first = (min(gets) - t0) if gets else None
    time.sleep(idle)
    mine = [p for p, _, cmd in procs() if t.matcher(p, cmd, before, ctx)]
    mem = footprint_mb(mine)
    t.quit(ctx, mine)
    time.sleep(3)
    js = statistics.mean(b["total"] for b in beacons) if beacons else None
    return {"ok": ok, "first_request_s": first, "all_loaded_s": t_all if ok else None, "js_ms": js,
            "mem_mb": mem, "procs": len(mine), "ua": beacons[0]["ua"][:70] if beacons else ""}

# ---- targets -------------------------------------------------------------
def kill(pids):
    for p in pids:
        try: os.kill(p, 15)
        except ProcessLookupError: pass
    time.sleep(2)
    for p in pids:
        try: os.kill(p, 9)
        except ProcessLookupError: pass

def hb_launch(urls_):
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", os.path.expanduser("~/HyperBrowser/HyperBrowser.app"), "--args", "--automation"])
    time.sleep(5)
    ui = os.path.expanduser("~/HyperBrowser/scripts/ui.sh")
    for u in urls_:
        subprocess.run([ui, "action", "newTabAction"], capture_output=True); time.sleep(0.4)
        subprocess.run([ui, "type", u.replace("http://", "")], capture_output=True)
        subprocess.run([ui, "key", "return"], capture_output=True); time.sleep(0.3)
    return None
def hb_match(pid, cmd, before, ctx):
    return pid not in before and ("HyperBrowser.app" in cmd or WEBKIT_HELPER.search(cmd) is not None)

def brave_launch(urls_):
    d = tempfile.mkdtemp(prefix="bench-brave-")
    subprocess.run(["open", "-g", "-n", "-a", "Brave Browser", "--args", f"--user-data-dir={d}", "--no-first-run",
                    "--no-default-browser-check", "--disable-sync"] + urls_)
    return d
def brave_match(pid, cmd, before, ctx): return f"--user-data-dir={ctx}" in cmd
def brave_quit(ctx, pids): kill(pids); shutil.rmtree(ctx, ignore_errors=True)

def app_launch(app):
    def go(urls_):
        subprocess.run(["open", "-a", app] + urls_); return None
    return go
def webkit_match(app_name):
    def m(pid, cmd, before, ctx):
        return pid not in before and (f"{app_name}.app" in cmd or WEBKIT_HELPER.search(cmd) is not None)
    return m

TARGETS = {
    "hyperbrowser": Target("HyperBrowser", hb_launch, hb_match),
    "brave": Target("Brave (profil isolé)", brave_launch, brave_match),
    "safari": Target("Safari", app_launch("Safari"), webkit_match("Safari")),
    "orion": Target("Orion", app_launch("Orion"), webkit_match("Orion")),
    "firefox": Target("Firefox", app_launch("Firefox"), webkit_match("Firefox")),
}
for k, t in TARGETS.items():
    t.quit = (lambda ctx, pids: kill(pids)) if k != "brave" else brave_quit

if __name__ == "__main__":
    args = sys.argv[1:]
    tabs = int(args[args.index("--tabs") + 1]) if "--tabs" in args else 5
    runs = int(args[args.index("--runs") + 1]) if "--runs" in args else 1
    names = [a for a in args if a in TARGETS]
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"machine: {subprocess.run(['sysctl','-n','machdep.cpu.brand_string'],capture_output=True,text=True).stdout.strip()}, tabs={tabs}, runs={runs}")
    results = {}
    for n in names:
        rs = []
        for r in range(runs):
            res = run_one(TARGETS[n], tabs, idle=20)
            print(n, r + 1, json.dumps(res)); sys.stdout.flush(); rs.append(res)
        results[n] = rs
    json.dump(results, open(os.path.join(os.path.dirname(__file__), "last-results.json"), "w"), indent=1)
