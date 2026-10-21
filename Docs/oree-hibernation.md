# Hibernation invisible d'Orée — « Fantôme + Hydratation »

Statut : **phases 1 à 3 terminées** (derrière le flag `oree.hibernation.ghost`, désactivé par défaut). Phases 4 à 6 : voir « Suite ».

## Principe
La veille actuelle remplace l'onglet par une image HEIC puis recharge la page derrière : l'image est morte et le remplacement se voit.
Le fantôme remplace l'image par **le DOM vivant sérialisé** :
1. à la mise en veille, on fige la page (HTML + CSS + état des formulaires + scroll), on le compresse (zstd, Rust) et on le range sur disque ; la vraie page est détruite ;
2. au retour, une WebView **sans JavaScript** affiche le fantôme (scroll, sélection, `:hover`, animations CSS, GIF fonctionnent) ;
3. la vraie page se restaure dessous, puis prend la place (échange invisible : phase 2).

Repli : si quoi que ce soit échoue (flag éteint, onglet privé, page trop lourde, script en erreur, fichier illisible), l'ancien chemin (image HEIC) s'applique tel quel.

## Activation
- Réglage `oree.hibernation.ghost` (UserDefaults, `SettingsStore.hibernationGhost`), ou variable d'environnement `HB_GHOST=1`.
- Outils de développement : `HB_GHOST_DUMP=/chemin` (écrit le HTML capturé), `HB_GHOST_PROBE=<js>` (exécute un script dans le fantôme), `HB_GHOST_SETTLE=<s>` (attente avant capture d'écran).

## Architecture
| Couche | Fichier | Rôle |
|---|---|---|
| Rust | `Rust/adblock_bridge/src/ghost.rs` | `ghost_compress` / `ghost_decompress` (zstd, plafond 32 Mo à la décompression), `GhostStore` (fichiers opaques, écriture atomique, clés `[A-Za-z0-9_-]`, `purge`) |
| BrowserCore | `GhostRecord.swift` | `GhostRecord` (DOM + scroll), `GhostPolicy` (jamais en privé, http/https seulement, ≤ 5 Mo de HTML), `GhostCodec` (JSON → zstd), `GhostBlobStore` (enveloppe Swift de `GhostStore`) |
| BrowserUI | `GhostBootstrap.swift` | script de capture dans le monde de la page (Shadow DOM, canvas, vidéo, iframes, `data-oree-live`) |
| BrowserUI | `GhostScript.swift` | restauration du scroll, sondes « prête » / comparaison (monde `oree-ghost`) |
| BrowserCore | `GhostCapture.swift`, `GhostMatcher.swift` | réponse de la capture, assemblage des espaces réservés, comparaison fantôme / vraie page |
| BrowserUI | `GhostView.swift` | WebView du fantôme (JS coupé, pool de process dédié, annule toute navigation et la signale), `GhostStorage` (dossier `Caches/Orée/Ghosts`, vidé au lancement et à la fermeture) |
| BrowserUI | `Tab.swift` | capture dans `suspend()`, affichage dans `wake()`, retrait dans `finishWakeReveal()` |
| BrowserUI | `Tab+GhostHarness.swift` | outillage de développement (`ui.sh ghost`), uniquement via `--automation` |

Choix de conception :
- le fantôme a **son propre pool de process** : sa page ne partage jamais le process d'un vrai onglet (indispensable pour le gel noyau de la phase 5) ;
- même `WKWebsiteDataStore` que l'onglet : les sous-ressources (CSS, images, polices) viennent du cache HTTP (vérifié : **0 requête réseau** pour recharger le fantôme) ;
- le fantôme a son propre délégué de navigation (`Tab.tab(for:)` identifie les vues par identité : une vue fantôme n'y serait pas reconnue) ;
- les contenus bloqués par les listes de pubs ne sont pas rechargés dans le fantôme.

## Ce que fait la capture
Sur une **copie** du DOM (la page vivante n'est jamais modifiée) :
- retire `<script>`, `<noscript>` (avec JS coupé son contenu s'afficherait), `<meta http-equiv=refresh>`, le `<base>` d'origine (remplacé par l'URL de la page) et les liens de préchargement ;
- écrit l'état des formulaires en attributs ; **jamais la valeur** d'un champ mot de passe, carte (`cc-*`), code à usage unique, ni des champs cachés (souvent des jetons CSRF) ;
- note le scroll de chaque conteneur scrollable (`data-oree-scroll`) et celui de la page ;
- reconstruit les `<style>` depuis le CSSOM vivant (les règles ajoutées par `insertRule` n'existent pas dans le HTML) et ajoute les `adoptedStyleSheets` ; les feuilles `<link>` **cross-origin** restent des liens (leurs règles sont illisibles mais rechargées depuis le cache) ;
- neutralise les animations CSS qui rejoueraient depuis zéro (terminées → valeurs finales écrites, `animation: none` ; en cours → reprise au même instant) ;
- coupe les transitions CSS pendant les 2,5 premières secondes du fantôme (voir « Pièges »).

## Spike : hypothèses WebKit vérifiées (macOS 27, 10 oct. 2026)
| Hypothèse | Résultat |
|---|---|
| `allowsContentJavaScript = false` renvoyé par `decidePolicyFor` d'un `loadHTMLString` laisse tourner nos `WKUserScript` et `evaluateJavaScript(in: contentWorld)` | **Vrai** (le script de la page ne tourne pas, les nôtres oui) |
| Le fantôme recharge ses sous-ressources depuis le cache du `WKWebsiteDataStore` partagé | **Vrai avec le store persistant** (0 requête) ; **faux avec un store non persistant** (tout est retéléchargé) |
| `cssRules` d'une feuille cross-origin lève `SecurityError` | **Vrai** → on garde le `<link>` (correction de la spec initiale qui prévoyait de tout inliner) |
| `:hover` fonctionne dans le fantôme | **Non vérifié** dans le spike (fenêtre non active : les événements souris synthétiques n'ont pas déclenché le survol). Les animations CSS, elles, avancent (vérifié). À valider avec de vrais événements en phase 2 |

## Résultats phase 1 — fidélité sur 10 sites
Mesure : `scripts/bench/ghost_check.py` (page scrollée de 700 px, capture d'écran de la page vivante avant **et** après la capture, capture du fantôme, % de pixels qui diffèrent — seuil 40/765 par pixel, comparé à la plus proche des deux captures vivantes).

| Site | Écart | HTML → compressé | Capture | Chargement du fantôme |
|---|---|---|---|---|
| BBC News | 0,0 % | 286 → 42 Ko | 111 ms | 398 ms |
| Wikipédia (Lisbonne) | 0,0 % | 1 329 → 177 Ko | 947 ms | 1 100–3 400 ms |
| GitHub | 0,0 % | 32 → 8 Ko | 32 ms | 210 ms |
| react.dev (SPA React) | 0,0 % | 284 → 46 Ko | 112 ms | 393 ms |
| IKEA (e-commerce) | 0,0 % | 501 → 58 Ko | 423 ms | 1 277 ms |
| MDN (doc technique) | **8,3 %** | 307 → 38 Ko | 80 ms | 334 ms |
| Hacker News | 0,0 % | 61 → 10 Ko | 21 ms | 176 ms |
| Stack Overflow | **5,0 %** | 1 100 → 122 Ko | 279 ms | 654 ms |
| vercel.com (Next.js) | 0,0 % | 2 073 → 64 Ko | 1 484 ms | 307 ms |
| Tailwind (doc) | 0,0 % | 180 → 17 Ko | 138 ms | 337 ms |

**8 sites sur 10 sont identiques au pixel près**, y compris une SPA React, un site Next.js et un e-commerce de 90 feuilles de style. Taux de compression moyen : environ 7 à 30 ×.

Échecs et causes (vérifiées) :
- **MDN (8,3 %)** : l'en-tête utilise des web components à Shadow DOM (`<mdn-dropdown>`). Le CSS qui masque les menus vit dans le shadow root, absent du fantôme : les menus s'affichent ouverts. → **phase 3** (sérialiser les shadow roots).
- **Stack Overflow (5,0 %)** : la seule différence est la pastille « Se connecter avec Google » (iframe cross-origin). → **phase 3** (iframes).

## Tests
- `scripts/test.sh` : `GhostTests` (codec, politique, drapeau), tests Rust (`cargo test` dans `Rust/adblock_bridge`).
- `scripts/bench/ghost_fixture_check.py` : **hors ligne**, 16 vérifications sur une page locale (mot de passe, carte, champ caché absents ; texte saisi, case, option, scroll, règle `insertRule`, image lazy, `<base>` présents).
- `scripts/bench/ghost_check.py` : fidélité en pixels sur 10 vrais sites (réseau requis).
- Cycle réel : `ui.sh tab sleep 0` puis `ui.sh tab select 0` ; les durées sont dans le journal (`Ghost: …`).

## Corrections issues de la revue de fin de phase
- Un ghost resté d'un réveil non terminé est retiré avant toute nouvelle veille / tout nouveau réveil (sinon il restait par-dessus la nouvelle image).
- Pas de capture de ghost sous pression mémoire (`suspend(captureGhost: false)`) : chaque capture coûte jusqu'à ~1 s.
- Les liens d'ancre (`#section`) restent dans le fantôme au lieu d'être annulés.
- La boucle de neutralisation des animations a un budget de 300 ms (grosses pages).
- Non encore fait : chiffrement au repos (phase 6) — garder le flag éteint par défaut d'ici là.
- À vérifier : le process WebContent du fantôme reste-t-il vivant une fois le fantôme retiré ? (deux process subsistaient 20 s après ; attribution à confirmer.)

## Pièges rencontrés (à ne pas refaire)
- **Transitions parasites.** Sur IKEA, 82 % de la page apparaissait assombrie avec une bulle de chat visible pendant les 2 premières secondes, puis tout se corrigeait. Cause : les feuilles de style arrivent l'une après l'autre ; chaque changement de style déclenche une **transition** visible (un menu qui « se referme » à l'écran). Les animations n'y étaient pour rien (testé). Remède : transitions coupées (`<style data-oree-ghost-boot>`) jusqu'à 2,5 s après le chargement, puis retirées. IKEA : 82 % → 0 %.
- **Scroll visible.** Le fantôme doit être défilé **avant** d'être montré (révélation dans le callback de la restauration du scroll), sinon une frame au sommet de la page est visible.
- **`getAnimations()` ne rapporte pas** les animations déjà terminées sans remplissage : il faut aussi éteindre celles que l'élément nomme encore (`animation-name`).
- L'outil de capture de l'automatisation compose la WebView active : il **ne montre pas** la pile fantôme/image ; la fidélité se mesure donc avec `ui.sh ghost` (captures de chaque vue séparément).

## Mesures de réveil (cycle réel : veille → retour sur l'onglet, cache chaud)
| Page | Fantôme visible après | Vraie page prête après | Gain d'avance |
|---|---|---|---|
| GitHub | 392 ms | 773 ms | ≈ 380 ms |
| react.dev | 625 ms | 687 ms | ≈ 60 ms |
| Wikipédia | jamais avant la vraie page | 953 ms | 0 |

**Constat honnête** : créer un fantôme *au moment du clic* coûte 160 ms à 1,2 s (une WebView + un process WebContent + le chargement du HTML), c'est-à-dire autant que de recharger la vraie page depuis le cache (640–950 ms). Le fantôme n'apporte son bénéfice qu'avec le **préchargement au survol** (phase 4) et un fantôme prêt avant le clic ; l'image HEIC reste utile comme premier étage instantané.

## RAM
| Page | Process de la vraie page | Process du fantôme (affiché) |
|---|---|---|
| BBC | 113 Mo | 87 Mo |
| Wikipédia | 147 Mo | 148 Mo |
| GitHub | 72 Mo | 66 Mo |
| react.dev | 78 Mo | 87 Mo |
| IKEA | 219 Mo | 187 Mo |
| Stack Overflow | 320 Mo | 250 Mo |
| Next.js (vercel.com) | 166 Mo | 102 Mo |

Un fantôme **affiché** coûte presque autant qu'une page (le coût fixe d'un process WebContent domine). Le gain est **au repos** : une page hibernée ne pèse plus que ses octets compressés sur disque (8 à 177 Ko) au lieu de 50 à 320 Mo. Mesure approximative : empreinte du process (`phys_footprint`), le pool du fantôme pouvant contenir des restes des fantômes précédents.

## Limites connues (phase 1)
- Shadow DOM, canvas/WebGL, vidéo, iframes, `blob:` : phase 3.
- Éléments interactifs, sélection, texte tapé, clics pendant la restauration : phase 4.
- Un élément avec plusieurs animations CSS n'est pas rendu à l'identique.
- Les images **lazy** hors écran sont rendues eager : le fantôme peut en charger plus que la page.
- Pas encore de chiffrement au repos (phase 6) : les fichiers sont dans `Caches/Orée/Ghosts`, vidés au lancement et à la fermeture, jamais créés en navigation privée.

## Phase 2 — l'échange invisible (ghost → vraie page)

### Ce qui se passe au retour sur un onglet hibernié
Du bas vers le haut dans l'onglet : **vraie page** (restaurée à pleine opacité, dans la fenêtre) → **image HEIC** (ou, à défaut, la couleur de la page) → **fantôme**. Le fantôme n'apparaît qu'une fois peint et défilé.
Quand la vraie page « charge quelque chose », `Tab.hydrate()` prend le relais :
1. attend que la vraie page soit **prête** (`GhostScript.ready`) : document complet, polices chargées, images du viewport chargées, aucune mutation visible depuis 150 ms, puis deux frames d'animation ;
2. compare les blocs de texte visibles du fantôme et de la vraie page (tag + hash du texte + position, `GhostMatcher.similarity`) et **aligne le scroll** : le premier bloc visible du fantôme est retrouvé dans la vraie page, qui est décalée de l'écart (`GhostMatcher.scrollDelta`), ce qui évite tout saut si du contenu a été ajouté au-dessus ;
2bis. **si l'onglet est caché** (réveil au survol), garde le fantôme jusqu'à ce que l'onglet soit affiché (30 s au plus), puis vérifie que la vraie page dessine ses frames : un onglet caché n'en produit aucune, et l'échanger à ce moment ferait apparaître une page vide au clic ;
3. attend que WebKit ait présenté la frame de la vraie page (`_doAfterNextPresentationUpdate:`, API privée gardée par `responds(to:)`, repli 250 ms) ;
4. échange fantôme → vraie page dans **une seule transaction** `CATransaction` sans animation (alpha, image, fantôme retirés ensemble) ; puis un `mouseMoved` synthétique recalcule les `:hover`, et un lien cliqué dans le fantôme entre-temps est suivi.

Toute défaillance mène quand même à l'échange. Une page qui **charge encore** (pas `complete`) est attendue jusqu'à ~8 s (3 tours) : le fantôme est alors meilleur que la vraie page. Une page chargée qui ne cesse de muter (carrousels, trackers) est échangée après ~2,5 s.

### Pourquoi la vraie page n'est plus à `alpha 0`
Mesuré : une page dont la vue est à `alphaValue = 0` ne produit **aucune frame** pour WebKit (le script « prête » ne reçoit jamais ses `requestAnimationFrame`). La vraie page est donc créée à pleine opacité sous un calque opaque (image HEIC ou couleur de page).

### Limite de la mesure automatique (important)
L'instance de test est lancée en arrière-plan (`open -g`) : sa fenêtre est **masquée** pour macOS (`visible=false`), donc WebKit met la page en `visibilityState = hidden` et ne produit pas de frames (`ready=…/no-frames/…/hidden` dans les journaux). Dans cet état :
- le test « une frame peinte avant l'échange » **ne peut pas être validé** automatiquement (en fenêtre visible, deux sites l'ont montré : `painted/visible`) ;
- les minuteries sont ralenties, ce qui allonge certaines durées.
À confirmer avec une vraie fenêtre visible (voir « Comment tester l'échange »).

### Résultats (10 sites, `scripts/bench/ghost_swap_check.py`)
`écart` = % de pixels qui diffèrent entre ce que montre le fantôme et ce que montre la vraie page **juste avant** l'échange (0 % = rien ne bouge à l'écran). `durée` = temps de hand-over mesuré sans captures (`--timing`).

| Site | Écart au moment de l'échange | Durée de la phase fantôme | Blocs de texte identiques | Remarque |
|---|---|---|---|---|
| BBC | 3,4 % (une exécution à 0 %) | 0,9 s | 100 % | légers décalages de mise en page (publicités) |
| Wikipédia | 0,0 % (une exécution à 13,8 %) | 0,9 s | 95–100 % | résultat variable d'une exécution à l'autre |
| GitHub | 0,0 % | 0,8 s | 100 % | |
| react.dev | 0,0 % | 0,8 s | 100 % | |
| IKEA | 0,0 % | 3,8 s | 100 % | la page ne cesse de muter ; minuteries ralenties |
| MDN | 7,8 % | 2,1 s | 46–51 % | Shadow DOM (phase 3) ; scroll corrigé de 36 pt |
| Hacker News | 0,0 % | 0,6 s | 100 % | |
| Stack Overflow | 0,3–5,0 % | 2,7 s | 98 % | iframe Google (phase 3) |
| Next.js (vercel.com) | variable | 3,3 s → ~8 s | 16 % tant que la page charge | la vraie page est lente à se restaurer ; on attend |
| Tailwind | 0,0 % | 0,7 s | 100 % | |

Constat : sur 6 sites sur 10 rien ne bouge à l'écran au moment de l'échange (0,0 %). Les écarts restants viennent de pages qui ne se rechargent **pas à l'identique** (publicités, contenus variables), du Shadow DOM et des iframes (phase 3). Les durées de 2 à 4 s concernent des pages très animées, dans une fenêtre masquée.

### Revue de fin de phase 2
- **Corrigé** : échange pendant que l'onglet est caché (réveil au survol). Vérifié : après `ui.sh tab prewake 0` l'onglet reste caché 8 s sans échange ; après `tab select 0` l'échange suit (`shownAfter=8022ms`).
- **Ouvert** : (2) l'alignement du scroll s'accroche à un en-tête fixe (prendre le bloc du milieu de la fenêtre) ; (3) le journal affiche 100 % quand la comparaison a échoué ; (4) l'observateur de mutations relit la mise en page ; (5) `dumpSwap` à déplacer dans `Tab+GhostHarness.swift`.
- **Non vérifié** : `_doAfterNextPresentationUpdate:` et la frame réellement dessinée, en fenêtre visible ; la saisie au clavier pendant que le fantôme couvre l'onglet (elle va à la vraie page cachée dessous) — phase 4.

## Phase 3 — les contenus difficiles

### Ce qui a été construit
La capture ne tourne plus en monde isolé mais dans le **monde de la page** (`GhostBootstrap.swift`, script injecté à `documentStart` dans **toutes les frames**), parce qu'elle doit voir ce qu'un script isolé ne voit pas : les shadow roots **fermés** et les éléments qui ont de vrais écouteurs. Le point d'entrée `capture()` est exposé sous un nom aléatoire par lancement ; les crochets (`attachShadow`, `addEventListener`, `getContext`) gardent leurs notes dans des `WeakMap`/`WeakSet`, **sans toucher au DOM**.

| Cas | Traitement |
|---|---|
| Shadow DOM (ouvert, **fermé**, imbriqué) | `<template shadowrootmode="open">` déclaratif, récursif, avec `<style>` et feuilles adoptées du shadow root |
| Web components | la copie est faite dans un document **inerte** (`importNode`) : aucun élément personnalisé n'est construit, aucun script de la page ne tourne pendant la capture (en prime, 2 à 10 × plus rapide : Wikipédia 950 → 66 ms) |
| Canvas 2D | `toDataURL` en image |
| Canvas WebGL / vidéo cross-origin / DRM | **instantané du rectangle** de l'élément (`WKSnapshotConfiguration.rect`), inséré dans un espace réservé numéroté |
| Vidéo lisible | image JPEG de la frame courante (ou son `poster` hors écran) |
| Iframes | même origine : HTML lu directement ; **cross-origin** : l'app demande à la frame de se capturer elle-même (la frame s'annonce par un message, `WKFrameInfo` + `evaluateJavaScript(in: frame)`) ; le document est intégré dans l'iframe en URL `data:` |
| Images `blob:` | converties en URL `data:` |
| Images lazy | passées en eager **seulement dans l'écran** (les autres restent lazy : le fantôme ne charge pas toute la page) |
| Éléments interactifs | `data-oree-live` (écouteurs réels, boutons, rôles ARIA…) — prêt pour la phase 4 |

### Découvertes WebKit (à ne pas redécouvrir)
- **WebKit ignore l'attribut `srcdoc` quand JavaScript est coupé** : l'iframe reste `about:blank` (vérifié sur un cas minimal, `scripts` du spike). La spec initiale (réassembler en `srcdoc`) était donc fausse.
- Un **schéma d'URL personnalisé** (`WKURLSchemeHandler`) pour servir les frames échoue en silence sur les pages **https** : WebKit le bloque comme contenu mixte (le gestionnaire n'est jamais appelé), alors qu'il marche sur une page http de test. D'où les URL **`data:`**.
- Un iframe `data:` est chargé sans JavaScript et sans contenu mixte ; ses ressources relatives passent par le `<base>` de la frame.
- La capture dans le monde de la page expose un nom de fonction à la page (non devinable) ; une page pourrait théoriquement la falsifier, ce qui ne ferait que fausser **son propre** fantôme.

### Résultats
`scripts/bench/ghost_fixture_check.py` (hors ligne, **37 vérifications**) : vie privée et formulaires (16), web components (8), canvas 2D et WebGL (4), vidéos même origine et cross-origin (3), iframes même origine et cross-origin (4) — **toutes passent**, écart au pixel de 0,00 à 0,79 %.
`scripts/bench/ghost_check.py` (10 vrais sites) : **les 10 sites à 0,0 % d'écart** (MDN 8,0 % → 0,0 % grâce au Shadow DOM ; Stack Overflow 5,0 % → 0,0 % grâce aux iframes cross-origin).

| Site | Écart | HTML → compressé | Capture (avant → après) |
|---|---|---|---|
| BBC | 0,0 % | 287 → 42 Ko | 111 → 42 ms |
| Wikipédia | 0,0 % | 1 329 → 177 Ko | 947 → 66 ms |
| GitHub | 0,0 % | 178 → 24 Ko | 32 → 69 ms |
| react.dev | 0,0 % | 286 → 46 Ko | 112 → 58 ms |
| IKEA | 0,0 % | 672 → 184 Ko | 423 → 182 ms |
| MDN | 0,0 % | 790 → 69 Ko | 80 → 159 ms |
| Hacker News | 0,0 % | 61 → 10 Ko | 21 → 26 ms |
| Stack Overflow | 0,0 % | 1 246 → 144 Ko | 279 → 315 ms |
| vercel.com | 0,0 % | 1 929 → 62 Ko | 1 484 → 736 ms |
| Tailwind | 0,0 % | 185 → 17 Ko | 138 → 30 ms |

(MDN, GitHub et Stack Overflow capturent plus de contenu qu'avant : shadow roots, frames.)
Le cycle de réveil (`ghost_swap_check.py`) fonctionne toujours : l'alignement du scroll corrige par exemple 700 pt sur GitHub quand la vraie page ne retrouve pas sa position.

### Limites connues (phase 3)
- **Les crochets ne sont installés que sur les onglets créés quand le flag est actif** : un onglet ouvert avant l'activation du flag n'a pas de ghost (repli sur l'image).
- WebGL et vidéo non lisible : instantané seulement si l'élément est **dans l'écran** ; hors écran, une image vide ou le `poster`.
- Un canvas animé est figé sur sa dernière frame (le score de fidélité de la phase 5 le détectera).
- `addEventListener` est enveloppé : un site qui compare `addEventListener.toString()` à du code natif peut le remarquer (même remarque que pour les protections anti-empreinte existantes).
- Une même origine imbriquée sur plus de 3 niveaux, ou plus de 24 frames / 12 médias, n'est pas capturée.
- Un shadow root fermé est servi **ouvert** dans le fantôme (personne ne le script).

## Comment tester l'échange (fenêtre visible)
```
defaults write com.nolhan.hyperbrowser oree.hibernation.ghost -bool true   # ou lancer avec HB_GHOST=1
```
Ouvrez une page longue, défilez, allez sur un autre onglet, endormez le premier (clic droit → Mettre en veille, ou ⌥⌘E), revenez dessus. Le journal (`log stream --predicate 'subsystem == "com.nolhan.hyperbrowser" AND category == "tabs"' --info`) affiche `Ghost: swap after … — ready=ready/painted/…/visible text=… position=…`. `painted` + `visible` = la vraie page a bien produit ses frames avant l'échange.

## Phase 4 (en cours) — état de l'utilisateur, aucun signe visible
- **Aucun indice de veille dans l'interface** : plus de lune, de flocon, de titre grisé ni de favicon atténué sur les onglets (barre latérale, rail, aperçu des espaces) ; le compteur « N en veille » est retiré. L'état reste interne (préréveil au survol).
- **État transféré au moment de l'échange** (`GhostScript.readUserState` / `applyUserState`) : texte saisi et cases cochées (champs changés depuis l'affichage du fantôme, jamais les mots de passe), champ actif avec son curseur, texte sélectionné (`window.find`, approximatif si le texte se répète). Les valeurs passent par le setter natif puis `input`/`change` (React/Vue). Aller-retour vérifié sur une page de test ; **non vérifié** : sur de vraies pages avec framework, et avec une fenêtre visible.
- Le préchargement au survol de la barre latérale existe déjà (`prewake`). Pas de préchargement pour ⌃Tab (le changement est immédiat) : non fait.
- **Réveil silencieux** : tant qu'un onglet se réveille derrière son fantôme, ni barre de chargement en haut, ni anneau sur l'onglet, ni bouton « arrêter » (`Tab.showsLoading`).
- **Mesure continue** : `scripts/bench/invisible_check.py` (enregistreur dans l'app, un échantillon toutes les 8 ms : pile affichée, barre, anneau, bouton stop). Rapport et historique dans `scripts/bench/invisible-report.json`. Dernier relevé (5 sites) : 0 ms de barre, d'anneau, de bouton stop, d'image blanche ou de fondu ; échange en 0,7 à 2,1 s.
- **Échange plus tôt, sans saut** (12 oct.) : le fantôme part dès que la vraie page est complète, montre le même texte aux mêmes endroits et n'a pas bougé pendant ~200 ms (avant : attente de « rien ne bouge pendant 150 ms », jusqu'à 2,5 s sur les pages qui bougent toujours). Le défilement est recalé tout de suite si la vraie page ne l'a pas restauré. Le chargement du réveil reste silencieux après l'échange, jusqu'à sa fin ou jusqu'à ce que l'utilisateur aille ailleurs.
- Mesure (`invisible_check.py` mesure aussi, après l'échange : rechargements, saut de défilement, re-rendus) : 5 sites, 0 rechargement, 0 saut, 0 re-rendu ; échange en 1,3 à 3,5 s, MDN a mis 6,8 s lors d'un relevé sur deux (page qui se stabilise tard). Le fantôme reste affiché tout ce temps : non cliquable (pas de JS).
- **Onglets restaurés après un redémarrage** (analyse de deux enregistrements d'écran, 13 oct.) : sans image ni fantôme, un onglet qui se réveille montrait un écran vide (gris d'Orée 67 à 300 ms, blanc jusqu'à 1,4 s sur une page claire). Les images des onglets ouverts sont maintenant gardées d'un lancement à l'autre (`SnapshotVault` : chiffrées en ChaCha20-Poly1305, clé dans le Trousseau, nommées par un hachage de l'adresse, tout ce qui n'est plus un onglet ouvert est supprimé à chaque fermeture, jamais en navigation privée). Pas de fantôme (DOM) conservé : donc ces onglets se réveillent par l'image puis un fondu court, pas par l'échange invisible. Vérifié : tests du coffre ; **non vérifié de bout en bout** (relance réelle d'Orée avec des onglets restaurés).
- Reste : clics pendant la restauration (file puis rejeu), état dans les iframes.

## Suite
5. Score de fidélité ; gel noyau `SIGSTOP`/`SIGCONT` (flag `oree.hibernation.kernelFreeze`).
6. Chiffrement AES-GCM, banc automatique d'invisibilité.


## Réveil avec fantôme : mesures du 22 octobre 2026

Journal d'usage (Mac 8 Go en mode économie d'énergie, pression mémoire « warning » 68 % du temps) : un réveil par clic durait **1,0 s en médiane sans fantôme** et **7,4 s avec** (p90 9,8 s). Les réveils au survol ne comptent pas : ils incluent le temps avant que l'onglet soit regardé.
Instance d'essai sur machine au repos : 1,1 à 4,8 s (médiane ≈ 1,9 s). Sous charge (8 boucles actives) : médiane 2,9 s, maximum 8,9 s : la cause est le temps de chargement de la vraie page, que le fantôme attend (état « complete », puis 6 s de concordance au plus).

Correctif (`Tab.hydrate`) : une fois la page « interactive » ou « complete », elle n'attend plus que 1,5 s une concordance (avant : jusqu'à 6 s au total), puis 0,8 s de calme au lieu de 2,5 s. Une page encore en chargement garde son délai.
Sous charge : maximum 8,9 → 6,3 s, IKEA 7,8 → 5,7 s, MDN 8,9 → 5,6 s, médiane inchangée (2,9 s). Le saut visuel de l'échange ne s'aggrave pas (IKEA 5,1 → 3,5 %, MDN 0 %, Stack Overflow 32,9 → 5,5 % sur un essai ; un seul passage par site, donc bruité).

Mesurer : `OREE_TEST_APP=… python3 scripts/bench/ghost_swap_check.py --timing [url…]` (l'instance est lancée directement, avec des clés de test ; `HB_WAKE_REPORT=1` écrit le dernier réveil dans `/tmp/oree-wake.txt`, build de debug).
