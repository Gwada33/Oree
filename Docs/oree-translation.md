# Traduction des pages (Apple Translation)

Traduit la page de l'onglet actif avec le framework **Translation** du système : le modèle est géré par macOS (zéro Mo livré
avec Orée), la traduction se fait sur le Mac, rien n'est envoyé nulle part.

## Ce que ça fait

- Un bouton « traduire » apparaît à droite de la barre d'adresse quand la langue **reconnue** du texte de la page diffère de la
  première langue préférée de l'utilisateur. Même action dans la palette (⌘K → « Traduire la page ») et le menu Édition.
- Un clic traduit sur place ; un second clic (bouton actif) remet l'original, octet pour octet.
- Jamais automatique. La page n'est lue que pour reconnaître sa langue (en local, ~2,5 Ko de texte).

## Architecture

| Pièce | Rôle |
|---|---|
| `BrowserCore/PageTranslation.swift` | Règles pures et testées : `TranslationPolicy` (http(s) seulement, langue principale, quand proposer, texte traduisible), `TranslationMemory` (textes déjà traduits, bornée à 5 000), `TranslationRound` (ce qui est connu, ce qu'il faut demander une seule fois au modèle). |
| `BrowserUI/TranslationScript.swift` | Script de page dans un monde isolé `oree-translate` (la page ne le voit pas). `sample`, `collect`, `apply`, `release`, `watch`, `restore`. |
| `BrowserUI/PageTranslator.swift` | Un par onglet (`Tab.translator`). Reconnaît la langue (`NLLanguageRecognizer`, repli sur `<html lang>`), choisit la session, boucle par lots, affiche les erreurs. |
| `BrowserWindowController` | Bouton, menu, palette, alerte d'erreur, branchement au changement d'onglet. |

### Déroulement

1. Après le chargement, `sample()` renvoie le texte visible ; `NLLanguageRecognizer` donne la langue (confiance ≥ 0,6).
2. Au clic : session `TranslationSession(installedSource:target:)` sur un modèle **déjà installé** (jamais de téléchargement
   déclenché). `.lowLatency` (le modèle rapide de Safari) s'il est installé, sinon `.highFidelity` (Apple Intelligence).
3. `collect(limit, reach)` rend les segments **les plus proches de l'écran** (24 puis 40 par lot, jusqu'à 2 écrans de distance).
   Texte, `placeholder`, `title`, `alt`, `aria-label`, boutons `submit`/`button`/`reset`, titre de l'onglet ; Shadow DOM ouvert inclus.
4. Les textes identiques sont demandés une fois, les connus sortent de la mémoire ; chaque réponse est posée dans la page dès
   qu'elle arrive (`translate(batch:)`).
5. `watch()` prévient l'app (rebond de 400 ms) après un défilement, un clic, un redimensionnement ou un changement du DOM : le lot
   suivant est pris à ce moment-là.
6. `restore()` remet chaque texte d'origine (sauf ceux que la page a réécrits entre-temps) et retire tout ce que le script a posé.

### Ce qui n'est jamais traduit

`<script>`, `<style>`, `<code>`, `<pre>`, `<kbd>`, `<textarea>`, SVG, iframes, zones `contenteditable`, `translate="no"`,
`.notranslate`, textes sans lettre (prix, dates), textes de plus de 4 000 caractères, **valeurs** saisies dans les champs.

## Mesures (Mac de développement, macOS 27, anglais → français, modèle `highFidelity`)

| Mesure | Résultat |
|---|---|
| Débit du modèle | ≈ 3 segments/s (200 segments : 70 à 85 s) |
| Regrouper 10 segments par requête | aucun gain (18 s pour 60 dans les deux cas) et **le modèle double les sauts de ligne** : la correspondance casse → une requête par segment |
| 3 sessions en parallèle | aucun gain (21 s pour 60) : le modèle est sérialisé |
| Premier démarrage du modèle | ≈ 6 s |
| Page de test, écran de départ (16 textes uniques) | 1er texte en ≈ 9 s, écran entier en ≈ 14 s |
| `.lowLatency` | **non mesuré** : le modèle rapide n'est pas installé sur cette machine (la session lève `notInstalled`) |

C'est pourquoi la traduction est paresseuse (autour de l'écran) et dédupliquée : traduire toute une page longue au débit de
`highFidelity` prendrait plusieurs minutes.

## Limites connues

- **Qualité** : traduction texte par texte. « Click **here** to continue » est traduit en trois morceaux indépendants (grammaire
  parfois fausse), et un mot isolé perd son contexte (« Home » → « maison »). Piste : regrouper par bloc avec des
  `AttributedString`.
- **Langues** : le modèle rapide (`lowLatency`) n'est pas celui que les Réglages Système téléchargent par défaut ; seule une
  session donnée par `.translationTask` peut le faire installer. `TranslationDownload.swift` (seul SwiftUI hors Réglages, vue
  invisible d'un point) le demande : palette ⌘K → « Télécharger la traduction rapide », ou bouton « Télécharger » de l'alerte
  quand aucune langue n'est installée. La fenêtre de téléchargement est celle du système (non vérifiée ici : instance de test masquée).
- **Fraîcheur** : une page mise en veille puis rouverte est rechargée **non traduite** (la traduction n'est pas rejouée).
- **Iframes** : leur contenu n'est pas traduit (seule la frame principale).
- **Contenu caché** (menu fermé) : repris au clic suivant ; un contenu qui apparaît sans clic ni changement du DOM reste en
  langue d'origine jusqu'au prochain défilement ou clic.
- **Langue cible** : la première langue préférée du système, sans réglage dédié.
- **macOS < 26** : fonction absente (le bouton n'apparaît pas, la palette ne propose rien).
- **Fantôme** (hibernation) : un onglet traduit n'est pas photographié en fantôme (il reviendrait traduit puis serait remplacé par
  la page d'origine) ; il retombe sur l'image classique.

## Tester

```
./build_app.sh
python3 scripts/bench/translate_check.py     # 23 vérifications, ~2 min, instance séparée (ne touche pas votre Orée)
scripts/test.sh                              # tests purs (PageTranslationTests)
```

À la main : `open -g Oree.app --args --automation`, puis `scripts/ui.sh load https://…` et `scripts/ui.sh tab translate 0`,
`scripts/ui.sh tab translation 0` pour l'état.
