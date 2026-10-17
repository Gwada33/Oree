# Orée (ex-HyperBrowser) — fonctionnalités et arguments pour la publicité

> Document de travail pour une future campagne. Il liste ce qui existe **vraiment** dans l'app,
> avec un niveau de preuve. **Ne rien affirmer dans une pub qui ne soit pas marqué ✅**, et refaire
> les mesures chiffrées sur plusieurs Macs avant publication.
>
> Légende : ✅ implémenté et vérifié · 🔶 implémenté mais pas testé en réel · ⏳ prévu / pas fait
> Unicité : ⭐⭐⭐ rare · ⭐⭐ combinaison peu courante · ⭐ présent chez d'autres navigateurs

---

## 1. Le pitch en une phrase (pistes)

- « Le navigateur Mac qui dort quand tu ne le regardes pas. »
- « Léger par conception : il libère la mémoire des onglets que tu n'utilises pas. »
- « Vie privée par défaut. Zéro télémétrie. Zéro réglage compliqué. »
- « Un navigateur natif, rapide à ouvrir, qui range ta vie en espaces. »
- « Tapez ⌘K. Tout est là : onglets, historique, favoris, actions. »

## 2. Ce qui le distingue (le cœur de la pub)

### 2.1 Mémoire et légèreté — ⭐⭐⭐ (notre meilleur argument)
| Fonction | Ce que ça fait pour l'utilisateur | Statut |
|---|---|---|
| **Onglets endormis** | Un onglet inutilisé est remplacé par une image de sa dernière apparence ; sa page est vraiment déchargée de la RAM. Il se rouvre à la demande. | ✅ |
| **Restauration paresseuse** | Au lancement, seul l'onglet visible est chargé ; les autres attendent. | ✅ mesuré |
| **Budget mémoire** | Dès que les onglets dépassent un budget (réglable), les onglets cachés les plus lourds s'endorment — jamais celui que tu regardes ni un onglet qui joue du son. | ✅ |
| **Fermeture réelle** | Fermer un onglet arrête sa page et sa vidéo et libère sa mémoire (pas de « fantôme »). | ✅ |
| **Espaces cachés endormis plus vite** | Quitter un espace met ses onglets en veille en 2 min au plus. | ✅ |
| **Retour instantané adaptatif** | Garde les pages précédentes en mémoire seulement si le Mac a assez de RAM (> 8 Go) ; réglable. | ✅ |
| **Alerte de mémoire système** | Sous pression, l'app endort les onglets cachés et vide les caches. | ✅ |
| **App légère** | ~50 Mo pour l'interface au repos. | ✅ mesuré |

**Chiffres mesurés** (Mac M1, 8 Go, à refaire avant publication) :
- Ouverture avec 8 onglets sauvegardés : **~700 Mo → ~120–175 Mo** (−75 à −80 %), 1 page chargée au lieu de 8.
- Retour arrière : cache désactivé = **−35 % de mémoire** (~270 → ~174 Mo) après 6 sites parcourus.
- Lancement : fenêtre visible en **~0,3–0,4 s**, première page en **~0,5–0,6 s** (lancements à chaud).

