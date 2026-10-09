#!/usr/bin/env python3
"""Comparatif Orée / Safari / Brave — un seul banc, mêmes pages, mêmes mesures, serveur local (aucune variance réseau).

  python3 scripts/bench/compare.py [--only launch,memory,idle,download] [--browsers oree,safari,brave] [--quick]

Mesures
  launch    `open` -> première requête reçue par le serveur, -> page chargée et JS exécuté (balise "done")
  js        score CPU/DOM/canvas de la page bench.html (médiane), exécutée dans chaque navigateur
  memory    somme des `phys_footprint` de TOUS les processus du navigateur avec 1, 8 et 20 onglets (sites distincts)
  idle      mémoire 5 min plus tard (20 onglets, 1 seul actif) et CPU au repos sur 30 s
  download  fichier de test : 192 Mo à 8 Mo/s PAR connexion (cas CDN) et 1 Go non limité; durée vue par le serveur

Ne touchez pas au Mac pendant l'exécution (les navigateurs passent au premier plan, comme en usage réel).
"""
import ctypes, glob, json, os, re, shutil, statistics, subprocess, sys, tempfile, threading, time
from http.server import ThreadingHTTPServer
import bench as B
import range_server as R

HERE = os.path.dirname(os.path.abspath(__file__))
DL_PORT = 8790
DOWNLOADS = os.path.expanduser("~/Downloads")
OREE = os.path.expanduser("~/HyperBrowser/Oree.app")

# ---- CPU time per process (libproc) ---------------------------------------
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
class _TB(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
_tb = _TB(); ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(_tb))
class _RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64)] + [("pad", ctypes.c_uint64 * 40)]
def cpu_seconds(pids):
    total = 0.0
    for p in pids:
        ru = _RU()
        if _libproc.proc_pid_rusage(p, 0, ctypes.byref(ru)) == 0:
            total += (ru.user + ru.system) * _tb.numer / _tb.denom / 1e9
    return total

# ---- download server with timing ------------------------------------------
dl_log = {}   # path -> {"starts": [...], "ends": [...]}
class LoggedH(R.H):
    def do_GET(self, head=False):
        if head: return super().do_GET(head=True)
        rec = dl_log.setdefault(self.path.split("?")[0], {"starts": [], "ends": [], "conns": 0})
        rec["starts"].append(time.time()); rec["conns"] += 1
        try: super().do_GET(head=False)
        finally: rec["ends"].append(time.time())

class QuietServer(ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address): pass   # browsers abort connections all the time

class NoCacheHandler(B.Handler):
    """Every page load really hits the server (an HTTP cache hit would hide the request and flatter the run)."""
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

# ---- browsers --------------------------------------------------------------
def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30).stdout.strip()

class Browser:
    name = ""
    def launch(self, urls): raise NotImplementedError
    def mine(self, before, ctx): raise NotImplementedError
    def quit(self, ctx, pids): B.kill(pids)
    def version(self): return ""

class Oree(Browser):
    name = "Orée"
    def launch(self, urls):
        subprocess.run(["open", "-n", "--env", "HB_FRESH_SESSION=1", "-a", OREE] + urls)
    def mine(self, before, ctx):
        return [p for p, _, c in B.procs() if p not in before and ("Oree.app" in c or B.WEBKIT_HELPER.search(c))]
    def quit(self, ctx, pids):
        osa('tell application "Oree" to quit'); time.sleep(2); B.kill([p for p in pids if _alive(p)])
    def version(self):
        return subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", f"{OREE}/Contents/Info.plist"], capture_output=True, text=True).stdout.strip()

class Safari(Browser):
    name = "Safari"
    def launch(self, urls): subprocess.run(["open", "-a", "Safari"] + urls)
    def mine(self, before, ctx):
        return [p for p, _, c in B.procs() if p not in before and ("Safari.app" in c or B.WEBKIT_HELPER.search(c))]
    def quit(self, ctx, pids):
        osa('tell application "Safari" to close every window'); osa('tell application "Safari" to quit')
        time.sleep(3); B.kill([p for p in pids if _alive(p)])
    def version(self): return osa('tell application "Safari" to get version')

