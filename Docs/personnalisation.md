# Personnaliser les boutons (barre d'outils et barre latérale)

**Où** : Réglages › Disposition › « Boutons : barre d'outils et barre latérale », ou clic droit sur n'importe quel bouton › « Personnaliser les barres… ».

**Ce qui se règle** (`ChromeLayout`, `Sources/BrowserCore/ChromeLayout.swift`, JSON dans la clé `settings.chromeLayout`) :
- l'emplacement de chaque bouton : barre d'outils à gauche, à droite, bas de la barre latérale, ou masqué ; l'ordre dans chaque zone ;
- la taille des icônes (petites 24 pt, moyennes 28, grandes 34) ;
- « Rechercher, aller à… » et « Nouvel onglet » dans la barre latérale : affichés ou non ;
- pour les boutons « selon la page » (Calendrier, L'essentiel, mode nuit, traduction, téléchargements, afficher la barre latérale) : « Toujours à sa place ».
  Épinglé, le bouton ne bouge plus : il est grisé quand il ne sert pas. Non épinglé, il n'apparaît que quand il sert (comportement d'origine).
- Nouveau bouton : l'assistant (Luciole), à côté de « Personnaliser ».

**Règles** : chaque bouton est quelque part exactement une fois ; la palette de commandes (⌘K, bouton « ··· ») ne peut pas être masquée (c'est le chemin de retour) ;
une valeur illisible redonne la disposition d'origine.

**Limites actuelles** : l'ordre se change avec les flèches ou le clic droit, pas encore par glisser-déposer ; l'ordre des sections de la barre latérale
(espaces, recherche, onglets) n'est pas réglable, seulement l'affichage de deux rangées ; la barre d'onglets horizontale a ses propres boutons.

**Essais** : `HB_CHROME_LAYOUT=<json>` charge une disposition en mémoire, sans toucher aux vrais réglages.
