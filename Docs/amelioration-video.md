# Agrandissement des vidéos (expérimental)

Réglages › Qualité des vidéos : « Agrandir d'office les vidéos de basse résolution » (éteint par défaut), netteté douce, normale (défaut) ou forte. Éteint, le choix se fait vidéo par vidéo : clic droit › **Améliorer cette vidéo (320×180 → 1920×1080)** / **Revenir à la vidéo d'origine**.

## Ce que c'est (et ce que ce n'est pas)

Dans la page (et ses iframes), un script en monde isolé (`VideoUpscaleScript`) copie chaque image de la vidéo dans une texture WebGL, l'agrandit en **bicubique Catmull-Rom**, puis applique le **CAS** de FidelityFX (netteté adaptative au contraste), et affiche le résultat dans un canevas posé sur la vidéo (`pointer-events: none` : les commandes du lecteur restent cliquables).
**Ce n'est pas de l'IA** : les contours deviennent plus nets, aucun détail absent de la source n'est inventé. Un flux déjà écrasé reste écrasé.

## Mesures (`scripts/bench/upscale_check.py`, 22 octobre 2026)

Cinq images 1920×1080 (quatre morceaux d'une photo aérienne du système, une capture d'interface avec du texte) réduites en 960×540 puis agrandies ×2 par le moteur dans Orée ; ffmpeg compare à l'original. « Netteté » : variance du laplacien ÷ celle de l'original (1,0 = autant de contours).

| Source propre | PSNR | SSIM | Netteté |
|---|---|---|---|
| Navigateur (bilinéaire) | 41,15 dB | 0,977 | 0,30 |
| Bicubique | 43,44 | 0,986 | 0,45 |
| Bicubique + netteté 0,3 | **43,92** | **0,987** | 0,72 |
| Bicubique + netteté 0,6 | 43,68 | 0,986 | 0,82 |
| Bicubique + netteté 0,9 | 42,47 | 0,981 | 1,15 |

| Source compressée (x264 CRF 28, comme un flux) | PSNR | SSIM | Netteté |
|---|---|---|---|
| Navigateur (bilinéaire) | 34,01 | 0,881 | 0,23 |
| Bicubique | **34,19** | **0,882** | 0,32 |
| Bicubique + netteté 0,3 | 34,10 | 0,879 | 0,51 |
| Bicubique + netteté 0,6 | 34,04 | 0,878 | 0,58 |
| Bicubique + netteté 0,9 | 33,85 | 0,873 | 0,79 |

Lecture : sur une source propre, le gain est net (+2,8 dB, netteté ×2,4). Sur un flux compressé, la **fidélité mesurée ne change presque pas** (±0,2 dB) : l'image paraît plus nette (netteté ×2) mais la netteté accentue aussi les défauts de compression, d'où le défaut à 0,4 et le choix « douce ».
Coût : 8 à 35 ms par image 1080p selon la charge de la machine (mesure bruitée, Mac en mode économie d'énergie) : à la limite de 30 images/s sur un Mac chargé.

## Garde-fous

- Seules les vidéos lues, d'au moins 320×180, **plus petites que leur affichage** sont touchées ; pas en plein écran natif.
- Une vidéo qu'un autre site sert sans CORS ou protégée par DRM n'est pas lisible par WebGL : le script le constate (`SecurityError`), laisse la vidéo telle quelle et le dit dans le menu.
- Si plus de 12 % des images sont perdues après 4 s, l'agrandissement s'arrête tout seul (« trop lourde pour ce Mac »).
- La sortie est plafonnée à 1920×1080.

## Limites

- Mesures sur des **images fixes**, pas sur une vraie vidéo : le scintillement d'une image à l'autre n'est pas mesuré. Aucune mesure sur un vrai flux en direct.
- Le canevas est inséré après la `<video>` dans le DOM de la page ; un lecteur qui masque ou remplace sa vidéo peut le cacher.
- Les lecteurs en iframe sont pris en compte, le clic droit retrouve le cadre qui a signalé sa vidéo.
- Pas de réglage par site ni de réglage de la netteté vidéo par vidéo.

## Tester

```
OREE_TEST_APP=… python3 scripts/bench/upscale_check.py        # qualité sur des images de référence
OREE_TEST_APP=… python3 scripts/bench/video_upscale_check.py  # repérage, bascule, mode auto, vidéo d'une autre origine (7 vérifications)
```


## Le moteur Apple (par apprentissage), branché dans Orée

Réglages › Qualité des vidéos › Moteur : **Apple** (par défaut, macOS 26 ou plus) ou **Filtre** (bicubique + netteté, ci-dessus). Sans macOS 26, ou pour une source hors de 96×96 à 1280×1280, Orée revient seul au filtre.

### Mesures de qualité (22 octobre 2026, `scripts/bench/upscale_check.py` avec `OREE_VTSR`)

`VTLowLatencySuperResolutionScaler` : agrandisseur par apprentissage de macOS, conçu pour le temps réel. Mêmes images que ci-dessus (×2, 960×540 → 1920×1080) :

| Source compressée | PSNR | SSIM | Netteté |
|---|---|---|---|
| Bicubique + netteté 0,3 (filtre) | 34,10 | 0,879 | 0,51 |
| **Apple** | 32,73 | 0,880 | **0,84** |

| Source propre | PSNR | SSIM | Netteté |
|---|---|---|---|
| Bicubique + netteté 0,3 (filtre) | 43,92 | 0,987 | 0,72 |
| **Apple** | 35,94 | 0,950 | 1,28 |

À l'œil (`comparaison-agrandissement.png`) : texte et icônes nettement plus lisibles qu'avec le filtre ; sur une photo, des contours plus nets mais l'original garde bien plus de texture. **Le modèle invente des contours plausibles** (PSNR plus bas ; netteté > 1 = contours plus marqués que l'original).

