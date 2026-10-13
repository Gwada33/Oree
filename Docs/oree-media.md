# Lecture en cours (carte de la barre latérale)

Quand une page joue une vidéo ou un son, une carte apparaît en bas de la barre latérale, comme dans Arc : couverture (ou icône du site), titre, artiste ou site,
barre de position cliquable, ±10 s, lecture/pause, image dans l'image (si c'est une vidéo) et la sortie audio avec la batterie du casque quand il en donne une.
Un clic sur le titre ramène à l'onglet. La carte disparaît quand la page change, que l'onglet s'endort ou se ferme, ou que le média n'a jamais démarré.

## Comment ça marche
- `MediaScript` (monde isolé `oree-media`, cadre principal) lit les `<video>` / `<audio>`, préfère celui qui joue puis le plus long, et reprend titre, artiste et couverture de la
  Media Session de la page. Rapport à chaque changement d'état, et au plus une fois par seconde pour la position. Un minuteur de 2,5 s ne tourne que tant qu'un média existe.
- La décision d'afficher est dans `MediaPolicy` (BrowserCore, testée) : pas de carte pour un son de moins de 20 s ni pour un média jamais lancé.
- Commandes : lecture, pause, position, ±10 s, par `callAsyncJavaScript` dans le même monde.
- **Image dans l'image** : l'interrupteur de WebKit (`_togglePictureInPicture`, API privée gardée par `responds(to:)`), qui ne demande pas de geste de l'utilisateur ; repli sur
  `requestPictureInPicture()` de la page (qui, elle, exige un geste).
- **Sortie audio** : CoreAudio (suit les changements). **Batterie** : pas d'API publique ; lue dans `system_profiler SPBluetoothDataType -json` (toutes les 2 min tant que la carte est
  affichée avec une sortie Bluetooth). Elle n'apparaît que si l'appareil la déclare (AirPods oui, beaucoup de casques non).
- Couverture : téléchargée une fois par adresse (https seulement), jamais pour un onglet privé.

## Limites
- Un lecteur dans une **iframe** (vidéo intégrée) n'est pas vu : seul le cadre principal l'est.
- Pas de « piste suivante / précédente » : une page ne laisse pas un autre script appeler ses actions Media Session.
- **Image dans l'image et batterie non vérifiées sur un vrai écran** : dans la fenêtre de test (cachée), WebKit répond `_canTogglePictureInPicture = false`, et aucun appareil Bluetooth n'était connecté.
- Les mesures de la carte (affichage, pause, saut, position, disparition au changement de page, lecture dans un autre onglet) ont été faites sur une vidéo locale, pas sur YouTube ou Spotify.

## Tester
Ouvrir une page avec une vidéo, la lancer ; `scripts/ui.sh tab media 0` donne ce que montre la carte ; `tab mediatoggle|mediaskip|mediaseek|mediapip 0` commandent la lecture.
