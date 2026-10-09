# Nom et identité — choix proposé : **Atoll**

## Pourquoi « Atoll »
- Un atoll est un **anneau d'îlots** autour d'un lagon calme : exactement l'idée du navigateur — des **espaces** (îlots) autour d'un centre calme, des onglets qui **dorment** quand on ne les regarde pas.
- Court (5 lettres), prononçable pareil en français et en anglais, facile à retenir.
- Le logo en découle : trois îlots en anneau (comme les trois espaces Perso / Travail / Lecture) et un point central (« vous êtes ici »).
- Palette : le vert citron déjà utilisé dans l'interface, vers un aqua de lagon.

## Vérifications faites (à compléter avant lancement)
- Aucun navigateur nommé « Atoll » trouvé dans les recherches web (navigateurs récents sur Mac : Arc, Dia, Orion, Zen, Tangerine, Nook, Aloha).
- Autres usages du mot : « ATOLL » (matériel audio hi-fi), « Atoll » (logiciel de planification radio de Forsk), une app de corail. Secteurs différents, mais **à vérifier en marque** (INPI / EUIPO / USPTO) avant toute publication.
- Noms de domaine : `atoll.com`, `.app`, `.io`, `.co`, `.dev` sont déjà **pris** (comme tous les mots courants). Pistes : `atollbrowser.com`, `getatoll.com`, `atoll-browser.app` (apparaissent libres au test DNS, ce n'est **pas** une preuve de disponibilité : à vérifier auprès d'un registraire).

## Autres noms envisagés
| Nom | Idée | Remarque |
|---|---|---|
| **Sylph** | esprit de l'air : léger, rapide | aucun navigateur trouvé ; mot rare, prononciation « silf » |
| **Loir** | le loir dort (« dormir comme un loir ») | clin d'œil français, moins lisible en anglais |
| Lull / Nimbo | calme / nuage | aucun navigateur trouvé |
| Wisp, Tern, Lark, Plume… | mots courts et légers | domaines tous pris, noms très utilisés ailleurs |

## Fichiers
- `AppIcon-1024.png` : icône macOS (utilisée par `build_app.sh`).
- `atoll-mark.png` : le symbole seul, fond transparent.
- `atoll-lockup-light-text.png` / `atoll-lockup-dark-text.png` : symbole + nom (texte clair pour fonds sombres, texte sombre pour fonds clairs).
- `make_logo.swift` : génère tout (`swift Branding/make_logo.swift Branding`).

## Pas encore fait
- Le renommage dans l'app (nom affiché, identifiant du paquet `com.nolhan.hyperbrowser`, dossier de données). Changer l'identifiant fait repartir de zéro les préférences et l'accès au Trousseau : à faire en une seule fois, une fois le nom validé.
