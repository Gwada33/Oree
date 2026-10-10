# Mode nuit universel

Assombrit les sites, y compris ceux qui n'ont aucun thème sombre. Réglages › Mode nuit des sites : **Jamais** (par défaut),
**Automatique** (quand Orée est en mode sombre, donc quand le Mac l'est sauf réglage contraire), **Toujours**. Une icône en forme
de lune dans la barre d'outils laisse le site courant clair (ou le ré-assombrit) d'un clic ; la palette ⌘K propose aussi
« Mode nuit : toujours / automatique / désactivé » et « ce site clair ou sombre ».

## Comment ça marche

- La racine de la page reçoit `filter: invert(1) hue-rotate(180deg) contrast(.85)` : le blanc devient gris très sombre, les teintes
  restent reconnaissables (un lien bleu reste bleu clair). Le filtre est sur `<html>`, ce qui garde `position: fixed` intact.
- **Remis à l'endroit** (filtre inverse) : images ≥ 64 pt, vidéos, canvas, lecteurs YouTube/Vimeo/Twitch/Dailymotion, et tout
  élément à grande image de fond (≥ 6 400 pt², repéré par `getComputedStyle`, par tranches de 8 ms au repos). Jamais deux fois sur
  des éléments imbriqués.
- **Laissées inversées** : les petites images (icônes et logos dessinés pour fond clair).
- **Sites déjà sombres** : une fois la page chargée, le script lit la vraie couleur de fond ; si elle est sombre il se retire et
  prévient l'app, qui mémorise le site (300 entrées au plus). Dès la visite suivante, aucun filtre ni flash. **La toute première
  visite d'un tel site peut montrer un bref éclair clair.**
- Pages de l'app (`oree://`), images et vidéos seules : jamais touchées. Iframes : inversées avec leur parent.
- Monde JavaScript isolé `oree-night` (la page ne le voit pas), image principale seulement.

## Limites

- Couleurs **très saturées** dans les images (rouge pur, par exemple) : le retour à l'endroit passe par un tronquage et peut les
  ternir (un rouge pur 220,0,0 sort à ≈150,70,70 ; un brique 200,90,60 ou une photo normale reste dans ±10). Même limite que
  Dark Reader en mode filtre.
- Night Shift (température de couleur) n'est pas accessible aux applications : « automatique » suit l'apparence claire/sombre.
- Les petites images noires sur fond transparent deviennent claires (voulu) ; une illustration moyenne à fond transparent dessinée
  pour fond clair peut rester sombre sur sombre.
- Image de fond dans une feuille de style appliquée après la mesure : repérée au prochain passage au repos (quelques centaines de ms).
- Coût : un calque filtré pour toute la page (GPU) ; non mesuré sur batterie.

## Tester

```
./build_app.sh --debug
python3 scripts/bench/night_check.py     # 14 vérifications, instance séparée en mode « toujours » (HB_NIGHT=always)
scripts/test.sh --fast                   # NightModeTests
```
Le script remet en l'état les deux listes de sites qu'il apprend (exclus / déjà sombres).
