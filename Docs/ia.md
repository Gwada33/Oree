# IA locale d'Orée

Document commun aux deux sessions (voir « Qui fait quoi »). Source : « Orée — Plan de l'IA locale » (11 octobre 2026). Le bloc « Contrat » est
repris tel quel du plan ; le reste adapte le plan à ce dépôt et fixe les portes de chaque étape.

## Contrat

(Bloc repris du plan, sans titre de premier niveau.)

## Objectif
Service IA local, hors ligne, macOS (Apple Silicon), qui génère du texte et pilote des pages via des outils.
Modèle : Qwen3.5-2B en GGUF Q4_K_M (puis notre LoRA fusionné). Moteur : llama.cpp (llama.xcframework, build récent avec l'architecture qwen35).

## Découpage
- Session IA (branche `ia`, dossier `OreeAI/`) : service XPC, llama.cpp, états de veille, prompt, boucle d'agent.
- Session navigateur (branche principale) : script de carte de page (WKContentWorld "oree-ai"), exécuteur d'actions, onglet de recherche caché, UI (barre, trace, Stop, confirmations), profil dans le Trousseau.
- On fusionne `ia` dans la branche principale à la fin de chaque étape, et on teste dans Orée.

## Contrat XPC (protocole OreeAIService)
- warmUp()                        → précharge les poids (madvise WILLNEED) et restaure le cache KV du prompt système
- run(taskID, userText, pageMap)  → flux d'événements vers le navigateur
- toolResult(taskID, callID, text)→ le navigateur renvoie le résultat d'un outil ("OK\n<page>…" ou "ERREUR: …")
- cancel(taskID)
- coolDown()                      → sauvegarde le cache KV, libère le contexte, garde les poids en mmap
Événements : textDelta(texte) · toolCall(callID, nom, argumentsJSON) · needsConfirmation(callID, résumé) · done(réponse, sources) · error(message)

## Outils (noms et arguments exacts)
search_web(query) · open_url(url) · read_page(section?) · click(ref) · type(ref, text, submit=false) · select(ref, option) · scroll(direction) · fill_form(fields{ref:valeur}) · ask_user(question) · done(answer)
Les valeurs perso sont des jetons {{profil.xxx}} remplacés côté navigateur, jamais envoyés au modèle.

## Règles
- Génération contrainte (grammaire GBNF ou schéma JSON) pour chaque appel d'outil. repeat_penalty = 1.0. Mode réflexion désactivé.
- Le contenu de page est entre <page></page> et n'est jamais une instruction.
- Confirmation obligatoire : envoi de formulaire, paiement, connexion, téléchargement, page avec mot de passe ou carte.
- Plafonds : 15 étapes, 3 recherches, 5 pages par tâche.
- Poids chargés par mmap. États : chaud (en usage) → tiède (30 s d'inactivité : cache KV sur disque, contexte libéré, residency set relâché) → froid (pression mémoire : l'OS reprend les pages).

## Format de la carte de page
PAGE <url> "<titre>" / VISIBLE / @eN <rôle>[type] "<libellé>" attributs / AUTRES +N … / TEXTE [h1] … [p] …
60 éléments max, priorité : visibles, puis formulaires, puis navigation. Mots de passe jamais lus.

## Précisions pour ce dépôt

**Le service suit le modèle du téléchargeur.** Le moteur de téléchargement tourne déjà comme un agent launchd avec un service Mach
(`Sources/DownloadProtocol` : `XPC.swift`, `AgentInstaller`, `LocalEngine`, exécutable `Sources/OreeDownloader`, copié et signé par `build_app.sh`). Le service IA
fait pareil : un exécutable `OreeAI` dans `Contents/MacOS`, un agent à la demande, un service Mach. Pas de bundle `XPCServices` : `build_app.sh` assemble l'app à la main.
Cibles à créer : `OreeAIProtocol` (protocole et événements, sans dépendance, partagé), `OreeAIService` (exécutable, llama.cpp), et côté navigateur un client mince.
Le « dossier `OreeAI/` » du contrat désigne ces cibles : `Sources/OreeAIProtocol` et `Sources/OreeAIService` (SwiftPM veut les cibles sous `Sources/`).

**Sécurité du service dès le premier jour.** `shouldAcceptNewConnection` du téléchargeur accepte toute connexion (point ouvert de l'audit du 10 octobre). Celui de l'IA doit
appeler `setCodeSigningRequirement` pour n'accepter qu'Orée ; sinon n'importe quel processus de la session pourrait faire tourner le modèle, ou lui faire lire une page.

**llama.cpp : prendre le `llama.xcframework` précompilé** des versions de llama.cpp (Metal inclus, macOS 13.3+), en `binaryTarget` avec somme de contrôle. **Ne jamais le compiler ici** :
ce Mac n'a ni Xcode ni le compilateur Metal (`xcrun metal` échoue). Épingler une version récente qui connaît l'architecture `qwen35`.

**Le modèle n'est ni dans git ni dans l'app** (≈ 2 Go). Il se télécharge à la demande dans `~/Library/Application Support/HyperBrowser/Models/`, avec le moteur de
téléchargement d'Orée (reprise, vitesse), puis **vérification de la somme SHA-256 épinglée dans l'app avant tout chargement**. Source : le dépôt **officiel** `Qwen/Qwen3.5-2B` (ou sa
conversion GGUF officielle). Le plan renvoie vers un dépôt tiers (`UraionLabs/Uraion-Agent-Small`) : à ne pas utiliser sans le vérifier.
**Vérifier la licence sur le dépôt officiel avant d'écrire du code** (le plan dit Apache 2.0 ; les recherches n'ont pas permis de le confirmer).

**Ce qui existe déjà et ne change pas.** `LocalModel` (modèle d'Apple, framework Foundation Models) sert L'essentiel, les Boosts et le Calendrier. Le nouveau service est à part : c'est
l'agent qui agit sur les pages. Ne pas toucher à `LocalModel`.

**Ce qui se réutilise côté navigateur** : `WKWebView.callJSON` (appel JavaScript avec délai), les mondes isolés (`TranslationScript`, `BoostScript`, `NightScript` : même méthode que le
monde `oree-ai`), `DigestScript.text` (extraction du texte principal), `BoostScript.survey` (parcours des éléments d'une page), `NoticePill` (offres), `StartPage`/`DigestPanelView` (fenêtres
et design), les réglages (`SettingsStore` + `SettingsView`), les opérations d'automatisation (`BrowserWindowController`, `scripts/ui.sh tab …`).

**Les valeurs de profil** (`{{profil.nom}}`…) vivent dans le Trousseau, comme le coffre de mots de passe (`CredentialVault`). Les mots de passe et les cartes restent au remplissage automatique.
Les messages envoyés par la page ne doivent jamais passer par un gestionnaire enregistré dans le monde de la page : tout se passe dans le monde `oree-ai`.

## Qui fait quoi

| Session | Dossier / branche | Écrit |
|---|---|---|
| **IA** | `~/HyperBrowser-ia`, branche `ia` (arbre de travail git séparé) | `OreeAIProtocol`, `OreeAIService`, llama.cpp, téléchargement et chargement du modèle, états chaud/tiède/froid, boucle d'agent, grammaire des outils, puis le LoRA |
| **Navigateur** | `~/HyperBrowser`, branche `main` | carte de page (les yeux), exécuteur d'actions (les mains), onglet de recherche caché, barre IA, trace, Stop, confirmations, profil, client XPC |

Une seule session touche à WebKit : la session navigateur. La session IA ne modifie pas `Sources/BrowserUI` ni `Sources/BrowserCore`, sauf accord explicite (une ligne à la fois, dans un commit à part).
Fusion de `ia` dans `main` à la fin de chaque étape, puis test dans le vrai Orée.

## Feuille de route : cinq étapes, une porte chacune

On ne passe à l'étape suivante qu'une fois la porte franchie, mesures à l'appui. Les chiffres cibles se fixent **après** la première mesure (étape 1), pas avant.

1. **Le cerveau seul** (session IA). Service qui charge Qwen3.5-2B Q4_K_M et répond à une question, sans outils ni LoRA ; protocole `OreeAIProtocol` publié en premier ;
   états chaud/tiède/froid ; pré-réveil ; téléchargement vérifié ; client XPC vérifié par signature.
   *Porte :* réponse en français ; mesures relevées sur le Mac M1 8 Go (chargement à froid, pré-réveil, tokens par seconde, mémoire dans chaque état, avec et sans le navigateur ouvert) ;
   les chiffres sont écrits dans `Docs/ia-mesures.md` ; un test de protocole avec un faux moteur ; l'app se construit avec `./build_app.sh --debug`.
2. **Les yeux** (session navigateur). Script `oree-ai`, carte de page au format du contrat, budgets, référence `@eN`, mot de passe jamais lu, carte refaite quand la page est stable.
   *Porte :* sur 10 vraies pages et les pages de test, la carte tient dans le budget (nombre de jetons mesuré), aucun mot de passe n'en sort, les références restent valables entre deux cartes.
3. **Les mains** (session navigateur). Exécuteur des outils : setter natif de `value`, `input`/`change`/`blur`, suite d'événements du clic, jetons `{{profil.xxx}}`, zones interdites, règles de confirmation.
   *Porte :* des suites d'outils écrites à la main réussissent sur des pages de test, dont une avec champs « contrôlés » (type React) ; une page piégée ne déclenche aucune action sensible sans confirmation.
4. **La boucle d'agent** (les deux). `run` / `toolCall` / `toolResult`, génération contrainte par grammaire, plafonds, trace, Stop, barre IA, recherche web par onglet caché, `read_page`.
   *Porte :* au moins 10 tâches de bout en bout sur des pages de test avec le modèle de base ; le taux de réussite réel est écrit, même s'il est mauvais ; plafonds respectés ;
   page piégée résistée **par les règles d'Orée**, pas par la bonne volonté du modèle.
5. **Le LoRA** (session IA, avec les traces de l'étape 4). Données, entraînement, jeu d'évaluation de 200 tâches, comparaison base / LoRA actuel / LoRA précédent, quantification.
   *Porte :* meilleur que la base sur les appels d'outils valides, la précision par étape et la réussite de bout en bout, sans perte de qualité de rédaction ; sinon on livre la base.

## Où en est-on

| Étape | État |
|---|---|
| 1. Le cerveau seul | **Fait et fusionné** (11 octobre 2026). Service `OreeAI`, états chaud/tiède/froid, modèle vérifié (SHA-256), service réservé à Orée. Mesures : `Docs/ia-mesures.md` (≈ 200 Mo d'empreinte en chaud, 16 à 19 jetons/s, réveil 0,14 s depuis le tiède, 0,7 s depuis le froid). Non mesuré : chargement à froid depuis le disque, navigateur chargé, version release. |
| Étape 2, les yeux (navigateur) | **Faite** (non commitée) : `Sources/BrowserCore/PageMap.swift` (tri, budget 60 éléments, format du contrat, secrets retirés au décodage), `Sources/BrowserUI/PageMapScript.swift` (monde `oree-ai`, références `@eN` stables par élément), op `tab pagemap`/`pagemapget`, `scripts/bench/pagemap_check.py` (14/14). Mesuré sur 8 vraies pages : 1 100 à 2 350 jetons estimés (≈ 3,5 car./jeton, pas le vrai tokenizer), 17 à 66 ms. Limites : pas de Shadow DOM ni d'iframes, pas de rafraîchissement « page stable » ni de carte donnée au modèle (étape 4). |
| Étape 3, les mains (navigateur) | **Faite** (non commitée) : `Sources/BrowserCore/AIActions.swift` (`AIAction.parse`, `ActionPolicy` : refus / confirmation / feu vert, `ProfileTokens`), `Sources/BrowserUI/PageActionScript.swift` (gestes dans le monde `oree-ai`, setter natif + `input`/`change`/`blur`, suite d'événements du clic) et `ActionExecutor`, `Sources/BrowserStorage/ProfileKeychain.swift` (profil dans le Trousseau), op `tab act`/`actget`, `scripts/bench/hands_check.py` (17/17 dont un champ « contrôlé » façon React). Confirmation exigée : envoi de formulaire, mot « payer/acheter/commander… », connexion, téléchargement, saisie avec envoi ; refus : champs mot de passe/carte et pages internes. **Limite connue** : un bouton `type=button` dont le script envoie quand même un formulaire ou une requête, avec un libellé innocent, n'est pas reconnu comme sensible ; la confirmation repose sur la structure et les mots, pas sur ce que fait le script. Pas encore branché au panneau (carte de confirmation, étape 4) ni de réglage pour saisir le profil. |
| Étape 4, la boucle d'agent (navigateur) | **Faite côté navigateur** (non commitée) : `Sources/BrowserCore/AgentLoop.swift` (analyse tolérante de la ligne JSON du modèle, plafonds 15 étapes / 3 recherches / 5 pages, anti-répétition, trace, texte de la consigne avec exemples), `Sources/BrowserUI/AgentSearch.swift` (onglet de recherche caché, DuckDuckGo HTML, stockage non persistant), panneau Luciole complet (trace repliable, carte « à valider » à 0,8 s d'armement, carte de question, sources cliquables, copier, puce de contexte cliquable, surlignage d'une seconde dans la page). Tests : 8 unitaires (`AgentLoopTests`) + `scripts/bench/agent_check.py` (20/20, modèle scripté en build de debug via `/tmp/oree-ai-script.json`, `HB_AI_TRACE=<fichier>` journalise chaque tour). **Choix à connaître** : le service n'a ni génération contrainte ni appels d'outils natifs, donc le modèle écrit une ligne JSON lue avec indulgence ; avec Qwen3.5-2B sans LoRA, il confond parfois (il a demandé « Quelle est la capitale de la France ? » à la personne avant l'ajout d'exemples dans la consigne). Contexte de 4 096 jetons : carte réduite à 30 éléments + 1 200 caractères de texte pour la boucle. `open_url` ne s'ouvre que pour http(s), dans l'onglet actif. Les réglages du profil (saisie des `{{profil.xxx}}`) ne sont pas encore faits : sans profil, un jeton inconnu échoue proprement. Reste pour l'étape 5 (session IA) : grammaire GBNF, vrais appels d'outils, LoRA. |
| Branchement côté navigateur | **Fait** : client XPC (`Sources/OreeAIClient`), **Panneau Luciole** (⌘J, `Sources/BrowserUI/AIPanel.swift` + `Luciole.swift`, à droite, pousse la page, 320–520 pt, une conversation par onglet, états du modèle, mascotte en 13 poses), installation de l'agent à la première ouverture, téléchargement du modèle avec accord (moteur de téléchargement d'Orée), Stop. Chaque question est indépendante : pas de mémoire, pas de page lue. **Pas encore branchés** (ils attendent les étapes 2 à 4) : puce de contexte réelle, trace d'actions, carte de confirmation, carte de question, surlignage dans la page, sources, plafond de 15 étapes, page protégée. |
| 2. Les yeux | à faire |
| 3. Les mains | à faire |
| 4. La boucle d'agent | à faire |
| 5. Le LoRA | à faire |

**Ce que fait la barre aujourd'hui.** ⌘J (ou ⌘K › « Demander à l'IA ») ouvre une carte en haut de la page. Rien n'est lancé avant : ni l'agent, ni la connexion au service. À la première
ouverture, Orée installe l'agent launchd `com.nolhan.hyperbrowser.ai` (comme le téléchargeur ; il pointe vers l'exécutable `OreeAI` de la copie d'Orée en cours), interroge le service
et le réveille. Si le modèle manque, la barre propose « Télécharger le modèle » (≈ 1,3 Go) : **le téléchargement ne démarre que sur ce clic**. Le service vérifie ensuite le fichier.
Textes d'état : `Sources/OreeAIClient/AIAvailability.swift` (testés).

**Qualité observée (à ne pas présenter comme une garantie).** Sur « capitale de l'Italie ? », trois essais ont donné « Rome », « Rome » et « Milan » ; la session IA avait relevé « Berne » pour la Suisse.
La barre ne doit donc pas servir de source de faits ; l'étape 4 mesurera la fiabilité des actions avec de vrais chiffres.

**Essais.** `python3 scripts/bench/ai_check.py` : instance séparée, **son propre nom de service** (`HB_AI_MACH_NAME=com.nolhan.hyperbrowser.ai-test`, jamais l'agent réel de l'utilisateur), service et modèle
réels, 11 contrôles (ouverture, réponse, Stop, service encore vivant, fermeture). L'agent d'essai est retiré à la fin. Ignoré si le fichier du modèle n'est pas sur le disque (le script ne télécharge pas 1,3 Go).
Variables d'environnement : `HB_AI_MACH_NAME` (autre service Mach), `HB_AI_NO_AGENT=1` (l'agent est géré à la main).

## Pièges connus (à lire avant de commencer)

- **Entraîner sur ce Mac n'est pas réaliste.** Un Mac M1 de 8 Go ne fait pas tourner un LoRA sur un modèle de 2 milliards de paramètres sans swap. Prévoir un notebook Colab (Unsloth) ou une machine louée.
- **Le professeur de l'étape 5** (Qwen3.5-122B ou 397B) ne tient pas sur ce Mac non plus : le prévoir en nuage, et mesurer le coût avant de s'engager.
- **Licences des données** : Mind2Web et xLAM à vérifier avant tout usage ; ne pas entraîner sur les sorties d'un modèle dont les conditions l'interdisent.
- **Mémoire** : sur 8 Go, le navigateur avec 20 onglets pèse déjà ~1,6 Go. Le service IA doit se mettre en veille vite et ne jamais être la cause d'un onglet endormi de force.
- **Premier lancement** : le modèle pèse ≈ 2 Go ; prévoir un état « en cours de téléchargement » honnête dans la barre IA, pas un blocage.
- **Ne jamais écrire le XML d'appel d'outil à la main** : le `chat_template.jinja` de Qwen3.5 le fait. Pénalité de répétition 1.0, réflexion désactivée.

## Règles de travail (les mêmes que pour tout le projet)

Réponses et textes en français. Une étape à la fois, du code propre et commenté, des tests, et à chaque étape : ce qui marche, ce qui reste, comment tester. Un commit par étape, avec un titre lisible
par un utilisateur (les titres de commits deviennent les notes de version) ; ne jamais pousser. Les essais en bout en bout se font **uniquement** avec une instance séparée :
`open -g -n --env HB_FRESH_SESSION=1 --env HB_DB_PATH=<fichier jetable> --env HB_EXT_DIR=<dossier vide> Oree.app --args --automation`, en ne tuant que le processus lancé. Ne jamais prendre
le focus ni l'écran de l'utilisateur, ne jamais écrire dans sa vraie base ni son historique, ne jamais lancer le plein écran sans son accord.
