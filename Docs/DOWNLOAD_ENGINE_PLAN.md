# Moteur de téléchargement d'Orée — exploration et plan d'architecture

*(état : **phases 1 et 2 livrées** — sections 6 et 7 ; phases 3 à 5 à faire)*

## 1. Ce que j'ai trouvé dans le projet

**Téléchargements actuels** (tout dans le processus principal) :
- `BrowserWindowController` : `WKDownload` + `WKDownloadDelegate` (destination = Téléchargements, nom sans collision, quarantaine à la fin via `Quarantine.apply`, reprise par `resumeData` sur coupure).
- `DownloadsCenter` (liste en mémoire, progression par KVO sur `NSProgress`), bouton de barre d'outils + anneau + `NSPopover` (`DownloadsListView`), panneau latéral « Téléchargements ».
- Défaut corrigé hier : la méthode de décision « afficher / télécharger » n'était jamais appelée (avertissement « nearly matches » ignoré). À garder comme règle : **traiter tout avertissement de conformité de protocole comme une erreur**.

**Contraintes techniques du projet**
- SwiftPM, Swift 6, macOS ≥ 15.4 (tourne sur macOS 27). L'app est assemblée à la main par `build_app.sh` (pas de projet Xcode) et signée **ad hoc** : `security find-identity` = 0 identité. Conséquences : pas de Developer ID, pas de notarisation, pas de `SMAppService` fiable (il exige en pratique une signature valide et l'app dans /Applications), vérification d'appelant XPC limitée à un *identifier* (pas de Team ID).
- Disque APFS : fichiers creux et `fcntl(F_PREALLOCATE)`/`ftruncate` disponibles.
- Outils de mesure déjà là : `footprint`, `proc_pid_rusage` (utilisés pour le budget mémoire) → je les réutilise pour la mesure « 5 × 1 Go ».
- Tests : `./scripts/test.sh` (Swift Testing). Pas encore de serveur HTTP de test dans Swift ; il y a un serveur Python dans `scripts/bench`.

## 2. Architecture proposée

```
┌─────────────── Orée (processus principal) ───────────────┐
│ WKDownload ──(intercepte: URL, requête, réponse)──┐      │
│ WKWebsiteDataStore ──(cookies du domaine seul)────┤      │
│ DownloadsModel (@MainActor, @Observable-like)     │      │
│   ▲  progression/état (XPC, push)                 ▼      │
│   └────────────── DownloadClient (actor) ────────────────┼──XPC──┐
└──────────────────────────────────────────────────────────┘       │
┌──────────────── OreeDownloader (processus séparé) ───────┐◄──────┘
│ DownloadService (NSXPCListener)                           │
│  DownloadManager (actor)  ── planificateur (phases 2/4)   │
│   DownloadJob (actor) ── Probe → SegmentPlan → N workers  │
│   SegmentWriter (pwrite sur fichier creux, blocs 64–256Ko)│
│   StateStore (JSON atomique, ETag/Last-Modified, offsets) │
│   HashStreamer (SHA-256 incrémental) · NWPathMonitor      │
└───────────────────────────────────────────────────────────┘
```

### Nouveaux modules SwiftPM
| Cible | Rôle | Dépend de |
|---|---|---|
| `DownloadKit` (bibliothèque, Swift pur) | Segmentation, plan de reprise, état persistant, hash en flux, politiques (backoff, Retry-After), `DownloadJob`/`DownloadManager` | Foundation, CryptoKit, Network |
| `DownloadProtocol` (bibliothèque minuscule) | Protocole `@objc` XPC + modèles `Codable`/`NSSecureCoding` partagés app ↔ service | Foundation |
| `OreeDownloader` (exécutable) | Hôte XPC fin autour de `DownloadKit` | DownloadKit, DownloadProtocol |
| `BrowserUI` (existant) | `DownloadClient`, nouvelle interface, branchement `WKDownload` | DownloadProtocol |

`DownloadKit` ne connaît ni XPC ni AppKit → **testable seul** (segmentation, reprise, hash, serveur local).

