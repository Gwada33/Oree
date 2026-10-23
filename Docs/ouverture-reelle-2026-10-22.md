# Ouverture mesurée avec un vrai site (22 octobre 2026)

`scripts/bench/launch_real.py` : temps entre `open` et la première fenêtre visible (position publique, aucune autorisation), en ouvrant `https://fr.wikipedia.org/…` ; aucun serveur local. Tour à tour, 10 passages par navigateur + 1 d'échauffement jeté. Mac M1 8 Go, macOS 27.0.

| Navigateur | Version | Médiane | Min – max |
|---|---|---|---|
| **Orée** | 1.1.0 | **0,70 s** | 0,65 – 0,96 |
| Brave | 155.1.97.59 | 1,11 s | 0,80 – 1,27 |
| Safari | 27.0 | 1,37 s | 1,31 – 1,48 |
| Firefox | 143.0.1 | 1,73 s | 1,63 – 1,85 |

Orée ouvre sa fenêtre en 49 % de temps en moins que Safari, 37 % de moins que Brave.

**Limites** : c'est le temps de la fenêtre, pas du chargement de la page ; Orée, Brave et Firefox démarrent avec un profil neuf, Safari avec le profil habituel (il n'en permet pas d'autre) ; une seule machine, un seul site ; l'instance d'Orée de l'utilisateur tournait en même temps (inactive). Orion non mesuré (son profil est celui de l'utilisateur).

**Optimisation faite** : l'écoute de la sortie audio (`AudioRoute.start`, qui réveille CoreAudio) est reportée après l'affichage de la fenêtre : −35 à −50 ms mesurés avec `HB_LAUNCH_TRACE=1`. Répartition d'un lancement (ms depuis le début du processus) : fenêtre configurée 285, barre latérale 294, feuille de page 316, première mise en page 412 (la plus grosse part restante, ~85 ms, inévitable avant d'afficher), fenêtre visible ~450, première page validée ~850.