class Brave(Browser):
    name = "Brave"
    def launch(self, urls):
        d = tempfile.mkdtemp(prefix="bench-brave-")
        subprocess.run(["open", "-n", "-a", "Brave Browser", "--args", f"--user-data-dir={d}", "--no-first-run",
                        "--no-default-browser-check", "--disable-sync"] + urls)
        return d
    def mine(self, before, ctx): return [p for p, _, c in B.procs() if f"--user-data-dir={ctx}" in c]
    def quit(self, ctx, pids): B.kill(pids); shutil.rmtree(ctx, ignore_errors=True)
    def version(self):
        return subprocess.run(["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", "--version"], capture_output=True, text=True).stdout.strip()

def _alive(p):
    try: os.kill(p, 0); return True
    except ProcessLookupError: return False

BROWSERS = {"oree": Oree(), "safari": Safari(), "brave": Brave()}

# ---- scenarios -------------------------------------------------------------
def page_urls(n):
    nonce = int(time.time() * 1000)   # a never-seen URL each run: no browser can answer from its cache
    return [u + f"&r={nonce}" for u in B.urls(n)]

def open_and_wait(b, n, timeout=150):
    # Some launches drop one of the URLs (seen with Brave); an incomplete run would flatter that browser's
    # memory, so such a run is thrown away and redone (up to 3 times).
    for attempt in range(3):
        with B.lock: B.events.clear()
        before = {p for p, _, _ in B.procs()}
        t0 = time.time()
        ctx = b.launch(page_urls(n))
        def done():
            with B.lock: return sum(1 for _, k, d in B.events if k == "beacon" and d.get("kind") == "done")
        ok = B.wait_for(lambda: done() >= n, 30 if attempt < 2 else timeout)
        if ok: break
        log(f"  (lancement incomplet: {done()}/{n} onglets chargés, on recommence)")
        b.quit(ctx, b.mine(before, ctx)); time.sleep(4)
    with B.lock:
        gets = [ts for ts, k, d in B.events if k == "get" and "bench.html" in d]
        done_ts = sorted(ts for ts, k, d in B.events if k == "beacon" and d.get("kind") == "done")
        beacons = [d for _, k, d in B.events if k == "beacon" and d.get("kind") == "done"]
    return {"ctx": ctx, "before": before, "ok": ok, "first_request_s": (min(gets) - t0) if gets else None,
            "first_done_s": (done_ts[0] - t0) if done_ts else None, "all_done_s": (done_ts[-1] - t0) if ok and done_ts else None,
            "beacons": beacons}

def scenario_launch(b, runs):
    out = []
    for i in range(runs + 1):                      # first run = warm-up, discarded
        r = open_and_wait(b, 1, 60)
        pids = b.mine(r["before"], r["ctx"]); time.sleep(1)
        b.quit(r["ctx"], pids); time.sleep(3)
        if i == 0: continue
        out.append({k: r[k] for k in ("ok", "first_request_s", "first_done_s")} | {"js": r["beacons"][0] if r["beacons"] else None})
        f = lambda v: "n/a" if v is None else f"{v:.2f}s"
        log(f"  launch {b.name} #{i}: requête {f(out[-1]['first_request_s'])}, page prête {f(out[-1]['first_done_s'])}" + ("" if out[-1]["ok"] else " (ÉCHEC)"))
    return out

def scenario_memory(b, tabs, runs, idle_long=False):
    out = []
    for i in range(runs):
        r = open_and_wait(b, tabs)
        time.sleep(20)
        pids = b.mine(r["before"], r["ctx"])
        mem = B.footprint_mb(pids)
        c0 = cpu_seconds(pids); time.sleep(30); c1 = cpu_seconds(pids)
        row = {"tabs": tabs, "ok": r["ok"], "all_done_s": r["all_done_s"], "mem_mb": mem, "procs": len(pids), "idle_cpu_pct": (c1 - c0) / 30 * 100}
        if idle_long:
            time.sleep(270)
            pids2 = b.mine(r["before"], r["ctx"])
            row["mem_after_5min_mb"] = B.footprint_mb(pids2); row["procs_after_5min"] = len(pids2)
        b.quit(r["ctx"], pids); time.sleep(4)
        out.append(row); log(f"  memory {b.name} {tabs} onglets #{i+1}: {json.dumps({k: (round(v, 1) if isinstance(v, float) else v) for k, v in row.items()})}")
    return out

