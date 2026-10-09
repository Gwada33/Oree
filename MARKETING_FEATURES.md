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
- « Tapez ⌘T. Tout est là : onglets, historique, favoris, actions. »

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
| **Palette de commandes ⌘T / ⌘L** | Une seule barre pour : aller sur un onglet ouvert, rechercher l'historique, ouvrir un favori, lancer une action, rechercher sur le web. Filtres (Tout / Onglets / Historique / Favoris / Actions), mise en évidence de la saisie, tout au clavier. | ✅ |
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
- Import des cookies de Brave (rester connecté aux mêmes sites) : lecture du profil Brave du même utilisateur, après autorisation du Trousseau macOS. 🔶 (déchiffrement testé sur des données fabriquées ; jamais essayé sur un vrai profil)

### 2.5 Mac natif — ⭐
- Écrit en Swift/AppKit, moteur WebKit du système (profite des correctifs de sécurité Apple). ✅
- Peut être défini comme navigateur par défaut. 🔶 (déclaré, bouton non testé)
- Pages d'erreur et messages en français. ✅
- Inspecteur web activable (option développeur). ✅

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

- ❌ « Plus rapide / plus léger que Safari, Chrome, Brave, Orion » : **aucune comparaison valide n'a été faite**
  (Safari, Orion, Firefox, Chrome non mesurés ; la comparaison avec Brave a été invalidée).
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
- Extensions de navigateur, lien avec Mots de passe Apple, synchronisation chiffrée entre Macs.
- Décodage des images à la taille affichée, bytecode partagé : demandent de modifier WebKit lui-même (non réalisable ici).

*Dernière mise à jour : octobre 2026. À relire et mettre à jour à chaque nouvelle fonction.*
