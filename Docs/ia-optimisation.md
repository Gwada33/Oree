# Luciole : optimisation du système d'IA (15 octobre 2026)

Audit, changements, mesures et limites. Les chiffres viennent de `scripts/bench/ai_cost.py` (Groq, `openai/gpt-oss-20b`, même instance d'essai, mêmes cinq questions) ; les jetons sont ceux
**comptés par le fournisseur**, pas des estimations. Les fichiers bruts : `Docs/ia-mesures-avant.json`, `Docs/ia-mesures-apres.json`, `Docs/ia-mesures-apres-bis.json`.

## 1. Ce que l'audit a trouvé

| Constat | Effet mesuré |
|---|---|
| Chaque tour renvoyait tout : consignes (≈ 300 jetons), les 10 outils (≈ 900 jetons), la carte de la page (jusqu'à 2 800 caractères + 45 éléments), l'historique recopié | « Quelle est la capitale du Portugal ? » coûtait **1 063 jetons** pour 35 jetons de réponse |
| Aucun routage : la page était lue même pour une question de culture générale, et le modèle pouvait chercher sur le web de lui-même | la même question, posée après une question météo, déclenchait une recherche |
| La conversation était réécrite à chaque tour : la page lue à l'étape 1 était **perdue** à l'étape 2 (l'historique ne gardait que 300 caractères de chaque résultat), puis renvoyée | des tâches web à 19 et 22 requêtes |
| Les résultats de recherche allaient au modèle tels quels (5 résultats, annonces comprises) | contexte inutile, annonces et doublons |
| 429 : jusqu'à 3 relances, uniquement si l'attente demandée ≤ 20 s, sans backoff, sans mémoire d'un tour à l'autre ; l'attente écrite dans le message d'erreur ignorée | 11 à 16 relances par série, tâches échouées |
| Un appel déjà fait n'était détecté que s'il était dans les 2 dernières étapes ; rien ne reconnaissait une boucle | tâches qui allaient jusqu'au plafond de 15 étapes |
| Le service local (OreeAI + llama.framework 24 Mo + téléchargement de 1,3 Go) n'était pas viable | voir §3 |
| Le « carré » de Luciole (cadre d'accent) restait posé sur le dernier élément jusqu'au geste suivant | impression d'interface bloquée |

## 2. Ce qui a changé

**Routage sans appel au modèle** (`BrowserCore/AIRouter.swift`) : des règles de mots (accents et majuscules ignorés) choisissent `direct` (connaissance générale : ni page, ni recherche d'office),
`page` (la page d'abord), `web` (information récente ou à vérifier, comparaison, « cherche… ») ou `agent` (agir : tous les outils et la page). Chaque route fixe les outils envoyés
(seuls ceux-là sont décrits dans la requête), le nombre de recherches, la limite de sortie et le nombre d'essais (4 / 6 / 8 / 15). Le routage économise, il n'interdit pas : si le modèle demande un
outil d'action alors que la page n'avait pas été fournie, la tâche passe en mode `agent`, la page arrive, et l'appel fait à l'aveugle n'est **pas** exécuté.

**Conversation gardée au lieu d'être réécrite** (`ModelRequest`, `AgentLoop`) : consignes + tâche en tête (identiques d'un tour à l'autre), puis appels d'outils et résultats comme messages d'outils.
La page est **un seul message** qui est remplacé quand elle change vraiment (empreinte du contenu) et jamais renvoyé si elle n'a pas changé. Les anciens résultats sont raccourcis.
`read_page` n'est plus proposé quand la page est déjà dans la conversation. Les souvenirs et la conversation précédente ne partent que si la tâche en a besoin (agir, page, ou question qui reprend la précédente).

**Prétraitement local** : `PageMap.render(focus:)` garde, dans une page trop longue, les titres et les passages qui parlent de la question (le début de la page sinon) ;
`SearchResultFilter` écarte annonces et doublons, classe par lien avec la question, favorise un peu les sources connues, et limite à 3–5 résultats selon la question ; les recherches
sont gardées 10 minutes (`TTLCache`).

**Registre des actions** (`ActionLedger`) : chaque appel passe par `running → done | failed(n)`. `done` seulement quand l'exécuteur a vérifié le résultat. Une recherche ou une lecture déjà faite
et toujours valable est **réutilisée** ; une action refaite à l'identique sur une page qui n'a pas changé est **refusée** ; un appel échoué deux fois est abandonné ; une page déjà ouverte n'est pas rouverte ;
une tâche qui tourne en rond reçoit un avertissement, puis s'arrête avec ce qui a été trouvé.

**Requêtes et limites de débit** (`RetryPolicy`, `RateLimitGate`, `CloudClient`) : backoff exponentiel (1,5 s × 2ⁿ, aléa ±20 %, plafond 30 s), `Retry-After` (secondes ou date) et attentes écrites par
Groq (`x-ratelimit-reset-*` sur un refus, « try again in 6.8s » dans le message ou dans le flux), 4 essais et 75 s d'attente au plus, annulation à tout moment, une seule barrière par fournisseur (un « attendez »
vaut pour tous les tours). Seules les erreurs passagères (408, 425, 429, 5xx, réseau, flux vide) sont relancées ; une clé refusée ne l'est jamais. Une requête au modèle ne fait rien dans le navigateur : la relancer ne
peut pas doubler une action. Une tâche arrêtée par une erreur du fournisseur garde son état : « reprends » repart de là sans rien refaire.

**Sortie** : limite de jetons par route (800–1 100 au lieu de 1 500) ; une réponse coupée par la limite est signalée (« […] ») ; consignes courtes avec « à la mesure de la question ».
Le flux (déjà en place) est conservé : le texte s'écrit au fil de l'eau.

**Luciole** (`AgentCursor`, `LucioleState`) : la mascotte reste en vue dans un coin de la page pendant la tâche, et sa pose suit les **événements réels** de la boucle
(requête partie → réflexion, recherche/lecture → lecture, saisie → écriture, clic/ouverture → action, question → attente de vous, limite de débit → attente, fin → contente ou en erreur). Le cadre autour d'un
élément s'efface 1,5 s après le geste (il reste seulement pendant une validation demandée) ; la chip du panneau affiche « Limite de débit · N s ». Sans événement, la pose ne change pas : rien n'est simulé.

## 3. IA locale retirée

Supprimés : cibles `OreeAIService` (+ `llama` binaryTarget), `OreeAIEngine`, `OreeAIProtocol`, `OreeAIClient`, leurs tests, l'installation de l'agent launchd, le téléchargement du modèle,
l'autorisation du dossier `Models/` dans le téléchargeur, le cas `AIProvider.local`, les écrans « télécharger le modèle ». `LucioleState` et `AIAvailability` (purs) ont déménagé dans BrowserCore.
Conservés : `LocalModel` (le modèle d'Apple Intelligence du système, qui sert « L'essentiel », les boosts et le calendrier : ce n'est pas un composant d'Orée) et `OreeDownloader` (téléchargements de fichiers).

**Modularité pour plus tard** : un moteur local futur serait un cas de `AIProvider` avec son propre module, derrière la même `ModelRequest` (conversation + outils permis + limite). Aucun autre code
n'a besoin de changer. Les documents de l'ancien service sont dans `Docs/archive-ia-locale/`.

**Poids du bundle (build de production, `./build_app.sh`)** : **47 372 Ko → 22 164 Ko (−53 %)**. `llama.framework` (24 Mo) et `OreeAI` (0,6 Mo) disparaissent ; l'exécutable principal est inchangé (20 Mo).

## 4. Mesures avant / après

Cinq questions, une instance d'essai, Groq. « Avant » : `Docs/ia-mesures-avant.json` (état du commit « Mesure du coût… »). « Après » : `Docs/ia-mesures-apres.json`.

| | avant | après |
|---|---|---|
| Requêtes API (total des 5 questions) | 34 | **6** |
| Jetons d'entrée | 34 776 | **6 967** |
| Jetons de sortie | 626 | **340** |
| Contexte envoyé (caractères des requêtes) | 319 325 | **28 617** |
| Relances (429 et autres) | 16 | **0** |
| Tâches échouées | 1 + 1 expirée | **0** |
| Recherches web / lectures de page | 2 / 4 | **1 / 0** |
| « capitale du Portugal » (jetons d'entrée) | 1 063 | **501** |
| « météo à Lyon » (requêtes / jetons d'entrée) | 22 (expirée) | **2 / 1 557** |

**Honnêteté sur la variance** : la série « après » a été rejouée trois fois. Deux fois : 6 requêtes, 0 relance. Une fois (quota Groq gratuit déjà entamé par les séries précédentes) : la question météo a fait 7 requêtes
avec 3 relances puis s'est arrêtée proprement avec « reprends » ; les quatre autres questions sont restées identiques (1 requête chacune). Une série « avant » d'un autre jour avait donné 19 requêtes et 9 relances pour la même
question. Ces chiffres dépendent du quota du fournisseur : ils montrent l'ordre de grandeur, pas une garantie. Je n'ai pas mesuré de qualité de réponse sur un jeu d'évaluation : sur ces cinq questions, les réponses sont justes et complètes.

## 5. Vérifications automatiques

- 399 tests purs (BrowserCore) : routage (accents, priorités, suites de question, essais par route), relances (backoff exact, bornes, plafond d'attente, erreurs définitives, barrière), tri de recherche, cache,
  choix des passages d'une page, registre (réutilisation, doubles actions, échecs, défilement, tour en rond), boucle (page jamais renvoyée si inchangée, une seule version de la page, reprise après erreur, escalade, événements).
- `scripts/bench/agent_check.py` : 29/29 (cartes de validation, Stop, questions, sécurité, mémoire envoyée seulement quand utile, tour en rond arrêté).
- `scripts/bench/lmstudio_check.py` : 28/28, dont 429 avec `Retry-After` (3 requêtes, attente respectée, pose « attente »), 401 jamais relancé, 503 relancé une fois, Luciole visible et en pose « réflexion » pendant l'attente du modèle.
- `scripts/bench/ai_cost.py` : la mesure du §4.

## 6. Limites restantes

- Le routage est un jeu de règles de mots : une demande d'action sans verbe connu part en `direct`, puis passe en `agent` au premier outil d'action demandé (un tour de plus, pas d'erreur).
- Le prompt caching du fournisseur n'est pas exploité explicitement (le début de la conversation est stable, donc il peut jouer, mais je ne l'ai pas mesuré).
- Les quotas gratuits de Groq restent serrés : après plusieurs tâches d'affilée, une attente > 30 s est rendue à la personne plutôt qu'attendue.
- Le cadre, la mascotte et leurs déplacements dans la page ne sont pas visibles sur les captures d'écran de ma fenêtre de test (calque au-dessus de la page) : je les ai vérifiés par leurs positions et poses (`aistate`), pas à l'œil.
- Le tri des résultats favorise des domaines connus à la main (liste courte) ; la fraîcheur se limite à l'année dans l'extrait.
