# Luciole dans la page

Luciole ne vit plus dans un panneau latéral : une couche native transparente (`LucioleOverlayView`) est posée au-dessus de la page de l'onglet actif.
Le cerveau n'a pas changé (`AIPanelController`, `AgentLoop`, les outils, les règles de sécurité) ; seule la présentation change.
Réglage : Réglages › Assistant › « Luciole s'affiche » (dans la page par défaut, ou panneau latéral). S'applique à la prochaine ouverture (⌘J).

## Les moments

| Moment | Ce qu'on voit | Où c'est |
|---|---|---|
| Appel (⌘J) | Luciole quitte la barre d'outils et s'ouvre en capsule de verre (champ, œil de partage, envoi) ; trois suggestions au-dessus | `LucioleOverlayView` |
| Sélection | Trois mots sélectionnés + 300 ms : Luciole vole au bout de la ligne et propose Expliquer (E), Traduire (T), Garder (G) | `LucioleSelectionScript`, `SelectionPassage` |
| Réponse ancrée | Bulle de 380 pt à côté du passage, surlignage et fil de lumière dessinés par la couche (jamais dans le site) ; Markdown mis en forme | `LucioleGeometry`, `MarkdownRenderer` |
| Action | Pastille numérotée sur chaque élément touché, pointillés lumineux, pastille « étape n sur 15 · Arrêter · esc » | `AgentCursor.onReveal`, `LucioleOverlayView` |
| Validation | Page assombrie avec un trou et un anneau autour de l'élément ; carte dense ; Annuler par défaut, Valider après 1,2 s, Entrée ne valide jamais | `LucioleDimView`, `LucioleDecisionCard` |
| Question | La même carte, avec un champ de réponse | `LucioleDecisionCard` |
| Repos | Après une tâche qui a agi : saut de joie, retour dans la barre d'outils, bulle de 4 s ; le chemin reste 60 s | `retractToRest` |
| Page protégée | Luciole détourne les yeux : une ligne sous la barre d'outils, pas de capsule | `protectedLine` |
| État du modèle | Carte (injoignable, clé manquante…) avec « Réessayer » ; plus de panneau | `LucioleDecisionCard.show(model:)` |

## Sécurité (ce qui ne bouge pas)

- La carte de validation est construite par Orée à partir des champs réels du formulaire, secrets masqués : jamais à partir du texte du modèle.
- Une adresse que ni la demande, ni une recherche, ni la page n'ont nommée demande un accord ; une valeur personnelle inventée est refusée (`OpenURLGuard`, `PersonalValueGuard`).
- Pendant une validation, le voile prend les clics : rien ne se passe sous lui.
- Le passage sélectionné part au modèle entre balises `<page>`, comme une donnée.
- Rien n'est injecté dans le DOM des sites. Le script de lecture est en monde isolé (`oree-luciole`), il lit des rectangles et ne change rien ; il n'existe que si « Dans la page » et « gestes de sélection » sont actifs, et jamais en navigation privée.

## Limites connues

- Le script de lecture est installé dès que le réglage est actif (il n'est pas injecté « seulement pendant une sélection ») ; hors sélection il ne calcule rien. Les pages chargées avant l'activation ne l'ont pas : recharger.
- Le script ne lit que le cadre principal (pas les iframes).
- Le flou animé 6 → 0 de l'apparition n'est pas fait (AppKit n'a pas de flou animable sur une vue) ; l'échelle, l'opacité et le rebond y sont.
- Les captures hors écran de mes bancs ne rendent pas le verre (`NSGlassEffectView`) : la disposition est vérifiée par elles, la matière à l'œil.
- « Garder » met la page avec un lien vers le passage (`#:~:text=`) dans la liste de lecture ; le passage lui-même n'est pas stocké.
- Le chemin n'est testé que sur des tâches à deux étapes.

## Tester

```
OREE_APP_DIR=/chemin/OreeTest.app ./build_app.sh --debug
OREE_TEST_APP=/chemin/OreeTest.app python3 scripts/bench/luciole_page_check.py             # sélection, éventail, réponse ancrée (6 vérifications)
HB_LUCIOLE_PAGE=1 OREE_TEST_APP=… python3 scripts/bench/agent_check.py                      # validation, question, trace, repos (30)
OREE_TEST_APP=… python3 scripts/bench/agent_check.py                                         # le même, panneau latéral (29)
scripts/test.sh --fast                                                                       # LucioleStageTests, SelectionPassageTests…
```
Lancer ces bancs un par un : juste après la suite de tests, la machine chargée les rend instables.
