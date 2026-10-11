# Mesures de l'IA locale — étape 1

Relevées le 11 octobre 2026 sur le Mac de développement : **MacBook M1, 8 Go, macOS 27.0**, Qwen3.5-2B Q4_K_M (1 270 808 032 octets, SHA-256 vérifié),
llama.cpp b11556 (Metal intégré), contexte 4096 jetons, 4 fils de calcul. Service compilé en **debug** (`./build_app.sh --debug`) ; le calcul se fait dans llama.cpp, donc
l'écart avec une version « release » devrait être faible, mais il n'a pas été mesuré.

Méthode : `OreeAI --bench` (même code que le service, sans XPC), un seul processus, un seul essai de chaque ligne. Les chiffres bougent d'une exécution à l'autre : sur trois séries
complètes, la génération est restée entre 16,4 et 19,2 jetons/s. **Ce ne sont pas des moyennes.**

- *Empreinte* : ce que macOS compte pour le processus (`ri_phys_footprint`). *Résident* : pages présentes en mémoire, y compris les poids mappés depuis le fichier (qui sont propres,
  donc reprenables par l'OS sans écriture). *Mémoire libre système* : `memory_pressure -Q`, pour situer l'effet sur la machine entière.
- *Jetons* : morceaux de texte émis par le moteur (≈ jetons ; un caractère coupé entre deux jetons est regroupé).
- Les états sont ceux du contrat : chaud (contexte créé), tiède (contexte libéré, cache KV du prompt système sur disque, poids ouverts), froid (poids fermés, l'OS reprend les pages).
  Le froid est ici déclenché à la main (pression mémoire « critique » simulée) ; le déclenchement par une vraie pression du système n'a pas été observé.

## Sans le navigateur ouvert

| étape | durée / détail | empreinte (Mo) | résident (Mo) | mémoire libre système |
|---|---|---|---|---|
| processus lancé | — | 42 | 85 | 55% |
| vérification SHA-256 (ready) | 0.98 s | 47 | 90 | 55% |
| froid → chaud (premier réveil) | 1.86 s total (prewarm 0.10, load 0.61, contexte 0.18) | 199 | 1346 | 27% |
| question (chaud) | 1er jeton après 0.15 s · 24 jetons · 18.0 jetons/s (génération) · 1.48 s au total | 216 | 1368 | 26% |
| question (chaud) | 1er jeton après 0.16 s · 161 jetons · 19.1 jetons/s (génération) · 8.60 s au total | 216 | 1355 | 26% |
| question (chaud) | 1er jeton après 0.17 s · 36 jetons · 19.2 jetons/s (génération) · 2.05 s au total | 216 | 1356 | 26% |
| → tiède | état tepid/ready | 146 | 1287 | 26% |
| tiède → chaud | 0.14 s (contexte 0.06) | 224 | 1376 | 26% |
| → froid | état cold/ready | 85 | 111 | 26% |
| froid → chaud (cache disque chaud) | 0.72 s (prewarm 0.07, load 0.60, contexte 0.05) | 182 | 1416 | 27% |

## Avec le navigateur ouvert

Instance d'essai d'Orée (version debug de cette branche, session vierge, page d'accueil seule, empreinte du navigateur : 83 Mo au repos), lancée avec
`open -g -n --env HB_FRESH_SESSION=1 --env HB_NO_AGENT=1 --env HB_DB_PATH=… --env HB_EXT_DIR=… Oree.app --args --automation`, puis fermée (PID lancé par moi uniquement).
`HB_NO_AGENT=1` en plus de la commande de base : il empêche l'instance d'essai de réécrire l'agent launchd du téléchargeur de l'utilisateur.

| étape | durée / détail | empreinte (Mo) | résident (Mo) | mémoire libre système |
|---|---|---|---|---|
| processus lancé | — | 44 | 87 | 55% |
| vérification SHA-256 (ready) | 1.11 s | 48 | 58 | 50% |
| froid → chaud (premier réveil) | 1.87 s total (prewarm 0.10, load 0.63, contexte 0.16) | 198 | 1379 | 25% |
| question (chaud) | 1er jeton après 0.17 s · 36 jetons · 16.5 jetons/s (génération) · 2.34 s au total | 214 | 1372 | 24% |
| question (chaud) | 1er jeton après 0.18 s · 211 jetons · 18.8 jetons/s (génération) · 11.41 s au total | 210 | 1372 | 25% |
| question (chaud) | 1er jeton après 0.19 s · 29 jetons · 19.2 jetons/s (génération) · 1.70 s au total | 210 | 1374 | 25% |
| → tiède | état tepid/ready | 140 | 1304 | 25% |
| tiède → chaud | 0.15 s (contexte 0.06) | 218 | 1393 | 25% |
| → froid | état cold/ready | 85 | 117 | 25% |
| froid → chaud (cache disque chaud) | 0.72 s (prewarm 0.07, load 0.61, contexte 0.05) | 179 | 1415 | 25% |

## Ce que disent ces chiffres

- Le calcul tient en mémoire sans effort : **≈ 200 Mo d'empreinte en chaud**, 146 Mo en tiède, 85 Mo en froid (le reste du « résident » est le fichier du modèle, propre et reprenable).
- La vérification SHA-256 coûte ≈ 1 s (1,3 Go lus) ; elle n'a lieu qu'une fois par lancement du service. Elle a révélé un défaut corrigé pendant les mesures : les blocs lus restaient
  en mémoire jusqu'à la fin (1,2 Go d'empreinte pendant la vérification) ; elle tourne maintenant à ≈ 47 Mo.
- Réveil : **froid → chaud 0,7 s** (fichier déjà dans le cache disque), **tiède → chaud ≈ 0,14 s**, premier réveil du service ≈ 1,9 s (dont ≈ 1 s de vérification).
- Génération : **≈ 16 à 19 jetons/s**, premier jeton ≈ 0,16 s après la question. Le navigateur d'essai ouvert n'a pas changé ce débit de façon visible (page d'accueil seule : voir les limites).

## Non mesuré (et pourquoi)

- **Chargement à froid depuis le disque** (cache disque vidé) : exige `sudo purge`. La ligne « froid → chaud » ci-dessus est donc *avec le cache disque chaud*. L'effet du pré-réveil
  (`madvise WILLNEED`) sur un vrai démarrage à froid n'est pas mesuré : le temps de pré-réveil relevé (0,07 à 0,3 s) est celui de l'appel, pas un gain démontré.
- **Navigateur chargé** (20 onglets, ≈ 1,6 Go d'après `Docs/ia.md`) : l'instance d'essai n'avait que la page d'accueil. L'interaction avec une vraie pression mémoire n'est pas mesurée.
- **Passage en tiède après 30 s** dans le vrai service : vérifié par test (horloge réduite, faux moteur) et par `coolDown` manuel avec le vrai moteur, pas par une attente de 30 s observée en direct.
  Le délai de maintien des poids par Metal est réglé à 30 s (`GGML_METAL_RESIDENCY_KEEP_ALIVE_S`, 180 s par défaut) ; son effet sur la mémoire n'est pas mesuré à part.
- Consommation d'énergie, température, version « release », autres Mac.
- Qualité des réponses : le français est correct sur ces essais, mais un modèle de 2 milliards de paramètres se trompe (il a répondu « le canton de Berne » pour la capitale de la Suisse).
  Aucune évaluation chiffrée n'a été faite : c'est l'objet des étapes 4 et 5.

## Chiffres cibles

À fixer par vous d'après ce tableau pour les étapes suivantes ; je n'en propose pas d'inventés.
