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
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.environ.get("OREE_TEST_APP") or os.path.join(ROOT, "Oree.app")
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
    # L'instance d'essai est lancée directement (pas par « open ») pour recevoir ses variables : sans HB_TEST_KEYS_DIR elle toucherait au Trousseau de la personne et resterait figée sur sa fenêtre d'autorisation.
    base = tempfile.mkdtemp(prefix="ghostrun-"); auto = os.path.join(base, "auto"); os.makedirs(auto); os.makedirs(os.path.join(base, "ext"))
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_GHOST="1", HB_WAKE_REPORT="1", HB_AUTOMATION_DIR=auto, HB_DB_PATH=os.path.join(base, "t.db"), HB_EXT_DIR=os.path.join(base, "ext"),
               HB_TEST_KEYS_DIR=os.path.join(base, "keys"), HB_AI_NO_AGENT="1", HB_AI_PROVIDER="groq")
    if not timing: env["HB_GHOST_SWAP_DUMP"] = tmp
    os.environ["HB_AUTOMATION_DIR"] = auto
    proc = subprocess.Popen([os.path.join(APP, "Contents/MacOS/Oree"), "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(9)
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
            try: os.remove("/tmp/oree-wake.txt")
            except FileNotFoundError: pass
            ui("tab", "select", "0")
            waited = 0.0
            while waited < 20 and not os.path.exists("/tmp/oree-wake.txt"): time.sleep(0.25); waited += 0.25
            time.sleep(1)
            g, r = os.path.join(tmp, "swap-ghost.png"), os.path.join(tmp, "swap-real.png")
            row = {"site": name}
            if os.path.exists(g) and os.path.exists(r):
                row["jump_pct"] = jump(g, r)
            wake = open("/tmp/oree-wake.txt").read() if os.path.exists("/tmp/oree-wake.txt") else "pas de réveil mesuré en 20 s"
            lines = [wake]
            row["log"] = lines
            rows.append(row)
            j = f'jump {row["jump_pct"]:5.1f}%' if "jump_pct" in row else "jump  n/a  (le fantôme n'était pas prêt)"
            print(f"{name:<22} {j}   {' | '.join(lines[-2:]) if lines else '(pas de journal)'}", flush=True)
    finally:
        proc.terminate(); time.sleep(1)
        if proc.poll() is None: proc.kill()
    json.dump(rows, open(os.environ.get("GHOST_REPORT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghost-swap-report.json"), "w"), indent=1, ensure_ascii=False)

if __name__ == "__main__":
    main()
