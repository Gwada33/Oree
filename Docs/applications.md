# Applications (un site devient une application)

Deux modes au choix à l'installation : **application indépendante** (par défaut : son propre programme, sans Orée, ses propres cookies) ou **fenêtre d'Orée** (tes extensions, ta session, mais Orée doit tourner).

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

## Application indépendante (`Sources/OreeWebApp`)
Un petit programme (≈ 0,3 Mo) : une fenêtre, un `WKWebView`, les menus macOS. Il n'embarque ni Orée ni Rust.
- **Rapide au relancement** : (1) elle reste en mémoire quand on ferme la fenêtre (⌘W la cache, l'icône du Dock la rouvre) ; (2) au lancement elle montre la **dernière image** de la page et restaure sa **session** (historique, défilement) ; la vraie page se charge dessous puis la remplace ; (3) cookies, cache disque et service workers persistants et à elle (`WKWebsiteDataStore(forIdentifier:)`) : la page se reconnecte au lieu de repartir de zéro.
- **Natif plutôt que dans la page** : blocage de pubs = règles de contenu WebKit (appliquées dans le processus réseau de WebKit, compilées une fois puis gardées) ; les listes sont converties par le **moteur Rust d'Orée à l'installation** (`exportForStandaloneApp`), avec le CSS qui masque les emplacements de pubs du site. Notifications (`Notification` → centre de notifications macOS), pastille du Dock (`navigator.setAppBadge`), téléchargements (dossier Téléchargements, Finder, rebond du Dock), choix de fichiers, boîtes de dialogue, liens externes (navigateur par défaut), caméra/micro/position (demandés par le système).
- **Mesuré** (`webapp_check.py`, build de développement, example.com) : fenêtre visible ≈ 0,25 s après le lancement ; 1er lancement : page à 2,3 s (la compilation des règles, ≈ 6 s avec les grandes listes, se fait en arrière-plan : on attend 1,5 s au plus) ; relancement : image à 0,25 s, page restaurée à 0,55 s.
- **Ce qu'elle n'a pas** : tes extensions, tes mots de passe, tes cookies d'Orée (il faut se reconnecter une fois dans chaque application), le journal et le reste d'Orée.
- Essais : `scripts/bench/webapp_check.py` (`MODE=standalone` ou `MODE=oree`), `OreeWebApp --selftest <url>` (variable `OREEWEBAPP_SUPPORT_DIR` pour isoler son dossier).
