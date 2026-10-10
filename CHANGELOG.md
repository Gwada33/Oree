## 1.0.5 — 2026-10-10

- Site : nouvelle section « Sur la page », questions sur les fonctions avec IA, palette ⌘K
- Sur la page : traduction, L'essentiel (recettes), Boosts et mode calme, Calendrier, mode nuit, copier-coller propre, reprise
- Builds et tests locaux plus rapides : build_app.sh --debug, tests sans le moteur de téléchargement
- Vidéos en plein écran : cause probable de l'écran noir corrigée (la vue web ne pouvait plus tomber à 0 × 0), à confirmer
- Hibernation fantôme, phase 3 : Shadow DOM, canvas, vidéos, iframes, images différées

## 1.0.4 — 2026-10-10

- release.sh : option --no-push
- Hibernation fantôme, phase 2 : échange ghost → vraie page en une transaction, alignement du scroll, attente de l'onglet affiché
- Hibernation fantôme, phase 1 : sérialiseur, stockage zstd (Rust), affichage JS coupé, derrière le flag oree.hibernation.ghost

## 1.0.3 — 2026-10-10

- Publication de bout en bout : scripts/release.sh (patch/minor/major, notes auto, CHANGELOG), release.yml (zip + DMG), publication planifiée, site vers le dernier DMG
- Corrections de l'audit : onglets privés jamais sauvegardés ni capturés, protections par site stables, veille sans blocage, mise à jour vérifiée par SHA-256, réactions aux réglages groupées
- DMG avec image de fond (dmgbuild), construit et publié par la CI

