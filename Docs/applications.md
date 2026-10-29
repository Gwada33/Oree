# Applications (un site devient une application)

« Installer ce site comme application… » (menu Fichier et ⌘K) : le site s'ouvre dans sa **propre fenêtre**, sans onglets, sans barre latérale ni barre d'adresse (précédent, suivant, recharger seulement), avec son nom et son icône. Un lien vers un **autre site** s'ouvre dans Orée ; ⌘T, ⌘N et les liens « nouvel onglet » vont dans la fenêtre principale ; fermer la fenêtre la ferme (l'application n'a pas d'onglet à garder).

## Comment c'est fait
- **Données** : `BrowserCore/WebApp.swift` (`WebApp`, `WebAppStore` = `~/Library/Application Support/HyperBrowser/Apps/apps.json` + `icons/<id>.png`, `WebAppScope` : le site et ses sous-domaines sont « dans l'application »).
- **Fenêtre** : `BrowserWindowController+WebApp.swift` — un `BrowserWindowController` secondaire en « mode application » (`webApp`), comme la mini-fenêtre mais pleine taille ; la taille est mémorisée.
- **Installation** : le nom et les icônes sont lus dans la page (balises `<link>`, manifeste, `og:site_name`), l'icône est posée sur un carré arrondi (`WebAppIcon`), une lettre sur fond coloré à défaut.
- **Raccourci macOS** : `~/Applications/<Nom>.app` = Info.plist + `OreeAppLauncher` (petit exécutable, cible SwiftPM, copié depuis Orée) + icône `.icns` (iconutil) + signature ad hoc. Le lanceur demande à Orée d'ouvrir l'application (`oree-app://open/<id>`), **garde son icône dans le Dock tant que la fenêtre est ouverte**, la ramène au premier plan au clic, et se ferme avec elle (ou avec Orée).
- **Gérer** : ⌘K → « Ouvrir l'application « X » » / « Retirer l'application « X » » (retire aussi le raccourci).

## Banc
`OREE_TEST_APP=<OreeTest.app (build --debug)> python3 scripts/bench/webapp_check.py` : 12 vérifications (enregistrement, icône, raccourci, plist, lanceur, signature, fenêtre sans onglets, liens hors du site, `oree-app://` sans doublon, retrait). Variables d'essai : `HB_WEBAPPS_STORE`, `HB_WEBAPPS_APPLICATIONS_DIR`, `HB_WEBAPPS_AUTOCONFIRM[_NAME]`.

## Limites
- Les applications partagent les cookies, l'historique et les extensions d'Orée (pas de profil à part).
- Le Dock montre l'icône du **raccourci** pendant que l'application est ouverte ; le processus qui fait tourner la page reste Orée.
- Pas encore vérifié à l'œil : la mise en page de la fenêtre (la fenêtre de l'instance d'essai est masquée, donc pas de capture).
- Pas de notifications push ni de « mode autonome » des sites (manifeste PWA) : seulement le nom et les icônes en sont lus.