### Interface XPC (phase 1)
`start(request: DownloadRequest, reply)`, `pause(id)`, `resume(id)`, `cancel(id)`, `list(reply)`, et `subscribe(observer)` : le service **pousse** `progress(id, bytes, total, speed, state)` (≤ 4 fois/s, regroupé). `DownloadRequest` = URL, en-têtes de la requête d'origine (sans `Cookie`), cookies **filtrés sur le domaine de l'URL**, URL de la page d'origine, nom suggéré, dossier de destination (validé : sous Téléchargements ou dossier choisi par l'utilisateur).

### Déroulement d'un téléchargement
1. `WKDownload` signale la réponse → **je ne réponds pas tout de suite** à `decideDestination` (la méthode est `async`) : je transmets au moteur, qui fait la **sonde** (`GET Range: bytes=0-0` plutôt que HEAD, que certains CDN refusent).
2. Sonde OK + `Accept-Ranges: bytes` + taille connue → le moteur prend le relais, je renvoie `nil` (WKDownload annulé) → pas de double téléchargement.
3. Sinon (pas de Range, taille inconnue, URL à usage unique qui échoue, auth non-cookie, `blob:`/`data:`/POST) → **repli** : on renvoie la destination à `WKDownload` et le flux actuel (avec `resumeData`) continue, mais suivi dans le même modèle d'interface.
4. Fichier pré-alloué (creux) → N segments → workers `URLSession` (HTTP/2/3 laissés au système) qui écrivent par `pwrite` à leur offset, sans jamais garder plus d'un bloc en mémoire.
5. Fin : fsync, quarantaine + `WhereFroms`, hash disponible, notification au client.

### Tenir « quitter le navigateur sans arrêter »
Deux façons de lancer le service, sans changer le code du moteur :
- **A. Service XPC dans le bundle** (`Contents/XPCServices/OreeDownloader.xpc`) : simple, fonctionne en signature ad hoc, mais **s'arrête quand Orée quitte** → les téléchargements se mettent en pause et **reprennent au prochain lancement** (état persistant). 
- **B. LaunchAgent utilisateur** (`~/Library/LaunchAgents/com.nolhan.hyperbrowser.downloader.plist`, service Mach à la demande, écrit et chargé par l'app avec `launchctl bootstrap gui/<uid>`) : **survit à la fermeture** de l'app, démarre à la demande, se termine seul quand il n'a plus de travail. macOS affiche une notification « élément d'ouverture ajouté » et l'utilisateur peut le désactiver (Réglages Système ▸ Éléments de connexion). Sans signature valide, `SMAppService` n'est pas fiable, donc je passerais par `launchctl` ; le chemin de l'exécutable est mis à jour à chaque lancement si l'app est déplacée.

**Recommandation : B**, avec A comme repli automatique si l'enregistrement échoue.

### Sécurité et respect des serveurs
- Cookies/identifiants : seulement ceux du domaine de l'URL ; jamais envoyés à un miroir d'un autre domaine (liste blanche par hôte et redirections suivies uniquement si même site).
- Service XPC : refuse les appelants autres qu'Orée (exigence de code `identifier "com.nolhan.hyperbrowser"` ; **limite connue** : en signature ad hoc elle n'est pas inviolable) ; destinations restreintes ; aucune écriture hors dossiers autorisés.
- Backoff exponentiel + jitter, `Retry-After` honoré, retour à 1 connexion sur refus (429/503/403 de parallélisme), jamais de connexions parallèles si le serveur refuse Range.
- DRM (phase 4) : flux HLS/DASH protégés **ignorés explicitement** (`#EXT-X-KEY: METHOD=SAMPLE-AES` / FairPlay, `ContentProtection` Widevine/PlayReady).

