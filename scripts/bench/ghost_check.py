#!/usr/bin/env python3
"""Ghost fidelity check (docs/oree-hibernation.md, phase 1).

For each site: open it in a throwaway Orée instance, scroll a bit, freeze the page into a ghost, show the ghost
over it and compare the two snapshots pixel by pixel. Prints one line per site and writes ghost-report.json.

  python3 scripts/bench/ghost_check.py [url ...]      (no argument = the 10 default sites)

Only the instance this script starts is ever closed; an Orée you have open is left alone.
"""
import json, os, subprocess, sys, tempfile, time
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI = os.path.join(ROOT, "scripts", "ui.sh")
APP = os.path.join(ROOT, "Oree.app")
SITES = [
    ("presse (BBC)", "https://www.bbc.com/news"),
    ("Wikipédia", "https://fr.wikipedia.org/wiki/Lisbonne"),
    ("GitHub", "https://github.com/Gwada33/oree"),
    ("SPA React", "https://react.dev"),
    ("e-commerce (IKEA)", "https://www.ikea.com/fr/fr/"),
    ("doc technique (MDN)", "https://developer.mozilla.org/fr/docs/Web/CSS/grid"),
    ("Hacker News", "https://news.ycombinator.com"),
    ("Stack Overflow", "https://stackoverflow.com/questions/11227809"),
    ("Next.js (Vercel)", "https://vercel.com"),
    ("doc Tailwind", "https://tailwindcss.com/docs/installation"),
]

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def pids():
    out = subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split()
    return set(out)

def diff(a_path, b_path):
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size:
        b = b.resize(a.size)
    d = ImageChops.difference(a, b).convert("L")
    px = list(d.getdata())
    changed = sum(1 for v in px if v > 40)
    return 100.0 * changed / len(px), a.size

def main():
    sites = [(u, u) for u in sys.argv[1:]] or SITES
    before = pids()
    env = dict(os.environ)
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_GHOST=1", APP, "--args", "--automation"], env=env)
    time.sleep(5)
    mine = pids() - before
    tmp = tempfile.mkdtemp(prefix="ghostcheck-")
    rows = []
    try:
        for name, url in sites:
            ui("load", url); time.sleep(7)
            ui("eval", "window.scrollTo(0, 700); 1"); time.sleep(1.5)
            live, ghost = os.path.join(tmp, "live.png"), os.path.join(tmp, "ghost.png")
            ok, out = ui("ghost", live, ghost)
            row = {"site": name, "url": url, "ok": ok}
            if ok:
                try:
                    report = json.loads(out); row.update(report)
                    after = live.replace(".png", "-after.png")
                    d1, row["size"] = diff(live, ghost)
                    d2, _ = diff(after, ghost)
                    drift, _ = diff(live, after)          # how much the live page itself changed meanwhile
                    row["diff_pct"], row["live_drift_pct"] = min(d1, d2), drift
                except Exception as e:
                    row.update(ok=False, error=f"{e}")
            else:
                row["error"] = out[:120]
            rows.append(row)
            print(f'{name:<22} ' + (f'diff {row["diff_pct"]:5.1f}% (page bouge {row["live_drift_pct"]:4.1f}%)  html {row["rawKB"]:>5} KB -> {row["packedKB"]:>4} KB  capture {row["captureMs"]:>4} ms  ghost {row["ghostLoadMs"]:>4} ms  RAM real {row["realMB"]:>4} MB / ghost {row["ghostMB"]:>4} MB' if row["ok"] else f'ÉCHEC {row.get("error")}'), flush=True)
            Image.open(ghost).save(os.path.join(tmp, f"{len(rows):02d}-ghost.png")) if ok and os.path.exists(ghost) else None
            if ok: Image.open(live).save(os.path.join(tmp, f"{len(rows):02d}-live.png"))
            if ok and os.path.exists(live.replace(".png", "-after.png")): Image.open(live.replace(".png", "-after.png")).save(os.path.join(tmp, f"{len(rows):02d}-live-after.png"))
    finally:
        for p in mine: subprocess.run(["kill", p])
    json.dump(rows, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghost-report.json"), "w"), indent=1, ensure_ascii=False)
    print("captures :", tmp)

if __name__ == "__main__":
    main()
