#!/usr/bin/env python3
"""Cost of Luciole's tasks, measured on a real provider (needs its key in the Keychain; debug build only).
One separate Orée instance (own database, nothing of the user's is read or written), scenarios asked one by one through the real panel,
numbers read from the usage meter (what the provider counted, not an estimate). Prints a table; --json FILE saves it for a before/after comparison.

  python3 scripts/bench/ai_cost.py [--provider groq] [--json out.json]
"""
import json, os, re, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI, APP = os.path.join(ROOT, "scripts", "ui.sh"), os.path.join(ROOT, "Oree.app", "Contents", "MacOS", "Oree")

SCENARIOS = [
    ("simple",  "https://example.com/", "Quelle est la capitale du Portugal ?"),
    ("page",    "https://en.wikipedia.org/wiki/Porto", "Quelle est la population de Porto d'après cette page ?"),
    ("resume",  "https://en.wikipedia.org/wiki/Porto", "Résume cette page en trois phrases."),
    ("web",     "https://example.com/", "Quel temps fait-il aujourd'hui à Lyon ?"),
    ("follow",  "https://example.com/", "Quelle est la capitale de l'Espagne ?"),
]

def ui(*args):
    r = subprocess.run([UI, *args], capture_output=True, text=True); return (r.stdout + r.stderr).strip()

def wait(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred(): return True
        time.sleep(0.5)
    return False

def main():
    provider = sys.argv[sys.argv.index("--provider") + 1] if "--provider" in sys.argv else "groq"
    out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    tmp = tempfile.mkdtemp(prefix="aicost-"); auto = os.path.join(tmp, "auto"); os.makedirs(auto); os.makedirs(os.path.join(tmp, "ext"))
    env = dict(os.environ, HB_FRESH_SESSION="1", HB_DB_PATH=os.path.join(tmp, "t.db"), HB_EXT_DIR=os.path.join(tmp, "ext"),
               HB_AUTOMATION_DIR=auto, HB_AI_PROVIDER=provider, HB_TAB_LAYOUT="vertical")
    proc = subprocess.Popen([APP, "--automation"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.environ["HB_AUTOMATION_DIR"] = auto
    results = []
    try:
        time.sleep(9)
        ui("tab", "aibar", "0"); time.sleep(1.5)
        for name, url, question in SCENARIOS:
            if name != "follow": ui("load", url); time.sleep(5)
            ui("tab", "aiusagereset", "0")
            open("/tmp/oree-ai-query.txt", "w").write(question); ui("tab", "aiquery", "0")
            time.sleep(1)
            ok = wait(lambda: "running=false" in ui("tab", "aistate", "0"), 150)
            if not ok: ui("tab", "aistop", "0"); wait(lambda: "running=false" in ui("tab", "aistate", "0"), 20)   # a scenario never leaks into the next
            report = ui("tab", "aistate", "0")
            usage = ui("tab", "aiusage", "0")
            m = re.search(r"answer=(.*)$", report); answer = (m.group(1) if m else "")[:160]
            nums = dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", usage))
            results.append({"scenario": name, "finished": ok, "answer": answer, **nums})
            print(f"{name:8} {'ok ' if ok else 'TIMEOUT'} {usage}\n         → {answer}")
    finally:
        proc.terminate()
    if out: json.dump(results, open(out, "w"), ensure_ascii=False, indent=1)
    tot = lambda k: sum(r.get(k, 0) for r in results)
    print(f"TOTAL requêtes={tot('requêtes')} jetons_entrée={tot('jetons_entrée')} jetons_sortie={tot('jetons_sortie')} contexte_car={tot('contexte_car')} "
          f"recherches={tot('recherches')} lectures={tot('lectures')} relances={tot('relances')} échecs={tot('échecs')}")

main()
