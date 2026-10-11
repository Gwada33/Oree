# Prompt à donner à Claude Design : le panneau IA d'Orée

À coller tel quel. Joindre en références, depuis le dépôt : `website/assets/shot-palette-light.webp`, `website/assets/shot-essentiel-light.webp` et `website/assets/shot-nuit.webp`
(vraies captures d'Orée : le style à prolonger).

```
Tu es designer produit. Conçois le PANNEAU IA d'Orée, un panneau latéral à droite, dans l'esprit de « Claude dans Chrome ». Orée est un navigateur Mac natif (Swift et AppKit, pas du web).
Le résultat sera ensuite codé en AppKit : tout ce que tu dessines doit être réalisable avec des vues natives (NSView, NSTextView, CALayer) et des mesures en points.

## Le produit
Orée : barre latérale GAUCHE (espaces et onglets, 286 pt), barre d'outils de 52 pt avec l'adresse au centre, page web à droite (coin haut-gauche arrondi, 14 pt). Palette de commandes ⌘K.
L'IA est locale (un petit modèle sur le Mac, sans internet) : elle lit la page ouverte, répond, cherche sur le web, et peut agir à la place de l'utilisateur (remplir un formulaire, cliquer).
Elle se trompe parfois, et l'interface doit le dire avec calme. Règle d'or : l'IA propose, Orée vérifie ; rien d'irréversible sans confirmation.

## Le système de design (à respecter à la lettre, c'est « Pierre, papier, encre »)
- Polices : Instrument Sans (interface, 13 pt par défaut, graisses 400 à 700) ; Instrument Serif en ITALIQUE pour les grands titres et les numéros d'étapes. Rien d'autre.
- Surfaces, clair / sombre : fond de chrome #ECE8E1 / #161514 ; page #FBFAF7 / #1E1D1B ; surface surélevée #FFFFFF / #2A2926 ; champ #E2DDD5 / #272622.
  Texte #1D1C1A / #EEEAE3 ; texte atténué #5E5A53 / #A8A299 ; filets : le texte à 12 % / 11 % d'opacité ; survol : 5,5 % / 6 % ; appui : 10 % / 11 %.
- Accent : choisi par l'utilisateur parmi six teintes (Mousse #2F7354 / #7FCBA2 par défaut, Brique, Ocre, Marine, Prune, Graphite), avec une version « encre » plus profonde pour le texte sur teinte douce.
  Dessine avec Mousse, et dis quels éléments prennent l'accent pour que ça suive la teinte choisie.
- Formes : rayons 6 / 10 / 14 pt (réglables), pastilles 999 pt. Espacements : 2, 4, 6, 8, 12, 16, 24, 32, 48. Mouvement : 120, 180 ou 260 ms, courbe (0,2 ; 0,8 ; 0,2 ; 1) ; aucun mouvement avec « réduire les animations ».
- Profondeur : un filet fin plus une ombre douce. PAS de verre dépoli, PAS de flou, PAS de dégradé, PAS d'emoji, PAS de bulles bleues de messagerie.
- Ton : calme, précis, papier et encre. Textes en français réel, jamais de lorem ipsum.

## Le panneau
- Ouverture par ⌘J (bascule) ; fermeture par Échap ou la croix. Collé au bord droit de la fenêtre, il POUSSE la page (elle rétrécit) au lieu de la recouvrir ; sous 900 pt de large de fenêtre il passe par-dessus.
- Largeur 380 pt par défaut, redimensionnable de 320 à 520 pt par la poignée de son bord gauche (comme la barre latérale gauche), mémorisée. Hauteur : toute celle de la page.
- Une conversation par onglet, qui suit l'onglet et revient quand on y retourne.

## Composants et états à concevoir
1. En-tête : titre « Assistant » (ou mieux, si tu as une idée), puce d'état du modèle, bouton « nouvelle conversation », croix.
2. Puce de contexte de page, sous l'en-tête : ce que l'IA voit (« Lit : Lisbonne — Wikipédia »), avec la possibilité de ne pas partager la page.
3. État vide : une phrase d'accueil sobre et 3 suggestions selon la page (par exemple « Résumer cette page », « Remplir ce formulaire », « Chercher… »).
4. Fil de conversation : message de l'utilisateur ; réponse qui s'écrit au fil de l'eau (avec un repère d'écriture) ; réponse terminée avec ses sources cliquables quand elle a cherché sur le web ; copier la réponse.
5. TRACE D'ACTIONS en direct : une ligne par action (« Clic sur Créer mon compte », « Remplissage de 3 champs », « Recherche : … »), avec son état (en cours, faite, échouée),
   repliable une fois la tâche finie ; l'élément concerné est surligné dans la page pendant une seconde (décris ce surlignage).
6. CARTE DE CONFIRMATION avant toute action sensible (envoi de formulaire, paiement, connexion, téléchargement) : ce qui va être envoyé, EN CLAIR, la page concernée, « Valider » et « Annuler ».
   Elle doit être impossible à rater et impossible à valider par erreur. Les valeurs personnelles s'affichent masquées si ce sont des mots de passe ou des cartes.
7. Carte de question : l'IA bloque et demande (« Le site demande un mot de passe… ») ; zone de réponse courte.
8. États du modèle : pas encore installé (« 1,3 Go, téléchargé une fois, reste sur ce Mac », bouton qui demande l'accord) ; téléchargement avec progression et vitesse ; vérification ; réveil
   (moins d'une seconde) ; prêt ; indisponible ; erreur. Un état vide honnête pour chacun.
9. Pendant une tâche : un bouton ARRÊTER toujours visible. Plafonds atteints (15 étapes) : message clair et ce qui a été trouvé jusque-là.
10. Composeur en bas : champ multi-ligne (Entrée envoie, ⇧Entrée = saut de ligne), bouton envoyer qui devient arrêter, rappel discret « Tout reste sur ce Mac · l'IA peut se tromper ».
11. Page « interdite » (réglages d'Orée, paiement, gestionnaire de mots de passe) : le panneau passe en lecture seule et l'explique en une ligne.

## Contraintes
- Densité et lisibilité d'abord : 380 pt est étroit. Lignes de 13 pt, interlignage généreux, aucun élément qui déborde ou se coupe à 320 pt.
- Accessibilité : contraste du texte ≥ 4,5:1 (clair et sombre), cible tactile ≥ 28 pt, ordre de tabulation logique, étiquettes pour VoiceOver sur chaque contrôle, états au clavier.
- États pour chaque contrôle : normal, survol, appui, focus clavier, désactivé.

## Livrables
1. Un prototype HTML interactif UNIQUE, clair et sombre, avec les écrans suivants : état vide ; réponse qui s'écrit ; tâche en cours avec la trace ; carte de confirmation ; question de l'IA ;
   modèle à installer ; téléchargement ; erreur. Il doit montrer le panneau DANS la fenêtre d'Orée (barre latérale gauche, barre d'outils, page qui rétrécit).
2. Une fiche de spécifications par composant, en points : dimensions, marges, polices (famille, taille, graisse), couleurs désignées PAR NOM de jeton (pas de valeurs inventées), rayons, états.
3. Ta recommandation en une demi-page : ce que tu as choisi, ce que tu as écarté, et le point qui t'inquiète le plus (par exemple la carte de confirmation).
N'invente aucune fonction hors de cette liste. Si une contrainte de la liste te semble mauvaise, dis-le et propose mieux plutôt que de la contourner.
```
