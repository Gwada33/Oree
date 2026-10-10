# L'essentiel

> Nom d'origine : « Aller droit au but ». Affiché dans une **fenêtre flottante** (pop-up) centrée sur la page assombrie : clic à côté, Échap ou « Fermer » la ferme ; elle **reste après un rechargement** de la page ; fermée volontairement, elle ne se rouvre pas toute seule sur cette page.

**Curseur de personnes** (recettes dont la page donne le nombre de parts) : − / curseur / + ; les quantités en tête de ligne sont recalculées (« 85 g de beurre » → « 170 g »), avec accord du pluriel en français (« 1 oeuf » → « 2 oeufs », « 2 cuillères à café »). Non recalculés : lignes sans quantité en tête (« sel », « vanille ou 1 sachet… ») et fourchettes (« 2 à 3 pommes »). Le tableau complet est calculé en Swift (testé) ; la page ne fait que l'afficher (JavaScript activé pour cette seule page, texte échappé, politique de sécurité stricte).

Affiche l'essentiel d'une page : ingrédients, étapes et temps d'une recette ; étapes d'un tutoriel ; verdict d'un comparatif. Bouton
(icône « presse-papiers ») dans la barre d'outils quand la page fournit une recette ou un « how-to », ou ⌘K › « Aller droit au
but » sur n'importe quelle page web. Réglages › L'essentiel : afficher directement l'essentiel des recettes qui le fournissent.

## Deux étages

1. **Données de la page (instantané, exact).** Beaucoup de sites de recettes publient leur recette en JSON-LD (schema.org
   `Recipe`, `HowTo`). Orée la lit telle quelle : aucune IA, aucune erreur, temps en « 1 h 30 min ». Étiquette : « Lu dans les
   données de la page ».
2. **Modèle local (≈ 30 à 40 s).** Sinon, le texte principal de la page (`<article>`/`<main>`, sans navigation ni pubs) est lu par
   le modèle d'Apple Intelligence (macOS 26 et Apple Intelligence activée). Étiquette : « Écrit par le modèle local · peut contenir
   des erreurs ». Rien ne quitte le Mac.

## Garde-fous contre les inventions du modèle

Mesuré sur une vraie recette (BBC Good Food) : bonne structure, mais le modèle avait *traduit* la page, remplacé « caster sugar » par
« sucre glace » et ajouté « un peu d'eau salée ». Donc :
- il doit répondre dans la langue de la page, sans traduire ;
- chaque ingrédient, étape, point fort/faible est **gardé seulement si au moins la moitié de ses mots significatifs (≥ 4 lettres)
  figurent dans le texte de la page** ; sinon il est écarté et la page le dit (« 1 élément du résumé, introuvable dans la page, a
  été écarté ») ;
- un verdict est écarté si moins de 40 % de ses mots viennent de la page ;
- si rien ne survit : « rien n'est affiché », jamais un résumé inventé.

## Mode cuisine

Bouton « Mode cuisine » : texte très grand, une colonne, et **l'écran ne se met pas en veille** (assertion IOKit, relâchée en quittant
le mode, en fermant le panneau, en changeant d'onglet ou de page).

## Design

La page parle le langage de la page d'accueil : mêmes variables de couleurs claires/sombres, même teinte d'accent (réglages), mêmes
rayons, Instrument Sans pour le texte et **Instrument Serif italique** pour le titre et les numéros d'étapes, puces arrondies pour les
temps, filets fins entre les lignes. Les ingrédients et les étapes ont une **case à cocher sans JavaScript** (le texte coché
s'estompe) ; en mode cuisine, chaque étape devient une carte. La description « vitrine » d'une recette (qui répète le titre et les temps)
n'est pas affichée. Polices servies par `OreeSchemeHandler`, comme pour l'accueil.

## Détails

- Le panneau est une vue web **sans JavaScript**, au stockage non persistant, qui refuse toute navigation ; il n'affiche que du HTML
  construit par `DigestRenderer` (tout texte de la page est échappé, testé).
- Contexte du modèle (≈ 4 000 jetons) : le texte est borné à 6 000 caractères (début et fin, là où sont recette, étapes, verdict).
- Résultats gardés en mémoire (30 pages) le temps de la session.

## Limites

- Lent avec le modèle (30–40 s ; la première requête de la session peut prendre ~18 s de plus) ; « Annuler » est proposé.
- Pages dont le texte est rendu par JavaScript tardif, ou très longs comparatifs (le milieu du texte n'est pas lu).
- Les « ingrédients » d'un tutoriel (matériel) ne sont lus que dans les données structurées `supply`/`tool`.
- Sans Apple Intelligence : seul l'étage 1 fonctionne ; un message l'explique pour le reste.

## Tester

```
./build_app.sh --debug
python3 scripts/bench/digest_check.py      # 13 vérifications, ~1 min, instance séparée (le modèle n'est pas requis pour les 9 premières)
scripts/test.sh --fast                     # PageDigestTests
```
