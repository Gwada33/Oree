# Publier une version

Tout part d'une commande. Le reste (construction, zip, DMG, release GitHub, site, mise à jour des copies installées) est automatique.

## À la main
```
./scripts/release.sh patch          # 1.0.2 → 1.0.3   (ou : minor, major, ou un numéro précis : 1.2.0)
./scripts/release.sh patch --dry-run   # affiche la version et les notes, ne change rien
./scripts/release.sh patch --skip-tests
```
Le script vérifie (arbre propre, branche main, tests), écrit `VERSION` et `CHANGELOG.md`, commit « Version X », crée le tag annoté `vX.Y.Z`
(les notes sont les sujets des commits depuis la dernière version) et pousse. GitHub Actions fait le reste.

## Planifié
`.github/workflows/scheduled-release.yml` tourne **chaque vendredi à 16:00 UTC** : s'il y a au moins **3 changements** depuis la dernière version
et que les tests de `main` passent, il publie une version « patch » tout seul. Pour changer le moment, modifiez la ligne `cron`.
À la demande : GitHub → Actions → « App — publication planifiée » → Run workflow (type de version, minimum de changements, ou « force »).

## Ce que produit une release (`release.yml`)
| Fichier | Pour qui |
|---|---|
| `Oree-macOS-arm64.dmg` (+ `.sha256`) | premier téléchargement : le site pointe vers `releases/latest/download/Oree-macOS-arm64.dmg` |
| `Oree-macOS-arm64.zip` (+ `.sha256`) | mise à jour intégrée : Orée le télécharge, vérifie son empreinte SHA-256, remplace l'app et se relance |

Le site affiche le numéro, la date et la taille de la dernière version en lisant l'API GitHub (rien à redéployer).
Les copies installées vérifient une fois par jour (ou via « Rechercher des mises à jour… ») et proposent l'installation, avec les notes.

## Si ça ne part pas
- Les tests échouent → `./scripts/test.sh`.
- Le flux planifié ne peut pas pousser sur `main` → une protection de branche l'en empêche (autorisez « github-actions » ou publiez à la main).
- Republier un tag existant : Actions → « App — publier une version » → Run workflow avec le tag.
