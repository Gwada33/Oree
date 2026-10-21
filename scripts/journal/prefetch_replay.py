#!/usr/bin/env python3
"""Banc de rejeu du préchargement des liens : une règle simple (« précharger si le pointeur reste ≥ T ms ») contre un petit modèle appris sur le journal.

  python3 scripts/journal/prefetch_replay.py journal-oree-AAAA-MM-JJ.jsonl

Ce que l'on compare est ce qui compte en vrai : pour la MÊME couverture des clics (part des clics dont la page était déjà préchargée), combien de préchargements inutiles chaque méthode coûte.
Le test se fait sur les derniers 30 % du temps, que le modèle n'a jamais vus. À T ms de survol on ne connaît PAS la durée finale du survol : le modèle n'utilise que ce qui existe à cet instant
(genre et place du lien, même site ou externe, site, forme de la page, vitesse récente du pointeur), jamais « dwell » ni « clicked ».
Dépendance : numpy seulement. Rien n'est envoyé nulle part ; le journal ne contient ni adresse, ni titre, ni texte.
"""
import collections, json, sys
import numpy as np

KINDS = ["nav", "content", "button", "other"]

def load(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    return [json.loads(l) for l in lines[1:] if l.strip()]

def build(events):
    """Un exemple par survol de lien, avec le contexte connu au moment du survol."""
    shape, speed = {}, {}
    rows = []
    for e in sorted(events, key=lambda e: e["t"]):
        d, kind = e.get("d", {}), e["e"]
        tab = d.get("tab")
        if kind == "page.shape": shape[tab] = d
        elif kind == "ptr.window": speed[tab] = d
        elif kind == "link.hover" and "dwell" in d:
            sh, sp = shape.get(tab, {}), speed.get(tab, {})
            rows.append(dict(
                t=e["t"], dwell=d["dwell"], clicked=bool(d.get("clicked")), site=d.get("site", ""),
                kind=KINDS.index(d["kind"]) if d.get("kind") in KINDS else 3, external=float(bool(d.get("external"))), same=float(bool(d.get("same"))),
                gx=d.get("gx", 0), gy=d.get("gy", 0), y=d.get("y", 0),
                links=sh.get("links", 0), tlen=sh.get("tlen", 0), article=float(bool(sh.get("article"))), form=float(sh.get("kind") == "form"),
                vmean=sp.get("vmean", 0), pauses=sp.get("pauses", 0)))
    return rows

def features(rows, site_rate, prior):
    X = []
    for r in rows:
        onehot = [1.0 if r["kind"] == k else 0.0 for k in range(len(KINDS))]
        X.append(onehot + [r["external"], r["same"], r["gx"], r["gy"], np.log1p(r["y"]), np.log1p(r["links"]), np.log1p(r["tlen"]), r["article"], r["form"],
                           np.log1p(r["vmean"]), np.log1p(r["pauses"]), site_rate.get(r["site"], prior), 1.0 if r["site"] in site_rate else 0.0])
    return np.array(X, dtype=float)

def fit_logistic(X, y, steps=400, lr=0.1, l2=1e-2):
    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = (X - mu) / sd
    w, b = np.zeros(Z.shape[1]), 0.0
    for _ in range(steps):
        p = 1 / (1 + np.exp(-(Z @ w + b)))
        g = p - y
        w -= lr * (Z.T @ g / len(y) + l2 * w); b -= lr * g.mean()
    return lambda A: 1 / (1 + np.exp(-(((A - mu) / sd) @ w + b)))

def evaluate(rows, T, scores, total_clicks):
    """Parmi les survols d'au moins T ms : la règle précharge tous ; le modèle ne précharge que ceux qu'il note assez haut pour atteindre la MÊME couverture que la règle."""
    cand = [i for i, r in enumerate(rows) if r["dwell"] >= T]
    rule_hits = sum(rows[i]["clicked"] for i in cand)
    order = sorted(cand, key=lambda i: -scores[i])
    got, used = 0, 0
    for i in order:
        if got >= rule_hits: break
        used += 1; got += rows[i]["clicked"]
    return dict(T=T, rule_prefetch=len(cand), rule_hits=rule_hits, model_prefetch=used, coverage=rule_hits / max(total_clicks, 1))

def main(path):
    rows = build(load(path))
    rows.sort(key=lambda r: r["t"])
    cut = int(len(rows) * 0.7)
    train, test = rows[:cut], rows[cut:]
    pos_train, pos_test = sum(r["clicked"] for r in train), sum(r["clicked"] for r in test)
    print(f"{len(rows)} survols : {len(train)} pour apprendre ({pos_train} cliqués), {len(test)} pour tester ({pos_test} cliqués, jamais vus par le modèle)")
    prior = pos_train / max(len(train), 1)
    seen = collections.defaultdict(lambda: [0, 0])
    for r in train: seen[r["site"]][0] += r["clicked"]; seen[r["site"]][1] += 1
    site_rate = {s: (c + prior * 5) / (n + 5) for s, (c, n) in seen.items()}          # taux de clic du site, lissé
    Xtr, ytr = features(train, site_rate, prior), np.array([r["clicked"] for r in train], float)
    Xte = features(test, site_rate, prior)
    model = fit_logistic(Xtr, ytr)
    scores = model(Xte)
    # Qualité brute du classement (aire sous la courbe ROC) : 0,5 = hasard
    pos, neg = scores[[r["clicked"] for r in test]], scores[[not r["clicked"] for r in test]]
    auc = float(np.mean([(p > n) + 0.5 * (p == n) for p in pos[:400] for n in neg[:400]])) if len(pos) and len(neg) else float("nan")
    print(f"classement (AUC, hasard = 0,50) : {auc:.3f}")
    total_clicks = pos_test
    print("\nPour la même couverture des clics que la règle, combien de préchargements ?")
    print("  T (ms) | règle | modèle | économie | couverture des clics")
    for T in (100, 150, 200, 300):
        res = evaluate(test, T, scores, total_clicks)
        saved = 1 - res["model_prefetch"] / max(res["rule_prefetch"], 1)
        print(f"  {T:>6} | {res['rule_prefetch']:>5} | {res['model_prefetch']:>6} | {saved:>7.0%} | {res['coverage']:.0%}")
    # À budget égal : la règle règle son budget avec T (plus T est grand, moins elle précharge) ; le modèle choisit les N survols les mieux notés parmi ceux d'au moins 100 ms.
    print("\nÀ budget égal (même nombre de préchargements), quelle part des clics est couverte ?")
    print("  T de la règle | préchargements | clics couverts (règle) | clics couverts (modèle)")
    base = [i for i, r in enumerate(test) if r["dwell"] >= 100]
    ranked = sorted(base, key=lambda i: -scores[i])
    for T in (150, 200, 300, 400, 500, 700):
        budget = sum(1 for r in test if r["dwell"] >= T)
        rule_cov = sum(r["clicked"] for r in test if r["dwell"] >= T) / max(total_clicks, 1)
        model_cov = sum(test[i]["clicked"] for i in ranked[:budget]) / max(total_clicks, 1)
        print(f"  {T:>13} | {budget:>14} | {rule_cov:>22.0%} | {model_cov:>23.0%}")
    print("\nLecture : « économie » = préchargements en moins pour attraper autant de clics. Moins de 10 % ou un AUC proche de 0,5 : la règle simple suffit encore.")

if __name__ == "__main__":
    main(sys.argv[1])