def clean_downloads():
    for f in glob.glob(os.path.join(DOWNLOADS, "**", "oree-*mb*.bin"), recursive=True) + glob.glob(os.path.join(DOWNLOADS, "**", "oree-*mb*.bin.download"), recursive=True):
        try: os.remove(f)
        except OSError: pass

def scenario_download(b, kind, size_mb, runs):
    out = []
    path = f"/{kind}/{size_mb}.bin"
    for i in range(runs):
        clean_downloads(); dl_log.pop(path, None)
        before = {p for p, _, _ in B.procs()}
        ctx = b.launch([f"http://127.0.0.1:{DL_PORT}{path}"])
        rec = None; t_start = time.time(); t_full = None
        def finished():
            nonlocal rec, t_full
            rec = dl_log.get(path)
            if not rec or not rec["starts"]: return False
            full = any(os.path.getsize(f) >= size_mb * 1048576 for f in glob.glob(os.path.join(DOWNLOADS, "**", "oree-*mb*.bin"), recursive=True))
            if full and t_full is None: t_full = time.time()      # the file is complete on disk: what the user actually waits for
            return full and len(rec["ends"]) >= len(rec["starts"]) and time.time() - max(rec["ends"]) > 1.5
        ok = B.wait_for(lambda: (time.sleep(0.05), finished())[1], 420)
        dur = (t_full - min(rec["starts"])) if ok and t_full and rec and rec["starts"] else None
        row = {"kind": kind, "size_mb": size_mb, "ok": ok, "seconds": dur, "mb_per_s": (size_mb / dur) if ok and dur else None,
               "connections": rec["conns"] if rec else 0, "start_delay_s": (min(rec["starts"]) - t_start) if rec and rec["starts"] else None}
        pids = b.mine(before, ctx)
        b.quit(ctx, pids); time.sleep(4); clean_downloads()
        out.append(row); log(f"  download {b.name} {kind} {size_mb} Mo #{i+1}: {json.dumps({k: (round(v, 2) if isinstance(v, float) else v) for k, v in row.items()})}")
    return out

_logf = None
def log(msg):
    print(msg); sys.stdout.flush()

def main():
    args = sys.argv[1:]
    only = set((args[args.index("--only") + 1] if "--only" in args else "launch,memory,idle,download").split(","))
    names = (args[args.index("--browsers") + 1] if "--browsers" in args else "oree,safari,brave").split(",")
    quick = "--quick" in args
    srv = QuietServer(("127.0.0.1", B.PORT), NoCacheHandler); threading.Thread(target=srv.serve_forever, daemon=True).start()
    class QuietDL(R.S):
        def handle_error(self, request, client_address): pass
    dl = QuietDL(("127.0.0.1", DL_PORT), LoggedH); threading.Thread(target=dl.serve_forever, daemon=True).start()
    hw = {"cpu": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
          "ram_gb": int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30,
          "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(), "date": time.strftime("%Y-%m-%d %H:%M")}
    out_path = os.path.join(HERE, "compare-results.json")
    results = {"machine": hw, "browsers": {}}
    if "--merge" in args and os.path.exists(out_path): results = json.load(open(out_path))
    for n in names:
        b = BROWSERS[n]; log(f"== {b.name}")
        res = results["browsers"].setdefault(n, {"version": b.version()})
        if "launch" in only: res["launch"] = scenario_launch(b, 2 if quick else 5)
        if "memory" in only:
            res["memory"] = {str(t): scenario_memory(b, t, 1 if quick else 2) for t in ((1, 8) if quick else (1, 8, 20))}
        if "idle" in only: res["idle"] = scenario_memory(b, 20, 1, idle_long=True)
        if "download" in only:
            res["download"] = {"slow": scenario_download(b, "slow", 192, 1 if quick else 2), "big": scenario_download(b, "big", 256 if quick else 1024, 1)}
        json.dump(results, open(out_path, "w"), indent=1)
    log("terminé -> " + out_path)

if __name__ == "__main__":
    main()