### Refonte de l'interface (demandée : « la partie téléchargement de la barre du haut est mal faite »)
Livrée dès la phase 1, sur le nouveau modèle :
- **Bouton de barre d'outils** : icône seule au repos (masquée s'il n'y a rien) ; pendant un téléchargement, anneau de progression global + débit total en infobulle ; « pop » à la fin.
- **Fenêtre flottante** (popover 360 px) : une ligne par fichier — icône de type (UTType), nom (milieu tronqué), « 124 Mo sur 480 Mo · 3,2 Mo/s · 2 min restantes », barre de progression 4 px dans la teinte d'accent, boutons Pause/Reprendre, Annuler, Afficher dans le Finder, Ouvrir ; état « Terminé » (+ badge SHA-256 en phase 3), « Échec » avec « Réessayer », « En attente de Wi-Fi » (phase 3/4) ; pied « Tout afficher » (panneau latéral).
- Animations du design system uniquement (120/180/260 ms, courbe unique, réduction de mouvement respectée).

## 3. Phasage, tests et mesures

| Phase | Contenu | Tests | Mesures |
|---|---|---|---|
| 1 | Sonde, segmentation Range, `pwrite` + fichier creux, resegmentation dynamique, reprise (ETag/Last-Modified), quarantaine, service XPC (A puis B), repli WKDownload, nouvelle UI | Unitaires : plan de segments, resegmentation, sérialisation/reprise, rejet si ETag changé, hash ; intégration : mini-serveur local (Network.framework) avec Range, coupures et ETag modifié ; XPC en boucle locale | Débit vs WKDownload, RAM principal + service pour 5 × 1 Go |
| 2 | Connexions adaptatives (1–16), miroirs (Metalink / `Link: rel=duplicate`), priorité à la navigation (API `browserLoadingChanged(Bool)`) | Simulateur de débit/erreurs 429/503 | Gain de débit |
| 3 | `NWPathMonitor` (pause/reprise réseau), SHA-256 en flux, checksum détecté dans la page | Hash par segments, coupure simulée | — |
| 4 | HLS/DASH sans DRM, rangement par règles, doublons, planification (réseau cher/limité, économie d'énergie) | Parseurs m3u8/mpd, règles | — |
| 5 | `kMDItemWhereFroms`, Quick Look progressif, `NSProgress` publié (Dock/Finder) | — | — |

## 4. Risques et limites connus (à valider avec toi)
1. **Signature ad hoc** : pas de notarisation, XPC vérifiable par *identifier* seulement, LaunchAgent via `launchctl` (pas `SMAppService`).
2. **URLs à usage unique / auth non-cookie** : le moteur ne peut pas toujours rejouer la requête → repli WKDownload (c'est pourquoi la décision est prise *avant* d'annuler le flux du navigateur).
3. **`WKDownload` gaspille les premiers octets** de la réponse initiale quand le moteur prend le relais (négligeable en pratique).
4. **Quick Look progressif** (phase 5) dépend du format ; certains conteneurs vidéo (moov en fin de fichier) ne sont lisibles qu'à la fin.
5. **Courtoisie envers les serveurs** : la limite par défaut sera prudente (4 connexions) tant que l'adaptatif (phase 2) n'est pas là.

## 5. Questions de décision
1. **Service A (arrêt avec l'app, reprise au lancement) ou B (LaunchAgent, survit à la fermeture) ?** — recommandation : B avec A en repli.
2. **Connexions par défaut en phase 1** : 4 (prudent) ou 8 ?
3. **Dossier de destination** : Téléchargements par défaut, avec choix d'un autre dossier dès la phase 1 ou seulement en phase 4 (règles) ?

## 6. Phase 1 — ce qui est fait (9 octobre 2026)

**Décisions prises** (recommandations du plan) : agent launchd avec repli en processus (B puis A-local), 4 connexions, destination = Téléchargements.

| Élément | Où |
|---|---|
| Sonde `GET Range: bytes=0-0`, taille / ETag fort / Last-Modified / nom (Content-Disposition) | `DownloadKit/RangeSession.swift`, `HTTPParsing.swift` |
| Segmentation + resegmentation (le plus gros reste coupé en deux) | `SegmentPlanner.swift`, `DownloadJob.swift` |
| Fichier creux + `pwrite` par blocs réseau, jamais le fichier en mémoire | `SegmentFile.swift` |
| État persistant atomique, reprise, redémarrage propre si ETag / taille changent | `StateStore.swift`, `DownloadManager.resume` |
| Backoff exponentiel, `Retry-After`, moins de connexions sur 429/503 | `HTTPParsing.Backoff`, `DownloadJob.runSegment` |
| Cookies du domaine seulement, retirés lors d'une redirection vers un autre hôte | `CookieHeader`, `RangeSession` |
| Quarantaine macOS à la fin | `DownloadQuarantine` |
| Service XPC + client + agent launchd (`launchctl bootstrap`), vérification de l'appelant par identifiant | `DownloadProtocol/*`, `OreeDownloader/main.swift` |
| Repli `WKDownload` (sans Range, onglet privé, requête non GET) dans la même liste | `BrowserUI/DownloadsController.swift` |
| Nouvelle interface (bouton + anneau, fenêtre à lignes, pause / reprise / annuler / afficher) | `BrowserUI/DownloadsPanel.swift` |

**Tests** : 31 tests dédiés (segmentation, analyse HTTP, reprise après pause, reprise après « relance », fichier modifié, 429 + Retry-After, sans Range, destination refusée, cookies non transmis, XPC en boucle locale, plist de l'agent) — dont 9 d'intégration contre un serveur local avec Range (`Tests/DownloadKitTests/TestServer.swift`).

**Vérifié à la main avec le vrai agent** : octets exacts (motif connu), fichier marqué en quarantaine, pause puis reprise, **fermeture de l'app pendant un téléchargement → l'agent continue** (≈ 28 Mo/s mesurés), **relance de l'app → elle retrouve le téléchargement en cours**, refus d'un client d'une autre identité.

**Mesures** (`scripts/bench/dl_ram_bench.py`, serveur local, 5 × 1 Go simultanés, 4 connexions chacun) :

| | Débit total | Mémoire app (footprint) | Mémoire moteur |
|---|---|---|---|
| Moteur (Range, processus séparé) | **≈ 540 Mo/s** (9,9 s) | 83 Mo → 83 Mo (**+0**) | 4 → 90 Mo |
| Ancien chemin `WKDownload` (même serveur sans Range) | ≈ 250 Mo/s (21,6 s) | 56 → 63 Mo (+7) | — |

Limites de ces chiffres : serveur local (le gain sur Internet dépend du serveur et de la ligne) ; la mémoire du processus réseau de WebKit n'est pas comptée dans la ligne « app » du chemin WKDownload.

**Limites connues**
- Signature ad hoc : la vérification de l'appelant XPC repose sur l'identifiant `com.nolhan.hyperbrowser` ; un programme qui se signerait avec le même identifiant passerait. Pas de notarisation.
- macOS affiche une notification « élément d'ouverture ajouté » à la première installation de l'agent ; il se désactive dans Réglages Système ▸ Général ▸ Ouverture.
- Déplacer l'app change le chemin de l'agent : il est réenregistré au lancement suivant.
- Pas encore : connexions adaptatives, miroirs, priorité à la navigation (le signal « page en chargement » est déjà transmis au service), reprise réseau, SHA-256, flux HLS/DASH, règles de rangement, doublons, planification, Spotlight, Quick Look, Dock (phases 2 à 5).
- Dossier de destination : Téléchargements uniquement pour l'instant.

## 7. Phase 2 — ce qui est fait (9 octobre 2026)

| Élément | Où |
|---|---|
| **8. Connexions adaptatives** (1 à 16, borne réglable) : départ à 2, +1 (ou +2 si le gain dépasse 50 %) tant que le gain est ≥ 10 %, retour arrière + pause de 20 s si une connexion n'apporte rien, −1 et pause de 45 s sur 429/503, pas d'ajout dans les derniers 8 Mo | `Adaptive.swift`, `DownloadJob.adapt()` |
| **9. Course entre miroirs** : `Link: rel=duplicate` et fichiers Metalink 4 ; un miroir n'est gardé que s'il sert le même fichier (même taille + même ETag ou même Last-Modified) et gère Range ; les premières connexions sont réparties sur toutes les sources, puis chacune reçoit une part proportionnelle à sa vitesse par connexion ; une source < 25 % de la meilleure est écartée ; un miroir en panne est abandonné sans toucher à l'origine ; **jamais de cookies vers un autre hôte** | `SourceSet`, `DownloadManager.discoverMirrors`, `Metalink`, `HTTPParsing.links` |
| **10. Priorité à la navigation** : « page en chargement » → les téléchargements ne gardent que 30 % de leur temps de transmission (les connexions sont suspendues par tranches de 100 ms, le contrôle de flux TCP fait le reste), vitesse rétablie 1 s après la fin du chargement, jamais plus de 30 s | `RangeSession.setShare`, `DownloadManager.setBrowsingActive`, `DownloadsController.pageLoading` |
| Réglages → Téléchargements : connexions max (1–16), adaptatif, miroirs, priorité à la navigation | `SettingsStore`, `DownloadsSection` |
| Interface : « ralenti pendant le chargement d'une page » dans la ligne ; infobulle « N connexions · M serveurs » | `DownloadsPanel.swift` |

**Tests** : 42 tests pour le moteur (+15 dans cette phase) — climbée / plafond / pause après saturation / retour arrière / minimum / fin de fichier du contrôleur ; analyse des en-têtes `Link` et de Metalink ; en intégration : montée de 2 à ≥ 4 connexions sur un serveur limité par connexion, budget fixe respecté, miroir rapide qui prend la main sans recevoir le cookie, miroir de taille ou de version différente ignoré, Metalink, throttle puis retour à pleine vitesse.

**Mesures** (`OreeDownloader --bench`, serveur Python local limité à 8 Mio/s **par connexion**, fichier de 640 Mo) :

| Mode | Durée | Débit moyen | Connexions max |
|---|---|---|---|
| 4 connexions fixes (phase 1) | 22,9 s | 29,3 Mo/s | 4 |
| **Adaptatif jusqu'à 16** | **13,6 s** | **49,3 Mo/s** (+68 %) | 12 |
| 1 connexion (téléchargement classique, 160 Mo) | 22,9 s | 7,3 Mo/s | 1 |

Fichier de 160 Mo (limité à 4 Mio/s par connexion) : sans miroir 12,2 s (13,7 Mo/s, 6 connexions) ; **avec un miroir rapide : 0,5 s (343 Mo/s)**. Mémoire du moteur : 5 à 13 Mo en mesure isolée (pic 90 Mo avec 5 × 1 Go en parallèle, phase 1).

**Vérifié avec le vrai agent** : le miroir fait passer 300 Mo en 1,5 s ; 8 connexions et 52 Mo/s sur le serveur limité ; la ligne passe en « ralenti » pendant le chargement de Wikipédia puis revient à la normale.

**Limites connues de la phase 2**
- Le gain adaptatif demande quelques secondes de montée : sur un petit fichier (160 Mo à 30 Mo/s) il ne bat pas 4 connexions fixes ; il gagne sur les fichiers longs et les serveurs qui limitent chaque connexion.
- « Plusieurs adresses IP du CDN » **n'est pas exploité** : URLSession choisit l'adresse lui-même et on ne peut pas en imposer une sans réécrire la couche TLS. Seuls les miroirs annoncés par le serveur (Link / Metalink) sont mis en concurrence.
- Un miroir est jugé « même fichier » sur la taille et les validateurs HTTP, pas sur le contenu : la vérification par SHA-256 arrive en phase 3.
- Le ralentissement par tranches de 100 ms est efficace quand le réseau est plus lent que les tampons du système ; sur une boucle locale très rapide (≈ 800 Mo/s) il ne retient que ~45 % au lieu de 70 % (mesuré).
- La part laissée aux téléchargements pendant le chargement (30 %) n'est pas encore réglable.
