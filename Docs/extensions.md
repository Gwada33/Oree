# Extensions dans Orée

Moteur : `WKWebExtensionController` (WebKit). WebKit ne fournit que **16 des ~70 espaces `chrome.*`** (mesuré : `scripts/bench/ext/api-inventory`) : action, alarms, contextMenus, cookies, declarativeNetRequest, extension, i18n, permissions, runtime, scripting, storage, tabs, webNavigation, webRequest, windows (+ `commands` si le manifeste en déclare). Orée ajoute le reste.

## Comment ça marche
1. **À l'installation et à chaque chargement**, `ExtensionCompat` (BrowserCore) prépare la copie de l'extension : le script `__oree/compat.js` est chargé **avant tout autre script** (page de fond, popup, réglages, panneau latéral…). Le manifeste d'origine est gardé dans `__oree/manifest.orig.json`. Un service worker est chargé dans une **page de fond persistante** : WebKit arrête le service worker quelques secondes après son démarrage et ne le réveille pas pour un clic sur le bouton (constaté avec Claude) ; `HB_BACKGROUND_SW=1` garde le service worker (essais).
2. **Le script** (`Resources/ExtCompat/core.js` + `sections/NN-*.js`) ajoute les API manquantes sans jamais écraser celles de WebKit. Trois sortes : JavaScript seul, **pont vers l'app** (`runtime.sendNativeMessage('oree', {m, a})`, côté app `ExtensionBridge*.swift`, avec contrôle de la permission demandée dans le manifeste d'origine), et API « honnêtes » (échec avec un message clair, jamais un faux succès).
3. **L'identifiant** : une extension qui a une `key` reçoit l'identifiant Chrome (`fcoeoabgfenejglbffodgkkbkcdhcgfn` pour Claude) : OAuth et services externes la reconnaissent. Les adresses `chrome-extension://<id>/…` (redirections de connexion) ouvrent la page de l'extension.

## Ce qui est ajouté
| Famille | API | Réalisation |
|---|---|---|
| Données d'Orée | history, bookmarks (liste plate = barre de favoris), topSites, readingList, sessions (onglets fermés récemment), downloads | pont ↔ `HistoryRepository`, `BookmarkRepository`, `DownloadsController` |
| Pilotage de page | **debugger** (CDP : Runtime.evaluate, Page.captureScreenshot / navigate / reload / getLayoutMetrics / addScriptToEvaluateOnNewDocument, Input.dispatchMouseEvent / dispatchKeyEvent / insertText, événements Page / Network (document) / Runtime.consoleAPICalled / exceptionThrown) | pont ; vrais événements souris et clavier ; Orée affiche « X contrôle cet onglet » avec un bouton Arrêter |
| Interface | sidePanel (panneau à droite), offscreen (page cachée), notifications (système), commands (raccourcis), identity (launchWebAuthFlow + redirection), action.setBadgeTextColor | pont + `WebPanelView` |
| Système | management, idle, power, system.cpu / memory / storage / display, browsingData, search, tts | pont |
| Messagerie native | sendNativeMessage / connectNative vers les programmes déclarés pour Chrome (`NativeMessagingHosts`), **avec l'accord de l'utilisateur** (une fois par extension et par programme) et vérification de `allowed_origins` | `ExtensionNativeHost.swift`, `NativeMessaging` |
| JavaScript seul | privacy, tabGroups + tabs.group/ungroup (groupes tenus pour l'extension, pas affichés), declarativeContent, accessibilityFeatures, proxy.settings, fontSettings, contentSettings (valeurs gardées, sans effet), storage.managed, runtime.getContexts / onSuspend…, tabs.executeScript / insertCSS (MV2), enums (declarativeNetRequest, scripting, cookies…), windows.create (repli : un onglet), **modifyHeaders de declarativeNetRequest** (appliqué aux requêtes de l'extension elle-même), nettoyage des filtres webRequest, requestIdleCallback, runtime.getURL('') |
| Honnêtes (échec clair) | gcm, instanceID, desktopCapture, tabCapture, pageCapture, processes, documentScan, printing, audio, dns, ttsEngine, platformKeys, certificateProvider, vpnProvider, wallpaper, systemLog, webAuthenticationProxy ; omnibox (événements inertes) | |

## Banc
- `node scripts/bench/ext_compat_test.js` : le script de compatibilité contre un faux `chrome` (31 vérifications).
- `OREE_TEST_APP=<OreeTest.app construite avec ./build_app.sh --debug> python3 scripts/bench/ext_check.py` : 11 extensions d'essai (`scripts/bench/ext/*`) installées dans une instance de développement ; popup rendu et dimensionné, réglages, script de contenu, API ajoutées, débogueur (vrais clics et frappes), API natives, système, messagerie native avec un vrai hôte, raccourci clavier, clic sur une grosse extension : **102 vérifications**. L'instance d'essai a sa fenêtre masquée : un popover n'y est jamais « à l'écran », on lit donc le contenu de la page du popup. Elle a son propre identifiant de contrôleur (`HB_EXT_CONTROLLER_ID`) : WebKit garde le stockage de chaque extension entre deux lancements.
- Diagnostic : `ui.sh extop calls:N` (journal des appels du pont, démarrages, erreurs non attrapées des extensions), `trace:N`, `report`.

## Limites connues
- **Claude in Chrome** : démarre sans erreur, le bouton ouvre son panneau latéral (écran de connexion), sa connexion OAuth revient dans l'extension. **Pas vérifié** : l'usage connecté (je n'ai pas de compte de test) et le pilotage complet d'une page par Claude (le sous-ensemble CDP qu'il utilise est traduit et testé avec une extension d'essai, pas avec lui).
- **uBlock Origin (Manifest V2)** : il bloque via `webRequest` bloquant, que WebKit ne fournit pas ; ses erreurs de démarrage restantes (`menus` avec motif `abp:`, `alarms.create`, filtres de requêtes) ne se corrigent pas toutes. Préférer **uBlock Origin Lite** (MV3, declarativeNetRequest). Orée a aussi son propre blocage.
- Le débogueur ne couvre pas tout CDP : DOM.*, Accessibility.*, Emulation (sauf focus), Input tactile, `Runtime.callFunctionOn`… échouent avec un message clair. Les événements réseau ne concernent que le document, pas les sous-requêtes. Les boîtes de dialogue JavaScript ne peuvent pas être pilotées.
- `tabGroups`, `proxy`, `contentSettings`, `fontSettings`, `privacy` : l'extension les lit et les écrit, mais Orée n'en tire aucun effet.
- Une extension ne peut pas ouvrir une fenêtre à elle (`windows.create` ouvre un onglet).
- **Journal des commits** : voir `git log` (Extensions : …).
