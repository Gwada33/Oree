# Fonctionnalités des autres navigateurs, et où en est Orée

Généré le 14 octobre 2026 par un inventaire du code (`Sources/`), **pas par un test d’usage**. Deux lectures possibles de chaque ligne :
**135 fonctions examinées : 56 absentes (rien trouvé), 79 avec du code présent.**

Ajoutées depuis la première version de cette liste (14 octobre 2026) : impression (⌘P), PDF (⇧⌘S), code source (⌥⌘U), huit moteurs de recherche, mots-clés de recherche (w, yt, gh… et personnels), dossier de téléchargement au choix, user-agent au choix (Safari, Chrome, Firefox, personnalisé, ou Chrome pour certains sites), exporter les favoris (HTML), ajouter tous les onglets aux favoris, fermer les onglets à droite / en dessous, informations sur le site (cadenas, certificat, cookies, autorisations), complétion en ligne de l’adresse, mode lecture (⇧⌘R). Corrigé : le glisser-déposer des onglets existait déjà (l’inventaire l’avait raté).


- **Absent** : aucun code correspondant trouvé. Probablement absent, mais une fonction peut exister sous un autre nom que celui cherché.
- **Code présent** : du code correspondant existe. Ça ne dit **rien** de sa qualité ni de sa complétude ; la ligne reste à tester.

Les navigateurs cités sont ceux qui, à ma connaissance (non revérifiée ligne par ligne), proposent la fonction : Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera.

## Onglets et fenêtres

| Fonction | Orée | Qui l’a |
|---|---|---|
| Groupes d’onglets | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Vivaldi |
| Onglets épinglés | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Onglets verticaux / barre latérale | ◐ code présent (à tester) | Edge, Arc, Vivaldi, Brave, Opera, Firefox |
| Rouvrir l’onglet fermé | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Restauration de session | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Écran partagé (deux pages côte à côte) | ◐ code présent (à tester) | Safari, Edge, Arc, Vivaldi, Firefox |
| Mise en veille des onglets | ◐ code présent (à tester) | Chrome, Edge, Firefox, Brave, Vivaldi, Opera, Safari |
| Couper le son d’un onglet | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Glisser-déposer pour réordonner les onglets | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Détacher un onglet dans une nouvelle fenêtre | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Plusieurs fenêtres | ❌ absent | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Dupliquer l’onglet | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Fermer les autres onglets / ceux à droite | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Aperçu de l’onglet au survol | ❌ absent | Chrome, Safari, Edge, Arc, Vivaldi, Brave |
| Vue d’ensemble en grille de tous les onglets | ◐ code présent (à tester) | Safari, Chrome, Firefox, Vivaldi |
| Ctrl+Tab dans l’ordre d’utilisation récente | ❌ absent | Chrome, Firefox, Vivaldi, Opera, Arc |
| Ajouter tous les onglets aux favoris | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Vivaldi, Opera |
| Archivage automatique des onglets inutilisés | ❌ absent | Arc |
| Aperçu d’un lien sans quitter la page (Peek) | ❌ absent | Arc, Safari |
| Mini-fenêtre rapide (Little Arc) | ❌ absent | Arc |
| Gestes de souris | ❌ absent | Vivaldi, Opera |
| Gestes du trackpad (glisser pour reculer/avancer) | ◐ code présent (à tester) | Safari, Chrome, Firefox, Edge, Brave |
| Onglets conteneurs (cookies séparés par contexte) | ◐ code présent (à tester) | Firefox |

## Page et lecture

| Fonction | Orée | Qui l’a |
|---|---|---|
| Recherche dans la page | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Zoom de la page (par site) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Impression | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Enregistrer la page (PDF, archive web, HTML) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Afficher le code source | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Mode lecture épuré | ◐ code présent (à tester) | Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Lecture à voix haute | ❌ absent | Edge, Safari, Firefox |
| Visionneuse PDF avec annotations | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Vivaldi |
| Traduction de page | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Liste de lecture | ◐ code présent (à tester) | Safari, Chrome, Firefox, Edge, Vivaldi |
| Capture d’écran de la page (zone, page entière) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Vivaldi, Opera |
| Mode sombre forcé sur tous les sites | ◐ code présent (à tester) | Chrome, Firefox, Edge, Opera, Vivaldi, Safari |
| Taille de police minimale / police par défaut réglables | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Navigation au clavier dans la page (caret browsing) | ❌ absent | Chrome, Firefox, Edge |
| Résumé de page par IA | ◐ code présent (à tester) | Edge, Arc, Brave, Opera, Safari |
| Informations sur le site (certificat, permissions, cookies) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Effacement automatique des bannières de cookies | ❌ absent | Brave, Firefox, Edge, Vivaldi, Opera |
| Demande de site pour ordinateur / mobile | ❌ absent | Safari, Chrome, Firefox, Edge |

