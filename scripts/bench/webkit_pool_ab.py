#!/usr/bin/env python3
"""A/B des réglages privés de WebKit (pool de processus, préférences) sur de vrais sites : temps de chargement (1re visite, puis revisite) et mémoire en fin de parcours.

  OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/webkit_pool_ab.py [runs] [config ...]
Les configs sont posées par HB_WK_POOL / HB_WK_PREFS / HB_WK_FEATURES, en plus des réglages par défaut d'Orée. Le réseau fait varier les temps : comparer des médianes de plusieurs passages.
"""
import json, os, re, statistics, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(__file__)); import bench

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh"); APP = os.environ["OREE_TEST_APP"]
SITES = ["https://en.wikipedia.org/wiki/WebKit", "https://news.ycombinator.com", "https://github.com/apple/swift", "https://developer.mozilla.org/en-US/", "https://www.bbc.com/news", "https://stackoverflow.com/questions"]
CONFIGS = {
    "base": {},
    "dns": {"HB_WK_PREFS": "_dnsPrefetchingEnabled=1"},
    "cache-processus": {"HB_WK_POOL": "usesWebProcessCache=1"},
    "garde-echanges": {"HB_WK_POOL": "alwaysKeepAndReuseSwappedProcesses=1"},
    "validation-disque": {"HB_WK_POOL": "diskCacheSpeculativeValidationEnabled=1"},
    "suspend-memoire": {"HB_WK_POOL": "suspendsWebProcessesAggressivelyOnMemoryPressure=1"},
}
ui = lambda *a: subprocess.run([UI, *a], capture_output=True, text=True).stdout.strip()

def one(env):
    tmp = tempfile.mkdtemp(prefix="wkab-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext"))
    os.environ["HB_AUTOMATION_DIR"] = auto
    full = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"), HB_AUTOMATION_DIR=auto, HB_AI_NO_AGENT="1", HB_TEST_KEYS_DIR=os.path.join(tmp, "keys"), **env)
    before = {p for p, _, _ in bench.procs()}
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=full, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(9)
        def visit(u):
            ui("load", u); end = time.time() + 25
            while time.time() < end:
                time.sleep(0.5)
                r = ui("eval", "document.readyState==='complete' ? Math.round(performance.getEntriesByType('navigation')[0].loadEventEnd) : -1")
                if r.lstrip("-").isdigit() and int(r) > 0: return int(r)
            return 25000
        first = [visit(u) for u in SITES]
        warm = [visit(u) for u in SITES]
        pids = [q for q, _, c in bench.procs() if q not in before and ("Oree" in c or bench.WEBKIT_HELPER.search(c))]
        return sum(first), sum(warm), bench.footprint_mb(pids)
    finally:
        p.terminate(); time.sleep(3)
        for q, _, c in bench.procs():
            if "WebKit" in c and q not in before: pass

if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 2; only = sys.argv[2:]
    for name, env in CONFIGS.items():
        if only and name not in only: continue
        res = [one(env) for _ in range(runs)]
        print(json.dumps({"config": name, "premiere_visite_ms": [r[0] for r in res], "revisite_ms": [r[1] for r in res], "memoire_mo": [round(r[2]) for r in res]}), flush=True)
