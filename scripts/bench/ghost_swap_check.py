#!/usr/bin/env python3
"""Ghost hand-over check (docs/oree-hibernation.md, phase 2).

For each site: open it, scroll, put the tab to sleep, come back, and look at the moment of the swap:
  - `jump`: % of pixels that differ between what the ghost shows and what the real page shows right before the swap
    (0 = nothing moves on screen);
  - the hand-over log line (text / position match of the visible blocks, scroll correction, time).

  python3 scripts/bench/ghost_swap_check.py [url ...]      (no argument = the 10 default sites)
Only the Orée instance this script starts is closed.
"""
import json, os, re, subprocess, sys, tempfile, time
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ghost_check import SITES   # same ten sites as the fidelity check

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

def pids():
    return set(subprocess.run(["pgrep", "-x", "Oree"], capture_output=True, text=True).stdout.split())

def jump(a_path, b_path):
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size: b = b.resize(a.size)
    px = list(ImageChops.difference(a, b).convert("L").getdata())
    return 100.0 * sum(1 for v in px if v > 40) / len(px)

def hand_over_lines():
    out = subprocess.run(["/usr/bin/log", "show", "--last", "40s", "--predicate", 'process == "Oree" AND category == "tabs"', "--info"],
                         capture_output=True, text=True).stdout
    return [re.sub(r"^.*tabs\] ", "", l) for l in out.splitlines() if "Ghost: swap" in l or "Ghost: visible" in l or "Wake: live" in l][-3:]

def main():
    timing = "--timing" in sys.argv      # no snapshots at the swap: measures the real hand-over time
    args = [a for a in sys.argv[1:] if a != "--timing"]
    sites = [(u, u) for u in args] or SITES
    tmp = tempfile.mkdtemp(prefix="ghostswap-")
    before = pids()
    subprocess.run(["open", "-g", "-n", "--env", "HB_FRESH_SESSION=1", "--env", "HB_GHOST=1", *([] if timing else ["--env", f"HB_GHOST_SWAP_DUMP={tmp}"]), APP, "--args", "--automation"])
    time.sleep(5)
    mine = pids() - before
    rows = []
    try:
        for name, url in sites:
            for f in ("swap-ghost.png", "swap-real.png"):
                try: os.remove(os.path.join(tmp, f))
                except FileNotFoundError: pass
            ui("load", url); time.sleep(7)
            ui("eval", "window.scrollTo(0, 700); 1"); time.sleep(1.5)
            ui("action", "newTabAction"); time.sleep(1); ui("key", "escape")
            ui("tab", "sleep", "0"); time.sleep(4)
            ui("tab", "select", "0"); time.sleep(9)
            g, r = os.path.join(tmp, "swap-ghost.png"), os.path.join(tmp, "swap-real.png")
            row = {"site": name}
            if os.path.exists(g) and os.path.exists(r):
                row["jump_pct"] = jump(g, r)
            lines = hand_over_lines()
            row["log"] = lines
            rows.append(row)
            j = f'jump {row["jump_pct"]:5.1f}%' if "jump_pct" in row else "jump  n/a  (le fantôme n'était pas prêt)"
            print(f"{name:<22} {j}   {' | '.join(lines[-2:]) if lines else '(pas de journal)'}", flush=True)
    finally:
        for p in mine: subprocess.run(["kill", p])
    json.dump(rows, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghost-swap-report.json"), "w"), indent=1, ensure_ascii=False)

if __name__ == "__main__":
    main()