## Barre d’adresse et recherche

| Fonction | Orée | Qui l’a |
|---|---|---|
| Moteurs de recherche au choix | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Moteurs et mots-clés personnalisés (« w » + Tab) | ◐ code présent (à tester) | Chrome, Firefox, Edge, Vivaldi, Opera, Brave |
| Suggestions de recherche en ligne | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Recherche dans les onglets, favoris et historique depuis la barre | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Vivaldi, Opera |
| Calculatrice et conversions dans la barre | ❌ absent | Chrome, Edge, Vivaldi, Arc |
| Complétion en ligne de l’adresse | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Vivaldi, Opera |
| Palette de commandes (⌘K) | ◐ code présent (à tester) | Arc, Vivaldi, Edge, Opera |
| QR code pour partager la page | ❌ absent | Chrome, Edge, Brave |
| Menu Partager (AirDrop, Messages…) | ❌ absent | Safari, Chrome, Arc, Edge |

## Vie privée et sécurité

| Fonction | Orée | Qui l’a |
|---|---|---|
| Blocage des publicités | ◐ code présent (à tester) | Brave, Firefox, Vivaldi, Opera, Edge |
| Protection contre le pistage / empreinte numérique | ◐ code présent (à tester) | Safari, Firefox, Brave, Vivaldi, Opera |
| Nettoyage des adresses (ClearURLs) | ◐ code présent (à tester) | Brave, Firefox, Safari |
| HTTPS d’abord | ◐ code présent (à tester) | Chrome, Firefox, Edge, Brave, Vivaldi, Opera, Safari |
| Navigation sûre (sites dangereux) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Fenêtre / onglet privé | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Fenêtre privée avec Tor | ❌ absent | Brave |
| VPN intégré | ❌ absent | Opera, Brave, Firefox |
| DNS sécurisé (DoH) réglable | ❌ absent | Chrome, Firefox, Edge, Brave, Vivaldi, Opera |
| Signal Global Privacy Control / Do Not Track | ❌ absent | Firefox, Brave, Chrome, Safari, Edge |
| Gestionnaire de mots de passe | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Verrouillage du coffre par Touch ID | ◐ code présent (à tester) | Chrome, Safari, Edge |
| Vérification de mots de passe compromis | ❌ absent | Chrome, Safari, Firefox, Edge, Brave |
| Passkeys (clés d’accès) | ❌ absent | Chrome, Safari, Firefox, Edge, Brave |
| Code à usage unique (2FA) rempli automatiquement | ❌ absent | Safari, Chrome |
| Remplissage d’adresses | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Remplissage de cartes bancaires | ❌ absent | Chrome, Safari, Edge, Vivaldi, Opera |
| Apple Pay / Google Pay sur les sites | ❌ absent | Safari, Chrome |
| Permissions de site (caméra, micro, position…) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Gestion des cookies et données du site | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Effacer les données à la fermeture | ❌ absent | Firefox, Chrome, Brave, Vivaldi |
| Notifications web (push) | ❌ absent | Chrome, Firefox, Edge, Brave, Vivaldi, Opera, Safari |
| Bloqueur de fenêtres intempestives | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Visionneuse de certificats | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge |

## Synchronisation et appareils

| Fonction | Orée | Qui l’a |
|---|---|---|
| Synchronisation des favoris, de l’historique et des mots de passe | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Envoyer un onglet vers un autre appareil | ❌ absent | Chrome, Firefox, Edge, Safari |
| Onglets d’autres appareils | ❌ absent | Chrome, Safari, Firefox, Edge, Vivaldi |
| Handoff / Continuité Apple | ❌ absent | Safari |
| Compte pour sauvegarder les réglages | ❌ absent | Chrome, Firefox, Edge, Brave, Vivaldi, Opera, Arc |
| Application iPhone / iPad | ❌ absent | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Version Windows / Linux | ❌ absent | Chrome, Firefox, Edge, Arc, Brave, Vivaldi, Opera |

## Import, export et données

| Fonction | Orée | Qui l’a |
|---|---|---|
| Importer depuis Chrome / Safari / Firefox | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Exporter les favoris (HTML) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Exporter les mots de passe (CSV) | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Gestionnaire de téléchargements | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Reprise de téléchargement interrompu | ◐ code présent (à tester) | Chrome, Firefox, Edge, Brave, Vivaldi, Opera |
| Téléchargement en plusieurs connexions | ◐ code présent (à tester) | Vivaldi, Opera |
| Choisir le dossier de téléchargement / demander à chaque fois | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Ouvrir automatiquement les fichiers sûrs | ❌ absent | Safari, Chrome |
| Historique avec recherche et suppression ciblée | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |

## Extensions et personnalisation

