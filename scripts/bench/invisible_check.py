#!/usr/bin/env python3
"""Invisibility check for tab hibernation (docs/oree-hibernation.md, phase 4): measures, every 8 ms, what a user could notice
while a sleeping tab comes back — not a screenshot.

For each site: open, scroll, open another tab, put the first to sleep, start the in-app recorder (`tab invisstart`), come back to the
first tab, stop it (`tab invisstop`). Per site it reports:
  - swap_ms   time from the click until only the real page is on screen
  - bar_ms    time the loading bar was visible          (must be 0)
  - spin_ms   time the tab showed its loading ring       (must be 0)
  - stop_ms   time the reload button was a stop button   (must be 0)
  - blank     samples where nothing covered the page     (must be 0)
  - fade_ms   time a half-transparent snapshot was shown (a dissolve is a tell: must be 0)
After the swap (the page is then "there" and must stay still), over the next seconds:
  - reloads   navigations that start after the swap (a real reload: must be 0)
  - jump_pt   largest scroll movement after the swap, in points (must be ~0)
  - shifts    times what the page shows changed after the swap (re-render, hydration: must be 0)
Results are appended to scripts/bench/invisible-report.json and compared with the previous run.

  python3 scripts/bench/invisible_check.py [--ghost 0|1] [url ...]
Only the Orée instance this script starts is closed; it runs on a throw-away database.
"""
import json, os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
REPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "invisible-report.json")
SITES = ["https://fr.wikipedia.org/wiki/Lisbonne", "https://www.bbc.com/news", "https://github.com/torvalds/linux",
         "https://react.dev", "https://developer.mozilla.org/fr/docs/Web/CSS"]

