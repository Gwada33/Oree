# Hibernation invisible d'Orée — « Fantôme + Hydratation »

Statut : **phase 1 terminée** (derrière le flag `oree.hibernation.ghost`, désactivé par défaut). Phases 2 à 6 : voir « Suite ».

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
| BrowserUI | `GhostScript.swift` | script de capture (monde `oree-ghost`), restauration du scroll |
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

## Suite
2. Échange invisible en une frame (API privée gardée `_doAfterNextPresentationUpdate:`) ; image HEIC → fantôme → vraie page.
3. Contenus difficiles (Shadow DOM, canvas, vidéos, iframes).
4. Transfert de l'état utilisateur ; **préchargement au survol** (condition du bénéfice de réveil).
5. Score de fidélité ; gel noyau `SIGSTOP`/`SIGCONT` (flag `oree.hibernation.kernelFreeze`).
6. Chiffrement AES-GCM, banc automatique d'invisibilité.