| Fonction | Orée | Qui l’a |
|---|---|---|
| Extensions de navigateur | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Installation depuis le Chrome Web Store | ◐ code présent (à tester) | Brave, Edge, Vivaldi, Opera, Arc |
| Boutique d’extensions propre / Safari | ❌ absent | Safari, Firefox, Chrome, Edge |
| Épingler des extensions dans la barre | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Scripts utilisateur (type Tampermonkey) intégrés | ◐ code présent (à tester) | Vivaldi, Opera |
| Personnalisation visuelle d’un site (Boosts) | ◐ code présent (à tester) | Arc |
| Thèmes de couleur / accent | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Fonds d’écran et page d’accueil personnalisable | ◐ code présent (à tester) | Chrome, Firefox, Edge, Vivaldi, Opera, Arc |
| Raccourcis clavier personnalisables | ◐ code présent (à tester) | Vivaldi, Opera, Safari |
| Barre d’outils personnalisable | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Vivaldi, Opera |
| Espaces / profils de travail | ◐ code présent (à tester) | Arc, Edge, Chrome, Firefox, Vivaldi |
| Profils séparés (cookies, historique, mots de passe) | ❌ absent | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Panneaux latéraux d’applications web (messageries, musique) | ❌ absent | Vivaldi, Opera, Edge, Chrome |
| Prise de notes intégrée | ❌ absent | Vivaldi, Opera |
| Langue de l’interface et du correcteur réglables | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |

## Média

| Fonction | Orée | Qui l’a |
|---|---|---|
| Image dans l’image | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Commandes de lecture en cours dans le navigateur | ◐ code présent (à tester) | Chrome, Arc, Firefox, Edge, Vivaldi, Opera |
| Contrôle de la vitesse de lecture des vidéos | ❌ absent | Chrome, Firefox, Edge, Vivaldi, Opera |
| Diffusion vers une TV (Chromecast, AirPlay) | ❌ absent | Chrome, Safari, Edge, Opera |
| Choix de la sortie audio | ◐ code présent (à tester) | Chrome, Firefox, Edge |
| Gestion de l’autoplay | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Vidéos protégées (DRM) | ◐ géré par WebKit lui-même, jamais testé ici | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Touches multimédia du clavier | ❌ absent | Chrome, Safari, Firefox, Edge, Opera |

## Développeurs

| Fonction | Orée | Qui l’a |
|---|---|---|
| Outils de développement (inspecteur, console, réseau) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Mode responsive / émulation d’appareil | ❌ absent | Chrome, Safari, Firefox, Edge |
| Changer le user-agent | ◐ code présent (à tester) | Chrome, Firefox, Edge, Safari |
| Débogage à distance de l’iPhone / Android | ❌ absent | Chrome, Safari, Firefox, Edge |
| Page d’état interne (chrome://, about:) | ◐ code présent (à tester) | Chrome, Firefox, Edge, Brave, Vivaldi, Opera |

## Intégration au système

| Fonction | Orée | Qui l’a |
|---|---|---|
| Navigateur par défaut (liens et fichiers HTML) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Applications web (« Ajouter au Dock ») | ❌ absent | Safari, Chrome, Edge, Firefox |
| Raccourcis Siri / Apple Intelligence | ❌ absent | Safari |
| Widgets et menu du Dock | ❌ absent | Chrome, Safari, Firefox, Edge |
| Services macOS (menu Services, extension de partage) | ❌ absent | Safari, Chrome, Firefox |
| Spotlight / recherche système | ❌ absent | Safari |
| Écran de saisie multilingue / dictée | ❌ absent | Safari, Chrome, Firefox |
| Accessibilité (VoiceOver, navigation clavier) | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Brave, Vivaldi, Opera |
| Mise à jour automatique | ◐ code présent (à tester) | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |
| Application signée et notarisée | ❌ absent | Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera |

## Performance et énergie

| Fonction | Orée | Qui l’a |
|---|---|---|
| Économiseur de mémoire | ◐ code présent (à tester) | Chrome, Edge, Firefox, Brave, Vivaldi, Opera, Safari |
| Mode économie d’énergie | ❌ absent | Chrome, Edge, Brave, Opera |
| Gestionnaire de tâches (mémoire par onglet) | ❌ absent | Chrome, Edge, Firefox, Vivaldi, Opera |
| Préchargement des pages probables | ◐ code présent (à tester) | Chrome, Edge, Firefox, Brave |
| Accélération matérielle réglable | ❌ absent | Chrome, Firefox, Edge, Brave, Vivaldi, Opera |
| Assistant IA intégré (panneau latéral) | ◐ code présent (à tester) | Edge, Opera, Brave, Arc, Chrome |
| Cartes de données (météo, calendrier) / Liste d’événements | ◐ code présent (à tester) | Safari |
