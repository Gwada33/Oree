# Extensions dans Orée

Moteur : `WKWebExtensionController` (WebKit). Code : `ExtensionManager.swift`, `ExtensionAdapters.swift`, `BrowserWindowController.swift` (popup, boutons).

## Ce qui a été corrigé (28 octobre 2026)
- **Clic sur le bouton sans effet** : la fenêtre (et ses onglets) n'était jamais déclarée au moteur (`didOpenWindow`). Sans cela, `performAction(for: tab)` ne faisait rien.
- **Popup vide** : l'app ouvrait le popover avant que la page du popup ne soit chargée et dimensionnée ; elle attend maintenant la page (3 s au plus) puis sa taille (1 s). Piège : lire `action.popupWebView` ailleurs que dans le rappel du moteur le précharge, et le moteur n'appelle alors plus l'app (le popup ne s'ouvre jamais).
- **Réglages inaccessibles** : (1) les pages `webkit-extension://` étaient bloquées par `ExternalLinkPolicy` ; (2) elles doivent se charger dans une vue configurée par `context.webViewConfiguration` (sinon erreur -1008). Entrées ajoutées : clic droit sur le bouton (Réglages, Désactiver, Supprimer) et bouton « Réglages » dans Réglages › Extensions.

## Banc
`scripts/bench/ext/*` : 5 extensions d'essai (popup MV3, popup MV2 + page de fond, script de contenu + pastille, messages popup ↔ service worker, `options_ui`).
`OREE_TEST_APP=<OreeTest.app construite avec ./build_app.sh --debug> python3 scripts/bench/ext_check.py` : 26 vérifications (installation, popup rendu et dimensionné, contenu dynamique, réglages, script de contenu). L'instance d'essai a sa fenêtre masquée : un popover n'y est jamais « à l'écran » (`onScreen` faux), on lit donc le contenu de la page du popup.

## Limites connues (WebKit, pas Orée)
- **Claude in Chrome** : le service worker plante au chargement (`TypeError … mcpPermissions`), et l'extension demande `sidePanel`, `debugger`, `offscreen`, `tabGroups`, `identity` : WebKit ne les fournit pas. Elle ne peut pas fonctionner dans Orée sans ces API.
- **uBlock Origin (MV2)** : `chrome.privacy` n'existe pas dans WebKit (erreur au démarrage), et le popup affiche des « _ » (pas de données du fond). Préférer **uBlock Origin Lite** (MV3). Orée a de toute façon son propre blocage.
