# Copier-coller propre

Copier depuis une page met sur le presse-papiers **le texte tel qu'on le lit**, sans la police, les couleurs, les liens ni le
texte caché du site. Réglages › Confidentialité › Copier-coller (activé par défaut).

| Cas | Résultat |
|---|---|
| Texte ordinaire | texte brut ; la destination (Notes, Mail, Pages) applique son propre style |
| Sélection sur plusieurs cellules d'un tableau | texte séparé par des tabulations : Numbers et Excel le collent en vrai tableau (cellules vides conservées) |
| Citation (≥ 25 caractères) avec l'option « source » | texte + `— Titre (adresse#:~:text=…)` : le lien ramène au passage exact (fragment de texte) |
| Adresse postale seule (≤ 200 caractères, 3 lignes) | une pastille « Adresse copiée · Ouvrir dans Plans » (8 s), ouvre `maps://?q=…` |
| Copie depuis un champ, un éditeur, ou une page qui gère elle-même la copie | laissée telle quelle |

## Pourquoi du texte brut seulement

WebKit réécrit tout HTML posé sur le presse-papiers et y ajoute des styles explicites (police par défaut, taille « medium »,
noir) : mon essai de HTML « structure seule » arrivait avec ces styles, donc imposait sa mise en forme à la destination au lieu
de s'y adapter. Le texte brut évite cela. Contrepartie : gras, listes à puces et titres ne sont plus copiés comme tels.

## Limites

- S'applique aux pages ouvertes après un changement de réglage.
- Sélection dans un Shadow DOM : laissée au comportement normal.
- Le lien « passage exact » n'est vérifié que dans sa forme ; WebKit le suit dans Safari, non testé dans Orée.
- Une cellule fusionnée (`colspan`) décale les colonnes d'un tableau copié.

## Tester

```
./build_app.sh --debug
python3 scripts/bench/copy_check.py     # 11 vérifications, instance séparée ; remet le réglage « source » comme avant
scripts/test.sh --fast                  # CopyPolicyTests
```
