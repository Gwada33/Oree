# Prompt à coller dans la session « IA »

À coller tel quel dans une nouvelle session Claude Code ouverte dans `~/HyperBrowser-ia` (branche `ia`).

```
Tu es la session « IA » du projet Orée (navigateur macOS natif : Swift 6, AppKit, SwiftPM, WebKit). Tu travailles dans ~/HyperBrowser-ia, un arbre de travail git sur la branche `ia`.
Une autre session (« navigateur ») travaille dans ~/HyperBrowser sur la branche `main` : elle écrit les yeux (carte de page), les mains (exécuteur d'actions) et l'interface. Toi, tu écris le service IA.
Réponds toujours en français. Méthode : une étape à la fois, code propre et commenté, des tests, et à la fin de chaque étape dis-moi ce qui marche, ce qui reste, comment tester.
Si un choix technique est ambigu, pose-moi la question au lieu de choisir seul.

LIS D'ABORD, dans cet ordre, avant toute action :
1. Docs/ia.md — le contrat, les précisions pour ce dépôt, les cinq étapes et leurs portes, les pièges connus. C'est la référence : si ce prompt et ce fichier se contredisent, dis-le-moi.
2. Package.swift, build_app.sh, scripts/test.sh.
3. Le modèle à imiter pour un service local : Sources/DownloadProtocol/ (XPC.swift, AgentInstaller, LocalEngine), Sources/OreeDownloader/, Docs/DOWNLOAD_ENGINE_PLAN.md.

TA MISSION : L'ÉTAPE 1 UNIQUEMENT, « le cerveau seul ». Un service qui charge Qwen3.5-2B (GGUF Q4_K_M) avec llama.cpp et répond à une question en français, sans outils ni LoRA, avec des états chaud / tiède / froid et un pré-réveil. Les étapes 2 à 5 ne sont pas à toi pour l'instant : n'écris ni carte de page, ni exécuteur d'actions, ni interface, ni LoRA.

TU NE TOUCHES PAS à Sources/BrowserUI ni à Sources/BrowserCore, sauf accord explicite de ma part (une ligne à la fois, dans un commit à part). Tout ton code vit dans de nouvelles cibles : `OreeAIProtocol` (protocole XPC et événements, sans dépendance, partagé avec la session navigateur), `OreeAIService` (exécutable, llama.cpp), plus les tests. Modifie Package.swift et build_app.sh seulement pour les brancher.

TRAVAIL EN TROIS TEMPS — arrête-toi et attends mon accord entre chacun :
A. VÉRIFICATIONS, sans écrire de code. Donne-moi les faits, avec les liens :
   - la licence du dépôt OFFICIEL Qwen/Qwen3.5-2B (le plan renvoie à un dépôt tiers « UraionLabs/Uraion-Agent-Small » : ne l'utilise pas sans le vérifier), et d'où vient le GGUF Q4_K_M à utiliser (conversion officielle ou non) ;
   - la dernière version de llama.cpp qui publie `llama-<build>-xcframework.zip` ET connaît l'architecture `qwen35` ; la taille et la somme SHA-256 réelles du GGUF ;
   - comment le moteur de téléchargement d'Orée (Sources/DownloadKit) peut télécharger ce fichier avec reprise.
B. PLAN COURT (une page, pas de code) : les cibles, le protocole `OreeAIServiceXPC` et l'observateur d'événements (même méthode que DownloadServiceXPC / DownloadObserverXPC, événements en JSON Codable), les états chaud/tiède/froid, ce que tu mesureras, les tests prévus.
C. RÉALISATION, dans cet ordre : d'abord `OreeAIProtocol`, commité seul (la session navigateur code contre lui) ; puis le service ; puis les mesures ; puis le rapport.

CONTRAINTES TECHNIQUES
- Ce Mac est un M1 de 8 Go sous macOS 27, avec seulement les Command Line Tools : PAS d'Xcode, PAS de compilateur Metal (`xcrun metal` échoue). Ne compile jamais llama.cpp : prends le `llama.xcframework` précompilé en `binaryTarget` avec somme de contrôle. Les tests se lancent avec ./scripts/test.sh --fast (ou --all) et l'app avec ./build_app.sh --debug.
- Le service est un agent launchd à la demande avec un service Mach, comme le téléchargeur. SÉCURITÉ DÈS LE PREMIER JOUR : appelle `setCodeSigningRequirement` dans `shouldAcceptNewConnection` pour n'accepter que Orée (le téléchargeur ne le fait pas : point ouvert de l'audit du 10 octobre, ne le recopie pas).
- Le modèle n'est ni dans git ni dans l'app. Il se télécharge à la demande dans ~/Library/Application Support/HyperBrowser/Models/, et sa somme SHA-256 (épinglée dans le code) est vérifiée avant tout chargement. Préviens-moi avant tout téléchargement de plus de 500 Mo.
- Réglages du modèle : pénalité de répétition 1.0, mode réflexion désactivé, poids chargés par mmap. Ne jamais écrire à la main le XML des appels d'outils (le chat_template de Qwen3.5 s'en charge ; sans objet à l'étape 1).
- Ne touche pas à `LocalModel` ni aux fonctions qui utilisent le modèle d'Apple : c'est un autre système, qui reste.

RÈGLES DE SÉCURITÉ POUR LES ESSAIS (importantes : un incident a déjà exposé l'historique de l'utilisateur)
- Ne lance jamais l'app de l'utilisateur et ne tue que les processus que tu as lancés toi-même. N'ouvre jamais le plein écran, ne prends jamais le focus ni l'écran.
- Toute instance d'essai se lance comme suit, SANS EXCEPTION : open -g -n --env HB_FRESH_SESSION=1 --env HB_DB_PATH=<fichier jetable> --env HB_EXT_DIR=<dossier vide> Oree.app --args --automation. Sans HB_DB_PATH, une instance d'essai écrit dans la vraie base et le vrai historique de l'utilisateur.
- N'écris jamais dans ~/Library/Application Support/HyperBrowser/ en dehors du dossier Models/.

PORTE DE L'ÉTAPE 1 (à franchir avant de proposer la fusion dans main) : le service répond à une question en français ; l'app se construit avec ./build_app.sh --debug ; un test de protocole avec un faux moteur passe ; la connexion XPC est refusée à un client non signé par Orée ; et un tableau de mesures, relevé sur ce Mac, est écrit dans Docs/ia-mesures.md : chargement à froid, pré-réveil (madvise WILLNEED + cache KV), jetons par seconde, mémoire résidente et empreinte dans chacun des trois états, avec et sans le navigateur ouvert. Les chiffres cibles des étapes suivantes se fixent d'après ces mesures : n'invente aucun chiffre, écris « non mesuré » quand c'est le cas.

COMMITS : titres en français lisibles par un utilisateur (ils deviennent les notes de version), un commit par étape logique, et ne pousse jamais. Termine chaque message de commit par : Co-Authored-By: Claude <noreply@anthropic.com>

COMMENCE PAR LE TEMPS A (vérifications). Réponds-moi avec les faits, puis attends.
```
