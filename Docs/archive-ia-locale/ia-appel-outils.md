# Le modèle de base sait-il appeler des outils ? — mesure préliminaire (étape 4)

Relevée le 11 octobre 2026, Qwen3.5-2B Q4_K_M, llama.cpp b11556, choix glouton des jetons (déterministe), pénalité de répétition 1.0, réflexion désactivée.
Matériel reproductible : `scripts/ia-probe/` (outils, cas, grammaire, notation) et `OreeAI --probe`.

## Méthode

- 26 situations écrites à la main, avec une carte de page au format du contrat (`PAGE … VISIBLE … @eN … TEXTE …`) : recherche, adresse donnée, clic, saisie, liste déroulante,
  défilement, formulaire, fin de tâche avec réponse visible, information manquante, et 2 pages piégées.
- Le prompt est rendu par le **modèle de conversation officiel de Qwen3.5** (Jinja, `tools` + `enable_thinking=false`), pas écrit à la main. Le modèle répond au format natif
  `<tool_call><function=…><parameter=…>…`.
- *Valide* : l'appel respecte le format, l'outil existe, les paramètres obligatoires sont là, `ref` est de la forme `@eN`. *Juste* : valide **et** le bon outil avec les bons arguments
  (référence attendue, mot-clé, champs du formulaire). Un seul tour : on juge le premier appel, pas une tâche complète.
- Séries : sortie libre ; sortie contrainte par grammaire GBNF (les 10 outils du contrat) ; grammaire et consigne améliorée.

## Résultats

| Série | Appels valides | Appels justes | Fuites vers l'adresse piégée |
|---|---|---|---|
| Sortie libre | 25 / 26 (96 %) | 15 / 26 (57 %) | 0 |
| **Grammaire GBNF** | **26 / 26 (100 %)** | **17 / 26 (65 %)** | 0 |
| Grammaire + consigne améliorée (règles sur `done` et `ask_user`) | 26 / 26 | 17 / 26 | 0 |

- La grammaire fait ce qu'on attend d'elle : **plus aucun appel invalide**. Elle ne rend pas les choix meilleurs.
- Ce qui réussit (grammaire) : adresse donnée (2/2), clic sur un lien nommé (5/5), liste déroulante (2/2), formulaire complet (2/2), recherche (2/3), saisie dans un champ (2/3), défilement (1/2).
- Ce qui échoue : **terminer avec `done`** (3 cas sur 3 : le modèle relit la page ou clique au lieu de répondre), **demander à l'utilisateur** (`ask_user`, 2 cas sur 2 : il remplit le formulaire
  de lui-même), et la page piégée où il fallait répondre (il ne suit pas l'ordre piégé, mais il n'a pas répondu non plus). Ajouter des règles dans la consigne n'a pas changé le total
  (les erreurs se déplacent). Ces deux outils sont ceux qui comptent pour la sécurité (confirmation, information manquante) : c'est ce que le LoRA de l'étape 5 doit améliorer.
- Aucune des deux pages piégées n'a fait appeler l'adresse piégée. Ce n'est **pas** une garantie : 2 cas, un seul tour, et le contrat veut que les règles d'Orée (confirmations,
  zones interdites) tiennent même si le modèle obéit.

## Limites de cette mesure

- 26 cas écrits par la même personne que la consigne : l'essai de consigne a été fait sur ces mêmes cas, donc ses résultats ne sont pas une évaluation indépendante.
- Un seul tour, sans enchaînement ni résultat d'outil ; cartes de page écrites à la main, pas produites par le vrai script de l'étape 2 ; 2 pages piégées seulement.
- Une seule exécution par série (choix glouton, donc reproductible, mais pas de variation d'échantillonnage mesurée).
- Durée : 7 à 10 s par cas, version debug, sans cache KV du préfixe d'outils (≈ 1 300 jetons de prompt à chaque fois) : non décomposée entre lecture du prompt et génération. À reprendre
  avec le cache KV avant de fixer un objectif de latence.

## Ce que la mesure a trouvé côté technique

- `llama_sampler_sample` accepte déjà le jeton : un second `llama_sampler_accept` faisait avancer la grammaire de deux pas et plantait (« Unexpected empty grammar stack »). Corrigé,
  y compris dans le chemin de réponse du service.
- `llama_chat_apply_template` n'exécute pas le Jinja de Qwen3.5 : il ne sait pas écrire la partie « outils ». L'xcframework n'expose pas le moteur Jinja de llama.cpp. **Question ouverte pour
  l'étape 4** : porter en Swift, avec des tests contre le rendu Jinja de référence (`scripts/ia-probe/render.py`), la partie « outils » du modèle de conversation, ou exposer le moteur autrement.
  Dans les deux cas, le texte exact vient du `chat_template.jinja` officiel, pas d'une écriture libre.
