#!/usr/bin/env python3
"""Lit un journal exporté d'Orée (Réglages › Confidentialité › Journal d'événements › Exporter…) et en tire des chiffres pour régler la vitesse.

  python3 scripts/journal/analyze.py journal-oree-2026-10-16.jsonl

Rien n'est envoyé nulle part. Le fichier contient des empreintes de sites, des durées, des nombres : pas d'adresse, de titre ni de texte.
"""
import collections, json, statistics, sys

def load(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    header = json.loads(lines[0])
    return header, [json.loads(l) for l in lines[1:] if l.strip()]

def pct(values, p):
    if not values: return 0
    values = sorted(values); return values[min(len(values) - 1, int(len(values) * p))]

def line(title): print("\n" + title + "\n" + "-" * len(title))

def main(path):
    header, events = load(path)
    if not events: print("Journal vide."); return
    by = collections.defaultdict(list)
    for e in events: by[e["e"]].append(e)
    span = (events[-1]["t"] - events[0]["t"]) / 3600
    print(f"{len(events)} événements sur {span:.1f} h, format {header.get('format')} v{header.get('schema')}")
    line("Événements par type")
    for name, items in sorted(by.items(), key=lambda kv: -len(kv[1])): print(f"  {name:16} {len(items)}")

    line("Préchargement des liens : survol → clic")
    hovers = by.get("link.hover", [])
    if hovers:
        clicked = [h for h in hovers if h["d"].get("clicked")]
        print(f"  {len(hovers)} survols, {len(clicked)} suivis d'un clic ({100 * len(clicked) / len(hovers):.1f} %)")
        print("  Règle « précharger si le pointeur reste ≥ T ms sur un lien » :")
        print("     T (ms)   préchargements   utiles   précision   clics couverts")
        for t in (100, 150, 200, 250, 300, 400, 500, 700):
            fired = [h for h in hovers if h["d"].get("dwell", 0) >= t]
            useful = [h for h in fired if h["d"].get("clicked")]
            print(f"     {t:5}   {len(fired):14}   {len(useful):6}   {100 * len(useful) / max(1, len(fired)):8.1f} %   {100 * len(useful) / max(1, len(clicked)):10.1f} %")
        for label, key in (("même site", True), ("autre site", False)):
            group = [h for h in hovers if bool(h["d"].get("same")) == key]
            if group: print(f"  {label} : {len(group)} survols, {100 * sum(1 for h in group if h['d'].get('clicked')) / len(group):.1f} % cliqués")
        kinds = collections.defaultdict(lambda: [0, 0])
        for h in hovers: kinds[h["d"].get("kind", "other")][0] += 1; kinds[h["d"].get("kind", "other")][1] += 1 if h["d"].get("clicked") else 0
        for kind, (n, c) in sorted(kinds.items()): print(f"  liens « {kind} » : {n} survols, {100 * c / n:.1f} % cliqués")
        dw = [h["d"]["dwell"] for h in clicked if "dwell" in h["d"]]
        if dw: print(f"  durée du survol avant un clic : médiane {pct(dw, .5)} ms, 25 % ≤ {pct(dw, .25)} ms, 75 % ≤ {pct(dw, .75)} ms")
    else: print("  aucun survol de lien enregistré")

    line("Navigation et chargement")
    done = by.get("nav.done", [])
    if done:
        ok = [d["d"]["ms"] for d in done if d["d"].get("ok")]
        print(f"  {len(done)} navigations, {len(ok)} réussies ; durée : médiane {pct(ok, .5)} ms, p90 {pct(ok, .9)} ms")
        kinds = collections.defaultdict(list)
        starts = {e["d"]["tab"]: e for e in by.get("nav.start", [])}
        for d in done:
            kinds[d["d"].get("kind", "?")].append(d["d"]["ms"])
        commit = [c["d"]["ms"] for c in by.get("nav.commit", [])]
        if commit: print(f"  jusqu'à la première réponse : médiane {pct(commit, .5)} ms, p90 {pct(commit, .9)} ms")
    for key in ("ttfb", "dcl", "load", "lcp"):
        values = [p["d"][key] for p in by.get("page.perf", []) if p["d"].get(key)]
        if values: print(f"  {key:5}: médiane {pct(values, .5)} ms, p90 {pct(values, .9)} ms ({len(values)} pages)")

    line("Onglets")
    selects = by.get("tab.select", [])
    if selects:
        asleep = [s for s in selects if s["d"].get("asleep")]
        print(f"  {len(selects)} changements d'onglet dont {len(asleep)} sur un onglet en veille ({100 * len(asleep) / len(selects):.1f} %)")
        vias = collections.Counter(s["d"].get("via", "?") for s in selects); print("  comment : " + ", ".join(f"{k} {v}" for k, v in vias.most_common()))
        gaps = [s["d"]["gap"] for s in selects if "gap" in s["d"]]
        if gaps: print(f"  temps depuis la dernière fois en avant : médiane {pct(gaps, .5)} s, p90 {pct(gaps, .9)} s")
    wakes = by.get("tab.wake", [])
    if wakes:
        ms = [w["d"]["ms"] for w in wakes]
        print(f"  {len(wakes)} réveils : médiane {pct(ms, .5)} ms, p90 {pct(ms, .9)} ms ; déclencheur " + ", ".join(f"{k} {v}" for k, v in collections.Counter(w['d'].get('trigger') for w in wakes).items()))
        pre = [w for w in wakes if w["d"].get("trigger") == "hover"]
        if pre: print(f"  réveils au survol : {len(pre)} (le clic a trouvé l'onglet prêt)")
    hov = by.get("tab.hover", [])
    if hov: print(f"  survols d'onglets : {len(hov)}, {sum(1 for h in hov if h['d'].get('clicked'))} suivis d'un clic, aperçu montré {sum(1 for h in hov if h['d'].get('preview'))} fois")
    closes = by.get("tab.close", [])
    if closes:
        life = [c["d"]["life"] for c in closes]; fg = [c["d"]["fg"] for c in closes]
        print(f"  {len(closes)} onglets fermés : vie médiane {pct(life, .5)} s, temps au premier plan médian {pct(fg, .5)} s")

    line("Barre d'adresse")
    inputs = by.get("addr.input", [])
    if inputs:
        commits = by.get("addr.commit", [])
        print(f"  {len(inputs)} saisies, {len(commits)} validées ; {statistics.mean(i['d']['keys'] for i in inputs):.1f} touches en moyenne")
        sug = by.get("addr.suggest", [])
        picked = [s for s in sug if s["d"].get("pick", -1) >= 0]
        if sug: print(f"  une suggestion choisie dans {100 * len(picked) / len(sug):.1f} % des cas ; rang médian {pct([s['d']['pick'] for s in picked], .5) if picked else '-'}")

    line("Mémoire")
    mem = by.get("perf.mem", [])
    if mem:
        print(f"  onglets ouverts : médiane {pct([m['d']['tabs'] for m in mem], .5)}, max {max(m['d']['tabs'] for m in mem)} ; mémoire des pages : médiane {pct([m['d']['mb'] for m in mem], .5)} Mo, max {max(m['d']['mb'] for m in mem)} Mo")

    line("Luciole")
    ai = by.get("ai.task", [])
    if ai:
        for route in ("direct", "page", "web", "agent"):
            group = [a for a in ai if a["d"].get("route") == route]
            if group: print(f"  {route:6}: {len(group)} tâches, {statistics.mean(a['d']['req'] for a in group):.1f} requêtes, {statistics.mean(a['d']['tin'] for a in group):.0f} jetons d'entrée en moyenne, {100 * sum(1 for a in group if a['d'].get('ok')) / len(group):.0f} % réussies")
    else: print("  aucune tâche")

if __name__ == "__main__":
    if len(sys.argv) != 2: print(__doc__); sys.exit(2)
    main(sys.argv[1])
