# Plusieurs fenêtres

- **⌘N** (Fichier › Nouvelle fenêtre) ouvre une fenêtre avec ses propres onglets, décalée de celle au premier plan.
- **Clic droit sur un onglet › Déplacer vers une nouvelle fenêtre** : la page n'est pas rechargée (vidéo en cours, texte tapé et défilement gardés).
- Les menus (⌘T, Favoris, Historique, ⌘P…) s'adressent à la **fenêtre au premier plan**.
- **Session** : la première fenêtre garde la session principale (`tabSessions`) ; les autres sont enregistrées dans `extraWindowTabs`
  (`ExtraWindowsRepository`) et reviennent au lancement suivant, onglets endormis sauf celui qui était devant. Une fenêtre fermée par
  l'utilisateur ne revient pas ; à la fermeture d'Orée, toutes reviennent. Les onglets privés et les pages vides ne sont jamais enregistrés.

## Limites
- **Pas d'extensions** dans les fenêtres supplémentaires (elles ne sont chargées que dans la première).
- Le **budget mémoire** et la **mise en veille** sont comptés par fenêtre, pas pour l'ensemble.
- Espaces et groupes d'onglets : une fenêtre supplémentaire ne rouvre pas les groupes.
- Fermer la première fenêtre alors que d'autres sont ouvertes laisse Orée tourner ; ses onglets restent dans la session principale.
- Non vérifié : l'apparence des fenêtres à l'écran et le glisser d'un onglet hors de la barre.

## Tester
`python3 scripts/bench/dialogs_check.py` et `reader_check.py` ne couvrent pas les fenêtres ; les opérations `tab newwindow|windows|wload|wchain|detach|closeextra|quit`
du canal d'automatisation servent à les vérifier (voir la session du 14 octobre).
