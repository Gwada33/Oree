## 1.1.0 — 2026-10-12

- Site refait en histoire : une nuit à la lisière du bois, huit chapitres, Luciole qui vole d'une scène à l'autre, forêt et lucioles animées, démonstrations du sommeil des onglets, du panneau Luciole et des six teintes
- Panneau Luciole refait d'après le design : mascotte à treize poses, carte de validation, trace d'actions, Luciole qui vole jusqu'à l'élément qu'elle manipule, fenêtre qui reste dans l'écran, réglages de l'assistant et des boutons
- Luciole se souvient : discussions rouvrables et journal de ses actions, sur ce Mac seulement, sans jamais garder ce que vous saisissez dans les formulaires
- Luciole peut utiliser Mistral, Groq ou LM Studio (modèles lus depuis son API locale), avec de vrais appels d'outils, des réponses qui s'écrivent en direct et plusieurs actions enchaînées en un seul tour
- Moins de plantages quand on agit vite sur un site : les scripts d'une page qui se ferme ou s'endort sont rattrapés, la bulle de correction orthographique des pages web est désactivée par défaut
- Panneau Luciole : l'assistant IA s'ouvre à droite (⌘J), avec la trace des actions, les cartes à valider, la mascotte, et les boutons personnalisables dans la fenêtre
- Barre d'outils et barre latérale : disposition des boutons personnalisable (emplacement, ordre, taille, boutons toujours à leur place)
- IA locale : Orée sait lire une page et agir dessus (carte de page, gestes sûrs, boucle d'agent, recherche cachée)
- IA locale : le service charge désormais Qwen3.5-4B, plus cohérent que le 2B (plus lourd et plus lent)
- IA locale : le service ne s'arrête plus en pleine réponse quand le Mac manque de mémoire
- IA locale : préparation du LoRA (licences des données, coût du professeur en nuage, entraînement)
- IA locale : le modèle de base appelle les outils à 100 % de formes valides avec une grammaire, mais choisit juste 17 fois sur 26
- IA locale : prompt de conception du panneau latéral IA (pour Claude Design)
- IA locale : barre IA (⌘J) branchée au service, téléchargement du modèle avec accord, Stop
- Téléchargeur : le dossier des modèles de l'IA locale est autorisé
- IA locale : mesures de l'étape 1 sur Mac M1 8 Go, vérification du modèle sans pic de mémoire, essai de bout en bout par XPC
- IA locale : le service charge Qwen3.5-2B avec llama.cpp et répond en français ; installé avec l'app
- IA locale : états chaud, tiède et froid, vérification du modèle avant chargement, service accessible à Orée seul
- IA locale : le contrat du service (protocole XPC, événements, états de veille) est publié pour le navigateur
- IA locale : précise que le dossier OreeAI du contrat désigne les cibles OreeAIProtocol et OreeAIService
- IA locale : prompt de la session « IA » (étape 1, le cerveau seul)
- IA locale : contrat entre les deux sessions, feuille de route en cinq étapes et pièges connus (Docs/ia.md)
- Note interne : la comparaison avec Safari et Brave existe, avec sa méthode, sa date et ses limites
- Site : vraies captures, polices woff2 (−60 %), aperçu de partage complet, instructions d'installation macOS 15

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

