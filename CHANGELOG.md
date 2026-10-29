## 1.1.2 — 2026-10-29

- Trois petits points : remis une fois dans la barre d'outils s'ils avaient été masqués (disposition enregistrée avant le menu)
- Menu des trois petits points (à la Chrome) : onglets, favoris, outils de la page, zoom, applications, Luciole, réglages ; ⌘K reste la palette
- Applications indépendantes : programme à elles (OreeWebApp), dernière image et session restaurées, reste en mémoire, blocage natif WebKit (règles converties par Rust à l'installation), notifications, pastille, téléchargements natifs
- Applications : un site devient une application (fenêtre sans onglets, raccourci Nom.app avec icône dans le Dock, oree-app://) ; messagerie native : port accepté tout de suite
- Luciole et instantanés : plus d'écriture avec .completeFileProtection (refusée par macOS 27.2 : la mémoire de Luciole n'était plus enregistrée)
- Extensions : raccourcis clavier, grosses extensions (clic), débogueur retrouvé par identifiant, polyfills (getURL, requestIdleCallback, webRequest), documentation
- Extensions : downloads, messagerie native (hôtes des navigateurs Chrome, avec accord de l'utilisateur), windows.create, essais
- Extensions : identifiant Chrome (clé du manifeste), redirection OAuth chrome-extension://, service worker chargé dans une page de fond persistante, énumérations, en-têtes DNR émulés, journal de diagnostic
- Extensions : notifications, panneau latéral, page cachée, management, idle, power, system, browsingData, search, tts, identity (redirection), raccourcis
- Extensions : history, bookmarks, topSites, sessions, readingList et chrome.debugger (protocole de débogage traduit en actions sur l'onglet) par le pont natif
- Extensions : script de compatibilité (privacy, tabGroups, declarativeContent, identity, réglages, API honnêtes), pont natif vers l'app, banc
- Extensions : fenêtre déclarée au moteur, popup attendu puis dimensionné, réglages (pages d'extension débloquées, clic droit, Réglages), banc de 5 extensions
- Extensions : le popup demande d'abord sa vue web, et dit pourquoi il ne s'ouvre pas au lieu de rester muet
- Barre d'adresse : Entrée ouvre l'adresse complétée en ligne, pas la 1re suggestion de ce qui était tapé
- Préconnexion au survol des liens (délais par genre de lien tirés du journal) ; veille : un onglet doit être inactif 60 s avant d'être endormi par le budget
- Plantages macOS 27.2 : hitTest constants et survol de SurfaceView sans contrôle d'exécuteur
- Plantages : isFlipped sans contrôle d'exécuteur ; les réglages ne rechargent plus que l'accueil (pas La Rime)
- La Rime : histoires qui se suivent, rimes à plusieurs syllabes, structure de la prod (mesures sans beat posées plus lentement)
- La Rime : jeu de freestyle (4 cases par mesure, la rime dans la 4e, balle Luciole), beat d'Orée ou prod de l'utilisateur avec tempo détecté ou réglé à la main, accessible depuis l'accueil et ⌘K
- Ouverture : mesure avec un vrai site contre Safari, Brave et Firefox (0,70 s contre 1,11 à 1,73 s), écoute audio reportée après l'affichage de la fenêtre
- Sécurité et licences : photo de l'accueil réservée aux pages d'Orée, liens web seulement, mentions de licences embarquées et bouton À propos, état documenté
- Plantages macOS 27 bêta : assumeIsolated remplacé par une vérification Dispatch (80 usages), relevé des 13 rapports
- Widgets : création par le modèle local (structure seulement, aperçu obligatoire), retrait par clic droit, documentation
- Widgets de la barre latérale : pastilles lues sur les onglets ouverts (titre, nombre d'éléments, texte), Gmail fourni, règles de sécurité testées
- Interface : accueil avec état vide des favoris et accent unifié, tiroir Personnaliser aligné, raccourci ⌘L au survol, dates de la palette en français, boutons Modifier lisibles
- WebKit : image dans l'image pour les vidéos, code QR dans le menu des images, adresse du lien et texte tronqué dans les infobulles
- Banc : réglages numériques de configuration WebKit (délai de rendu), mesuré au premier affichage de contenu, rien de retenu
- WebKitTuning : liste de propriétés vide, sans condition inutile
- Banc A/B des réglages privés du pool WebKit et des préférences (aucun retenu : ils coûtent de la mémoire ou ne gagnent rien)
- WebKit : réglages internes de vitesse et de confort activés (préchargement, animations hors fil principal, API récentes), coupables dans Réglages
- Agrandissement des vidéos : s'arrête sur une image protégée (noire) au lieu de la cacher, bancs sur flux HLS réel
- Agrandissement des vidéos : plus d'écran vert au démarrage, la vue suit la page en plein écran
- Agrandissement des vidéos : moteur Apple (apprentissage) affiché par-dessus la vidéo, iframes prises en compte, mesures de bout en bout
- Agrandissement : mesure de l'upscaler d'Apple (VideoToolbox) dans le banc de qualité
- Agrandissement des vidéos : bicubique + netteté (WebGL), clic droit, réglage, garde-fous, bancs de mesure
- Luciole peut répondre par Claude Code (claude -p) : fournisseur sans clé, outils décrits et gardes-fous inchangés
- Fantôme : l'échange n'attend plus que 1,5 s une fois la page prête (interactive ou complète) ; banc de réveil mesuré directement
- Journal : le banc de rejeu peut tester sur des sites jamais vus (--sites)
- Journal : banc de rejeu du préchargement des liens (règle contre petit modèle)
- Trousseau : savoir si une clé existe sans la lire (plus de gel de 6 à 8 s à la première ouverture de Luciole)
- Luciole : mémoire ambiante et outil recall, contexte gardé entre les messages, liens cliquables, cartes qui évitent le contenu, vol d'arrivée visible, champs centrés, sous-titre retiré
- Luciole : une seule mascotte qui vole (départ animé, ⌘J animé dès la première ouverture), gestes de sélection au clic droit, barre d'outils réduite à Luciole
- Luciole dans la page (fin) : états du modèle, repos dans la barre d'outils avec bulle de fin, pages protégées, doc et fiche marketing
- Luciole dans la page (étape 3) : validation avec voile, trou et anneau, carte dense, question, chemin d'actions et pastille « Arrêter » ; affichage dans la page par défaut
- Luciole dans la page (étape 2) : sélection, éventail Expliquer/Traduire/Garder, réponse ancrée avec surlignage et fil de lumière
- Luciole dans la page (étape 1) : couche de verre au-dessus de la page, capsule d'appel, suggestions, bulle de réponse, et repli vers le panneau pour les validations
- Luciole : cinq nouveaux outils (retour, historique, calcul, note, attente) et réponses en Markdown, avec « Ouvrir en page »
- Agent : adresses inconnues soumises à accord, valeurs personnelles inventées refusées, suppressions confirmées, banc de 20 scénarios
- LM Studio sur le réseau : message d'erreur précis, délai plus long et autorisation « Réseau local » demandée
- Petits modèles : références tolérantes aux parasites et adresses à ouvrir limitées à celles de la demande
- Inspecteur web : s'ouvre enfin, dans sa propre fenêtre
- Clic droit : copier tous les médias, copier la page entière, inspecter l'élément

## 1.1.1 — 2026-10-23

- Site : refonte complète du site vitrine (direction « la lisière »)
- Fiche marketing : 2FA, audit, adresses, cartes, profils, gestes, Dock, Spotlight et le reste
- AirPlay explicite, tableau de parité mis à jour et fiche des outils du quotidien
- Profils : un Orée par profil, avec ses cookies, son historique et ses mots de passe
- Gestes de souris : bouton droit enfoncé, on trace, on relâche
- Refus automatique des bannières de cookies
- Mode responsive : la page dans la taille et l'identité d'un iPhone, d'un iPad ou d'un écran
- Intégrations Mac : menu du Dock, menu Services, Spotlight
- Remplissage automatique des adresses et des cartes bancaires
- Codes 2FA remplis dans les pages, export CSV, contrôle de santé des mots de passe ; le journal ne gèle plus l'interface quand le Trousseau demande l'accès
- Mots de passe : codes 2FA (TOTP, RFC 6238), contrôle de santé, export CSV (briques testées)
- Journal d'événements : une mesure fine, chiffrée et locale de la façon dont on se sert d'Orée
- Journal d'événements : schéma fermé, empreintes de sites, stockage chiffré par jour (tests)
- Précisions sur les mesures de l'IA
- Documentation de l'optimisation de l'IA ; anciens documents du service local archivés
- Luciole : pose qui suit les vrais événements, cadre qui s'efface, attente de débit visible ; essais bornés par route
- IA : routage, requêtes avec relance intelligente, registre des actions, conversation gardée, suppression de l'IA locale
- IA : briques pures de routage, relances, tri des recherches, cache, registre des actions (testées)
- Mesure du coût des tâches de Luciole : requêtes, jetons comptés par le fournisseur, contexte, recherches, relances
- Construction de la fenêtre découpée, et liste d'onglets 70 fois plus rapide quand rien ne change
- Contrôleur principal : 1 000 lignes au lieu de 5 342, et sauvegarde de session regroupée
- Contrôleur principal découpé : 5 342 → 3 384 lignes
- Les commandes de développement ne partent plus dans l'app livrée
- Panneaux web : une application web gardée à droite de la page
- Notes intégrées : un bloc-notes sous la barre d'adresse
- Archivage automatique des onglets inutilisés
- Onglets : glisser-déposer et fermeture avec des ressorts, comme les listes du système
- Barre d'onglets : tous les onglets restent accessibles, même à 30
- Aperçu d'un lien (Peek) : voir une page sans quitter celle qu'on lit
- Mini-fenêtre flottante : un coup d'œil sans quitter ce qu'on fait
- Aperçu d'un onglet au survol : image de la page, titre, site et mémoire
- Version mobile d'un site, partager la page, lire à voix haute, mode économie d'énergie
- Gestionnaire de tâches (⌥⌘T) : la mémoire de chaque onglet, avec mise en veille et fermeture
- Fonctions simples : Global Privacy Control, effacer à la fermeture, code QR, texte minimal, calculatrice, ⌃Tab
- Vitesse de lecture sur la carte « Lecture en cours » et touches multimédia du clavier
- Plantage au téléchargement d'un fichier créé par la page (« Exporter »), et message perdu par les fenêtres de connexion qui se ferment
- Zoom de la page (⌘+ ⌘− ⌘0), mémorisé par site, et pincer pour zoomer
- Liens d'autres applications et mots de passe demandés par un site, qui n'étaient pas gérés
- Les fenêtres ouvertes avec ⌘N reviennent au lancement suivant (et celles qu'on ferme ne reviennent pas)
- Fenêtres des pages réparées : choisir un fichier à envoyer, alert(), confirm(), prompt() et window.close()
- Déplacer un onglet vers une nouvelle fenêtre (menu contextuel) : la page reste vivante
- Nouvelle fenêtre (⌘N) : une seconde fenêtre avec ses propres onglets
- Mode lecture (⇧⌘R) : l'article de la page seul, sans menus, publicités, commentaires ni scripts
- Barre d'adresse : complétion en ligne (« gith » → github.com, « fr.wikipedia.org/wiki/L » → …/Lisbonne)
- Informations sur le site : un clic sur le cadenas montre la connexion, le certificat, les cookies et les autorisations
- Compatibilité et favoris : user-agent au choix (Safari, Chrome, Firefox, personnalisé, ou Chrome pour certains sites), export des favoris en HTML, tous les onglets en favoris, fermer les onglets en dessous
- Liste de parité : rappel des ajouts du jour
- Recherche : huit moteurs, mots-clés (« w Lisbonne », « yt chats », « gh swift »…) et les tiens ; dossier de téléchargement au choix
- Imprimer (⌘P), enregistrer la page en PDF (⇧⌘S) et afficher le code source (⌥⌘U)
- Liste des fonctions des autres navigateurs et de leur état dans Orée (inventaire du code, pas un test d'usage)
- Corrections : batterie du casque et couvertures sans doublons, panneau de correction orthographique protégé, veille qui ne reste plus affichée sur les pages qui bougent
- Carte « Lecture en cours » dans la barre latérale : contrôle de la vidéo ou du son, image dans l'image, sortie audio et batterie du casque
- Onglets restaurés : l'image de chaque onglet est gardée (chiffrée) d'un lancement à l'autre, fin de l'écran vide au premier réveil
- Veille : l'échange attend qu'une vraie image de la page soit affichée (fin des ~250 ms de noir)
- Veille invisible, installation d'extensions du Chrome Web Store et bouton « Nouvel onglet » après le dernier onglet
- « Reprendre où tu en étais » ne s'offre plus que sur les articles
- Plantages corrigés : exception de WebKit pendant un script, et base de données impossible à ouvrir
- Site : la fin « Bonne route » devient une aube, avec un grand bouton de téléchargement
- Site : la forêt laisse place à une page de papier (ou d'encre) éclairée par la lanterne de Luciole, et le téléchargement se montre en direct : quinze connexions contre une, mégaoctets qui s'accumulent
- Site : forêt de facettes en profondeur (étoiles, lune, brume, trois rangées d'arbres, jour et nuit), ouverture montrée par trois fenêtres qui se chargent avec chronomètre, téléchargement par quinze flux contre un seul, huit fenêtres qui s'endorment en vague
- Site plus sobre : une phrase par moment, plus de chapitres, décor presque invisible, et Luciole plus expressive (regarde le pointeur, réagit au survol, saute au clic, laisse une traînée de lumière, s'endort quand on ne bouge plus)

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