### 2.2 Interface : espaces, palette, barre latérale — ⭐⭐
| Fonction | Détail | Statut |
|---|---|---|
| **Palette de commandes ⌘K (et ⌘L pour l'adresse)** | Une seule barre pour : aller sur un onglet ouvert, rechercher l'historique, ouvrir un favori, lancer une action, rechercher sur le web. Filtres (Tout / Onglets / Historique / Favoris / Actions), mise en évidence de la saisie, tout au clavier. | ✅ |
| **Espaces** Perso / Travail / Lecture | Trois groupes d'onglets à pastille de couleur, renommables, raccourcis ⌃1–⌃3, déplacement d'un onglet entre espaces. | ✅ |
| **Barre latérale verticale** | Favoris en grille, onglets en liste, repliable (⌘⇧S). | ✅ |
| **Favoris** | Ajout en un clic (+), retrait par clic droit. | ✅ |
| **Onglets** | Glisser-déposer pour réordonner, clic droit (dupliquer, copier le lien, fermer les autres…), ⌘⇧T pour rouvrir, ⌘1–⌘9. | ✅ (menu clic droit 🔶) |
| **Icône de son** | Haut-parleur sur l'onglet qui joue ; un clic coupe le son. | ✅ |
| **Barre de progression** | Fine ligne verte pendant le chargement. | ✅ |
| **Animations soignées** | Ouverture/fermeture d'onglets, palette, repli de la barre latérale. | ✅ |
| **Page de nouvel onglet locale** | Aucun réseau, apparaît instantanément ; option pour masquer les sites récents. | ✅ |
| **Thème clair, sombre ou automatique**, 6 couleurs d'accent, 5 préréglages, densité et arrondi réglables, tout en direct. | Centre de personnalisation (⌘,). | ✅ |
| **Espaces personnalisables** | Nom, icône (8) et teinte (6) au choix, nombre libre, vue d'ensemble (⌃↑). | ✅ |
| **Groupes d'onglets repliables** | Par espace, avec « Pages libres ». | ✅ |
| **Écran partagé** | Deux pages côte à côte (⌘\), répartition ⅓ ½ ⅔, glisser la charnière. Non conservé au redémarrage. | ✅ (rendu du côté non actif non vérifié visuellement) |
| **Raccourcis clavier éditables** | Réglages → Raccourcis clavier, avec détection des conflits. | ✅ |
| **Traduction de page** | Traduit la page sur le Mac avec le framework Translation d'Apple (hors ligne, rien n'est envoyé). Bouton proposé quand la langue de la page diffère de la vôtre ; « Afficher la page d'origine » restitue tout. macOS 26 et plus. Lente avec le modèle Apple Intelligence (~3 textes/s, traduit autour de l'écran puis au défilement). | 🔶 (testé sur une page de test ; pas sur de vrais sites ; modèle rapide non mesuré) |
| **Copier-coller propre** | Le texte copié arrive sans la police, les couleurs ni les liens du site ; une sélection sur plusieurs cellules d'un tableau se colle en vrai tableau dans Numbers ou Excel ; option pour ajouter la source avec un lien vers le passage ; une adresse copiée propose « Ouvrir dans Plans ». | ✅ testé sur une page de test ; 🔶 pas sur de vrais sites ni dans Numbers/Excel |
| **Mode nuit universel** | Assombrit tous les sites, même sans thème sombre : photos, vidéos et grands visuels restent naturels, les sites déjà sombres ne sont pas touchés, un clic sur la lune laisse un site clair. Désactivé par défaut ; « automatique » suit le mode sombre du Mac. | ✅ testé sur pages de test et 3 vrais sites (Wikipédia, BBC, GitHub) ; 🔶 consommation non mesurée ; Night Shift non pris en charge |
| **Reprendre où tu en étais** | Sur n'importe quel site, Orée retient la position d'une vidéo longue et le paragraphe d'un article long, et propose de reprendre à votre retour ; une fine ligne montre l'avancée de la lecture. Local, jamais en navigation privée, effacé avec les données de navigation. | ✅ testé sur pages de test ; 🔶 pas sur de vrais sites ; vidéos en iframe non suivies |
| **L'essentiel** | Un bouton affiche seulement l'essentiel d'une page : ingrédients, étapes et temps d'une recette, étapes d'un tutoriel, verdict d'un comparatif — sans les 2 000 mots de souvenirs. Mode cuisine : gros texte, écran qui reste allumé. Données de la page lues exactement quand elles existent ; sinon modèle local d'Apple Intelligence (≈ 30 s, macOS 26, peut contenir des erreurs ; ce qui ne se retrouve pas dans la page est écarté). | ✅ testé sur pages de test et un essai sur une vraie recette ; 🔶 pas sur beaucoup de sites ; lent avec le modèle |
| **Boosts : changer un site en une phrase** | « Cache les recommandations et agrandis le texte » : le modèle local d'Apple Intelligence écrit des règles de style pour ce site seulement, vérifiées par l'app (jamais de JavaScript, rien ne peut être chargé ou cacher l'article), avec annulation immédiate. Mode calme (sans lecture automatique, sans animations, sans pastilles) par site ou partout. | ✅ testé sur page de test ; 🔶 pas sur de vrais sites (essai YouTube non concluant) ; scroll infini non géré |
| **Ajouter au Calendrier** | Un événement annoncé par la page, ou un rendez-vous écrit en texte (modèle local, date vérifiée dans la page), s'ouvre dans Calendrier avec le titre, l'heure et le lieu remplis. Aucune autorisation d'accès au calendrier. | ✅ testé sur pages de test ; 🔶 pas sur de vrais sites ; Rappels non faits |
| **Page d'accueil** | Date en serif, favoris numérotés (⌥1–⌥8), « Reprendre », fonds uni/papier/horizon/photo. | ✅ |

### 2.3 Vie privée et sécurité intégrées (sans extension) — ⭐⭐
| Fonction | Détail | Statut | Unicité |
|---|---|---|---|
| **Blocage des pubs et traceurs** | Listes EasyList/EasyPrivacy compilées pour WebKit (moteur Rust) + masquage cosmétique + mises à jour en arrière-plan. | ✅ (effet réel sur sites : 🔶) | ⭐ |
| **Nettoyage des liens** | Retire `utm_*`, `fbclid`, `gclid`… (règles ClearURLs) à la navigation. | ✅ | ⭐⭐ |
| **Réduction du fingerprinting** | Bruit discret sur canvas, WebGL, audio ; différent par site et par session. | ✅ (peut casser quelques sites) | ⭐⭐ |
| **HTTPS uniquement** | Met à niveau `http://`, avertit avant de continuer en HTTP. | ✅ | ⭐ |
| **« Connexion non privée »** | Certificat invalide = page non ouverte, sans bouton de contournement. | ✅ | ⭐ |
| **Safe Browsing optionnel** | Désactivé par défaut ; listes locales, seul un préfixe de 4 octets part chez Google en cas de doute. | 🔶 (jamais testé avec le vrai service) | ⭐⭐ |
| **Autorisations par site temporaires** | Caméra/micro/position : oubliées à la fermeture par défaut, jamais mémorisées en navigation privée. | 🔶 | ⭐⭐ |
| **Zéro télémétrie** | Aucune donnée d'usage envoyée. | ✅ | ⭐⭐ |
| **Téléchargements marqués** | Quarantaine macOS (Gatekeeper) ; reprise après interruption. | ✅ quarantaine / 🔶 reprise | ⭐ |
| **Navigation privée** | Données non persistantes, aucune session ni favori enregistré. | ✅ | ⭐ |

### 2.4 Mots de passe intégrés et locaux — ⭐⭐
- Coffre chiffré (ChaChaPoly), clé dans le Trousseau macOS, protection Touch ID pour remplir et copier. ✅ (Touch ID 🔶)
- Remplissage seulement sur un vrai clic de l'utilisateur, jamais automatique, uniquement en HTTPS. ✅
- Import CSV (export de Mots de passe Apple, Chrome…) avec proposition de supprimer le fichier en clair. ✅
- Presse-papiers effacé 30 s après une copie. ✅
- Tout reste sur le Mac. ✅
- **Codes à usage unique (2FA)** : Orée génère les codes TOTP à la place d'une appli d'authentification et les remplit (champ unique ou cases séparées). ✅ (banc d'essai ; pas essayé sur un vrai site)
- **Export CSV** de tous les mots de passe, avec leurs codes 2FA. ✅
- **Audit** : mots de passe faibles, réutilisés ou compromis. ✅ (compromis : 🔶, jamais essayé avec le vrai service)
- Import des cookies de Brave (rester connecté aux mêmes sites) : lecture du profil Brave du même utilisateur, après autorisation du Trousseau macOS. 🔶 (déchiffrement testé sur des données fabriquées ; jamais essayé sur un vrai profil)

### 2.5 Mac natif — ⭐
- Écrit en Swift/AppKit, moteur WebKit du système (profite des correctifs de sécurité Apple). ✅
- Peut être défini comme navigateur par défaut. 🔶 (déclaré, bouton non testé)
- Pages d'erreur et messages en français. ✅
- Inspecteur web activable (option développeur). ✅

### 2.6 Outils du quotidien (ajoutés en octobre 2026) — ⭐
| Fonction | Ce que ça fait pour l'utilisateur | Statut | Unicité |
|---|---|---|---|
| **Remplissage d'adresses** | Remplit nom, adresse, téléphone ; reconnaît les champs français ; propose d'enregistrer. | ✅ (banc d'essai) | ⭐ |
| **Remplissage de cartes** | Remplit la carte sur demande ; le code de sécurité n'est **jamais** enregistré. | ✅ (banc d'essai) | ⭐ |
| **Refus automatique des cookies** | Clique « Refuser » sur les bannières de consentement (gestionnaires connus et détection par le texte) ; ne touche à rien s'il n'y a pas de bouton de refus. | ✅ (pages de test ; sites réels : 🔶) | ⭐ |
| **Profils séparés** | Travail, Maison… : cookies, historique et mots de passe distincts, ouverts en même temps dans leurs propres fenêtres. | ✅ | ⭐ |
| **Gestes de souris** | Clic droit + glisser : précédent, suivant, nouvel onglet, fermer l'onglet. | ✅ | ⭐⭐ |
| **Mode responsive** | Voir la page à la taille d'un téléphone ou d'une tablette sans quitter la fenêtre. | ✅ | ⭐ |
| **Menu du Dock** | Nouvelle fenêtre, navigation privée, autres profils, directement depuis l'icône. | ✅ | ⭐ |
| **Menu Services** | « Ouvrir dans Orée » depuis n'importe quelle appli sur un lien ou un texte sélectionné. | ✅ | ⭐ |
| **Spotlight** | Favoris et pages retrouvables depuis la recherche du Mac. | ✅ | ⭐⭐ |
| **Copier tous les médias** | Clic droit : enregistre toutes les images, vidéos et sons de la page dans un dossier et les met sur le presse-papiers (⌘V dans le Finder) ; ou copie leurs adresses. | ✅ (page de test) | ⭐⭐ |
| **Copier la page entière** | Clic droit : toute la page, de haut en bas, en PDF et image sur le presse-papiers. | ✅ (page de test ; pages très longues coupées à 20 000 pt) | ⭐ |
| **Inspecter l'élément** | Clic droit : ouvre l'inspecteur web. | 🔶 (ouverture non vue à l'écran) | ⭐ |
| **AirPlay** | Envoyer une vidéo vers une Apple TV ou un écran compatible. | 🔶 (activé, jamais essayé avec un appareil) | ⭐ |

### 2.7 Luciole vit dans la page — ⭐⭐
| Fonction | Ce que ça fait pour l'utilisateur | Statut | Unicité |
|---|---|---|---|
| **Luciole dans la page** | ⌘J ouvre une capsule de verre en bas de la page, plus de panneau latéral ; la mascotte dort dans la barre d'outils et y revient. | ✅ (verre vu sur macOS 27) | ⭐⭐ |
| **Sélectionner, c'est demander** | Sélectionnez un passage : Expliquer, Traduire ou Garder apparaissent à côté. La réponse s'écrit à côté du passage, surligné et relié par un fil de lumière. | ✅ (page de test) | ⭐⭐ |
| **Valider en voyant** | Avant tout envoi, paiement ou connexion, la page s'assombrit autour du bouton et une carte montre en clair ce qui va partir. Rien ne part sans votre clic, Entrée ne valide jamais. | ✅ | ⭐⭐ |
| **Le chemin de l'agent** | Chaque action de Luciole laisse une étape numérotée sur la page ; une pastille « Arrêter » reste en haut. | ✅ (tâche de 2 étapes) | ⭐⭐ |
| **Mémoire d'Orée** | Luciole retrouve la page que vous avez lue hier (« l'article sur WebKit »). Jamais en navigation privée, ni connexion, paiement ou mot de passe ; sur ce Mac seulement ; effaçable en un clic. | ✅ (page de test ; recherche par mots, pas par sens) | ⭐⭐ |
| **Réponses mises en page** | Tableaux, listes, titres, code ; « Ouvrir en page » pour lire en grand. | ✅ | ⭐ |

---

## 3. Arguments par public

- **Utilisateur de Mac avec peu de RAM (8 Go)** : « Ouvre 20 onglets sans ralentir ton Mac. »
- **Utilisateur soucieux de vie privée** : « Bloque, nettoie et protège par défaut. Rien n'est envoyé. »
- **Travailleur / étudiant** : « Espaces Perso, Travail, Lecture. Tout au clavier avec ⌘T. »
- **Minimaliste** : « Une barre latérale, une palette, zéro encombrement. »

## 4. Visuels de pub possibles
- Avant/après de la mémoire avec 8 onglets (ex. barre Moniteur d'activité).
- La palette ⌘T avec la saisie en surbrillance verte.
- Le sélecteur d'espaces coloré (Perso / Travail / Lecture).
- L'écran « Connexion non privée ».
- L'icône de son verte sur un onglet.

---

## 5. À NE PAS affirmer (pas prouvé ou pas vrai)

- ⚠️ Comparaison avec Safari et Brave : **une mesure existe** (Docs/benchmark-compare-2026-10-09.json, banc `scripts/bench/compare.py`, Mac M1 8 Go,
  macOS 27, Orée **1.0.1**, serveur local, médiane de 10 lancements) : ouverture 0,83 s contre 1,58 s (Safari) et 0,90 s (Brave) ; téléchargement de
  192 Mo 7 s contre 27,5 s et 30 s (serveur limitant chaque connexion). **Safari reste plus économe en mémoire** (20 onglets : ~1,07 Go contre ~1,6 Go).
  À dire avec la méthode et la date, **à refaire sur la version courante et sur d'autres Mac** ; jamais « plus léger que Safari ». Firefox, Chrome et
  Orion ne sont pas mesurés.
- ❌ « Meilleure batterie » : jamais mesuré.
- ❌ Passkeys, mises à jour automatiques, extensions, synchronisation entre appareils, profils séparés :
  **non disponibles** (certaines demandent un compte Apple Developer payant).
- ❌ « Signé et notarisé » : l'app est signée en ad-hoc ; macOS affichera un avertissement sur un autre Mac.
- ❌ Compatibilité Windows/Linux/iPhone : Mac uniquement.
- ❌ « Bloque 100 % des pubs » : dépend des sites et des listes.
- ❌ « Aucun site cassé » : l'anti-fingerprinting et le blocage peuvent casser des sites.
- ⚠️ « Le seul à… » : la plupart des fonctions de vie privée existent ailleurs (surtout dans Brave, Firefox) ;
  **notre différence est la combinaison** (légèreté + espaces + palette + vie privée intégrée, sur Mac natif).
- ⚠️ Tous les chiffres viennent d'un seul Mac (M1, 8 Go) avec peu de passes de mesure.

## 6. Expérimental (désactivé par défaut — ne pas vendre comme acquis)
- **Pages longues plus légères** 🔶 : sur une liste de 6 000 éléments, le recalcul de la mise en page passe de ~710 à ~406 ms (−42 %) ; avec une règle écrite à la main avant l'affichage, la mémoire de la page baisse de ~45 %. La version automatique ne reproduit pas encore le gain de mémoire. Peut rogner un menu qui dépasse d'un élément.
- **Nettoyage de la mémoire JavaScript des onglets cachés** 🔶 : −112 Mo sur un YouTube resté caché dans un essai, 0 sur d'autres. Effet sur la fluidité de l'onglet actif non mesuré. Sert aussi de premier palier du budget mémoire avant la mise en veille.

## 7. Idées étudiées, pas faites
- Impossibles sans compte Apple ou serveur : notarisation, passkeys, notifications push, Apple Pay, synchronisation iCloud, VPN, Tor, compte, apps iPhone/Windows. **Ne pas les promettre.**
- Extensions de navigateur, lien avec Mots de passe Apple, synchronisation chiffrée entre Macs.
- Décodage des images à la taille affichée, bytecode partagé : demandent de modifier WebKit lui-même (non réalisable ici).

*Dernière mise à jour : octobre 2026. À relire et mettre à jour à chaque nouvelle fonction.*
