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
