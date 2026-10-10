# Boosts : changer un site en une phrase, et mode calme

⌘K › « Personnaliser ce site… » : une phrase (« cache les recommandations et agrandis le texte »), le modèle local écrit des règles de
**style**, l'app les vérifie, les applique et les garde **pour ce site seulement**. Une pastille « Annuler » (15 s) les retire aussitôt ;
⌘K › « Retirer les changements de ce site » les enlève plus tard. Nécessite macOS 26 et Apple Intelligence.

## Pourquoi c'est sûr

Le modèle ne produit que du JSON de règles CSS. Rien n'atteint la page avant ces contrôles (`BoostPolicy`, testés) :
- **sélecteurs** : sans `{ } ; @ \ url( expression /* <`, longueur bornée, jamais trop larges (`body`, `div`, `*`, `html`…) ;
- **propriétés** : liste blanche d'apparence (cacher, taille, espaces, couleurs, polices, mouvement) ; pas de `position`, de `content`,
  de `background-image` ; valeurs sans `url()` ni sortie de règle ;
- **essai à blanc dans la page** : une règle qui ne correspond à rien, ou à presque tout, est écartée ; **une règle qui cache plus d'un
  tiers du texte de la page est écartée** (le modèle avait caché l'article avec les pubs lors d'un essai) ;
- toujours du CSS, **jamais de JavaScript**, aucune requête réseau possible.

Le modèle voit la liste des éléments réels de la page (balises personnalisées, identifiants, classes, avec leur nombre et le début de
leur texte), pas une devinette. Consigne : « fais le minimum ».

## Mode calme

Par site (⌘K › « Mode calme sur ce site ») ou partout (Réglages › Mode calme…) : **pas de lecture automatique** tant que la page n'a pas
été touchée, **animations et transitions coupées**, pastilles de notification courantes cachées, « (3) » retiré du titre de l'onglet.

## Limites

- **Scroll infini** : non géré (aucun moyen général fiable) ; promis dans l'idée de départ, **pas fait**.
- Le modèle reste faillible et lent (30–60 s) ; sur un site dont les noms d'éléments sont opaques, il peut ne rien trouver (message clair).
- Vérifié sur une page de test (16 contrôles) ; **essai sur YouTube non concluant** (ma session n'avait pas d'étagère « Shorts »).
- Pastilles de notification : repérage par noms de classes courants, donc partiel. Les boosts ne suivent pas les sites qui changent leurs classes.
- Les boosts sont des réglages (non effacés avec l'historique) ; pas encore de liste dans les Réglages.

## Tester

```
./build_app.sh --debug
python3 scripts/bench/boost_check.py     # 16 vérifications ; la dernière utilise le modèle (ignorée s'il est indisponible)
scripts/test.sh --fast                   # BoostPolicyTests, BoostRepositoryTests
```
