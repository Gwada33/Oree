#!/usr/bin/env python3
"""Memory + throughput of the download engine with N simultaneous big downloads.
Needs: the app running with --automation, and scripts/bench/range_server.py on 8790.
  dl_ram_bench.py [big|norange] [count=5] [mib=1024]
'big' goes through the engine (separate process); 'norange' forces the old WKDownload path (baseline)."""
import os, re, subprocess, sys, time, glob

HB = os.path.expanduser("~/HyperBrowser"); UI = f"{HB}/scripts/ui.sh"
kind = sys.argv[1] if len(sys.argv) > 1 else "big"
count = int(sys.argv[2]) if len(sys.argv) > 2 else 5
mib = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
downloads = os.path.expanduser("~/Downloads")

def run(*a): return subprocess.run(a, capture_output=True, text=True).stdout
def pid(name):
    out = run("pgrep", "-x", name).split()
    return int(out[0]) if out else None
def footprint_mb(p):
    if not p: return None
    out = run("footprint", "-p", str(p))
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB)", out)
    if not m: return None
    v = float(m.group(1)); return v / 1024 if m.group(2) == "KB" else v * 1024 if m.group(2) == "GB" else v

def files(): return glob.glob(f"{downloads}/oree-{kind}-{mib}mb*.bin") + glob.glob(f"{downloads}/.oree-{kind}-{mib}mb*.oreedl")
def written():  # real bytes on disk (sparse files only count what has landed)
    return sum(os.stat(f).st_blocks * 512 for f in files() if os.path.exists(f))

for f in files(): os.remove(f)
app = pid("HyperBrowser"); agent = pid("OreeDownloader")
if not app: sys.exit("l'app ne tourne pas")
base_app, base_agent = footprint_mb(app), footprint_mb(agent)
print(f"avant : app {base_app:.0f} Mo · moteur {base_agent if base_agent else 0:.0f} Mo")

start = time.time()
for i in range(count):
    run(UI, "load", f"http://127.0.0.1:8790/{kind}/{mib}.bin"); time.sleep(0.4)
agent = pid("OreeDownloader")
peak_app, peak_agent, total = base_app or 0, base_agent or 0, count * mib * 1024 * 1024
last = 0
while time.time() - start < 600:
    time.sleep(0.5)
    a, g = footprint_mb(app), footprint_mb(agent or pid("OreeDownloader"))
    peak_app = max(peak_app, a or 0); peak_agent = max(peak_agent, g or 0)
    done = written()
    if done >= total and not glob.glob(f"{downloads}/.oree-{kind}-{mib}mb*.oreedl"): break
elapsed = time.time() - start
print(f"{count} × {mib} Mo ({kind}) en {elapsed:.1f} s → {total / 1e6 / elapsed:.0f} Mo/s au total")
print(f"pic mémoire (footprint) : app {peak_app:.0f} Mo (+{peak_app - (base_app or 0):.0f}) · moteur {peak_agent:.0f} Mo")
for f in files(): os.remove(f)