def ui(*a):
    r = subprocess.run([UI, *a], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def pids():
    return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def analyse(samples):
    """samples: [{t, stack, bar, spin, stop}] from the moment the tab is selected. Pure, see the self-check below."""
    dt = 8
    pages = [s for s in samples if "page" in s]
    navs = [s for s in samples if "nav" in s]
    samples = [s for s in samples if "stack" in s]
    def ms(pred): return sum(dt for s in samples if pred(s))
    real_only = lambda s: s["stack"].startswith("W1.00") and "+" not in s["stack"] and "G" not in s["stack"]
    swap = next((s["t"] for s in samples if real_only(s) and s["t"] > 0), None)
    # first sample with the tab on screen counts as the start
    after = [p for p in pages if swap is not None and p["t"] >= swap]
    ys = [int(p["page"].split("|")[0]) for p in after]
    hashes = [p["page"].split("|")[2] for p in after]
    return {
        "reloads": sum(1 for n in navs if n["nav"] == "start" and swap is not None and n["t"] > swap),
        "jump_pt": (max(ys) - min(ys)) if ys else None,
        "shifts": sum(1 for a, b in zip(hashes, hashes[1:]) if a != b),
        "swap_ms": swap, "bar_ms": ms(lambda s: s["bar"] > 0.02), "spin_ms": ms(lambda s: s["spin"]), "stop_ms": ms(lambda s: s["stop"]),
        "blank": sum(1 for s in samples if s["stack"] in ("", "-") ),
        "fade_ms": ms(lambda s: any(p.startswith("S") and p not in ("S1.00",) for p in s["stack"].split("+"))),
    }

def selfcheck():
    ok = [{"t": 0, "stack": "G+W1.00", "bar": 0, "spin": False, "stop": False}, {"t": 8, "stack": "G+W1.00", "bar": 0, "spin": False, "stop": False},
          {"t": 16, "stack": "W1.00", "bar": 0, "spin": False, "stop": False}]
    ok += [{"t": 20, "tab": "x", "page": "700|complete|11"}, {"t": 120, "tab": "x", "page": "700|complete|11"}]
    r = analyse(ok); assert r["jump_pt"] == 0 and r["shifts"] == 0 and r["reloads"] == 0, r
    r = analyse(ok[:3] + [{"t": 30, "tab": "x", "nav": "start"}, {"t": 40, "tab": "x", "page": "0|loading|1"}, {"t": 150, "tab": "x", "page": "700|complete|2"}])
    assert r["reloads"] == 1 and r["jump_pt"] == 700 and r["shifts"] == 1, r
    r = analyse(ok); assert r["swap_ms"] == 16 and r["bar_ms"] == r["spin_ms"] == r["blank"] == r["fade_ms"] == 0, r
    bad = [{"t": 0, "stack": "S0.50+W1.00", "bar": 0.8, "spin": True, "stop": True}, {"t": 8, "stack": "", "bar": 0, "spin": False, "stop": False}]
    r = analyse(bad); assert r["bar_ms"] == 8 and r["spin_ms"] == 8 and r["stop_ms"] == 8 and r["blank"] == 1 and r["fade_ms"] == 8, r

def main():
    selfcheck()
    args = sys.argv[1:]
    ghost = "1"
    if "--ghost" in args:
        i = args.index("--ghost"); ghost = args[i + 1]; del args[i:i + 2]
    sites = args or SITES
    tmp = tempfile.mkdtemp(prefix="invis-"); os.makedirs(os.path.join(tmp, "ext"))
    before = pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", *(["--env", "HB_GHOST=1"] if ghost == "1" else []), "--env", "HB_AI_NO_AGENT=1",
                    "--env", f"HB_DB_PATH={tmp}/db.sqlite", "--env", f"HB_EXT_DIR={tmp}/ext", APP, "--args", "--automation"])
    time.sleep(6)
    mine = pids() - before
    rows = []
    try:
        for url in sites:
            ui("load", url); time.sleep(8)
            ui("eval", "window.scrollTo(0, 700); 1"); time.sleep(1.5)
            ui("key", "cmd+t"); time.sleep(1); ui("key", "escape")
            ui("tab", "sleep", "0"); time.sleep(4)
            ui("tab", "invisstart", "0"); time.sleep(0.3)
            ui("tab", "select", "0"); time.sleep(8)
            ui("tab", "invisstop", "0")
            try: samples = json.load(open("/tmp/oree-invis.json"))
            except Exception: samples = []
            # only the tab that is being woken, from the moment it is selected
            if samples:
                woken = [x for x in samples if "stack" in x][-1]["tab"]; samples = [s for s in samples if s["tab"] == woken]
                t0 = samples[0]["t"]
                for s in samples: s["t"] -= t0
            row = {"site": url, **(analyse(samples) if samples else {"error": "no samples"})}
            rows.append(row); print(json.dumps(row, ensure_ascii=False))
            ui("key", "cmd+w"); time.sleep(0.5)
    finally:
        for p in mine: subprocess.run(["kill", p])
    history = json.load(open(REPORT)) if os.path.exists(REPORT) else []
    if history:
        prev = {r["site"]: r for r in history[-1]["rows"]}
        for r in rows:
            p = prev.get(r["site"])
            if p and r.get("swap_ms") is not None and p.get("swap_ms") is not None:
                print(f"  {r['site']}: swap {p['swap_ms']} -> {r['swap_ms']} ms")
    history.append({"date": time.strftime("%Y-%m-%d %H:%M"), "ghost": ghost, "rows": rows})
    json.dump(history[-20:], open(REPORT, "w"), indent=1, ensure_ascii=False)
    bad = [r for r in rows if r.get("error") or r.get("swap_ms") is None or any(r.get(k) for k in ("bar_ms", "spin_ms", "stop_ms", "blank", "fade_ms", "reloads", "shifts")) or (r.get("jump_pt") or 0) > 2]
    print(f"\n{len(rows) - len(bad)}/{len(rows)} sites invisible (no bar, spinner, stop button, blank frame, dissolve, reload, scroll jump or re-render after the swap).")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