### Comment c'est branché

1. Le script de la page (monde isolé) recopie chaque image de la vidéo dans un canevas, l'encode en JPEG (qualité 0,95) et l'envoie à Orée en base64. **Les messages de WebKit ne peuvent pas porter de binaire** (un `ArrayBuffer` arrive vide, un `Uint8Array` arrive comme un dictionnaire d'un million d'entrées) : d'où le JPEG en texte, ~17 Ko à 320×180, ~57 Ko à 640×360, ~109 Ko à 960×540.
2. `SuperResolutionEngine` (acteur) décode le JPEG, le convertit en YUV 4:2:0, l'agrandit ×2 avec l'API d'Apple (trois tampons de sortie en rotation) ; si le moteur est occupé, la plus ancienne image en attente est abandonnée.
3. `VideoEnhancer` affiche le résultat dans une `AVSampleBufferDisplayLayer`, dans une vue posée par-dessus la page (`EnhancerView`, qui laisse passer la souris), à l'emplacement que le script donne (ses coordonnées + le décalage de ses iframes parentes, calculé de proche en proche par `postMessage`). Si plus aucune image n'arrive pendant 0,3 s (pause, onglet caché), la vue se cache et la vidéo d'origine reprend la place.

### Mesures du moteur branché (`scripts/bench/video_upscale_check.py`, 23 vérifications)

- Agrandissement : **1,9 ms par image** (320×180 → 640×360). Décodage JPEG + conversion : ~5 ms. **Délai de bout en bout côté natif : 7 ms** ; 150 images rejouées à 30 images/s : 150 agrandies, 0 perdue.
- Côté page (copie + JPEG + base64), mesuré sans minuteur : **4,4 ms** à 320×180, **7,7 ms** à 640×360, **9,9 ms** à 960×540 : de quoi tenir 60 images/s jusqu'en 540p, au prix d'une bonne part du fil principal de la page.
- Position : la vue couvre la vidéo à 960×540 à 20 px du bord ; dans une iframe à (100, 60) + vidéo à (20, 20), elle est à (120, 80).

### Limites

- Mesure du délai total (page → écran) : ~25 ms estimés (≈ 10 ms page + 7 ms natif + affichage), non mesurés de bout en bout ; au-dessus de ~45 ms le décalage image/son se verrait.
- La page d'essai est cachée (fenêtre invisible) : ses minuteurs sont freinés, donc la cadence réelle à 30 ou 60 images/s côté page n'est **pas** mesurée sur un vrai lecteur ; la chaîne native, elle, l'est (images rejouées).
- Mêmes refus que le filtre : autre origine sans CORS, DRM.
- Le résultat s'affiche par-dessus la vidéo : un lecteur qui dessine des sous-titres ou une barre de commandes dans le même plan reste dessous (les commandes cliquables restent cliquables, la vue ne prend pas la souris, mais elles peuvent être cachées visuellement). À vérifier sur de vrais lecteurs.
- Plein écran natif de la vidéo : non géré (la vue n'y est pas).
