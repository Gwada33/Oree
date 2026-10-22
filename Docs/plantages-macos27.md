# Plantages sur macOS 27 bêta (26A5388g)

Relevé du 22 octobre 2026 : 13 rapports `Oree-*.ips` (15 → 22 octobre), tous sur la version 1.1.0, tous dans le runtime Swift, jamais dans notre logique :

| Entrée | Rapports | Chemin du plantage |
|---|---|---|
| `MainActor.assumeIsolated` dans un minuteur ou un rappel (`startAudioTimer`, `AutomationServer`) | 5 | `swift_task_isCurrentExecutorWithFlags` → `SerialExecutorRef::isMainExecutor` → `objc_opt_class` / `swift_getObjectType` sur une référence d'exécuteur invalide (adresse 0x1e) |
| Point d'entrée `@objc` d'une classe `@MainActor` (`FlippedDocumentView.isFlipped`, `Tab.webView(for:)`, `JournalMessageHandler`, `webViewRenderingProgress`) | 7 | `_checkExpectedExecutor` → même chemin |
| Vrai défaut d'Orée : `devOp` appelé hors du thread principal | 1 | `_dispatch_assert_queue_fail` |

## Ce qui est corrigé (22 octobre 2026)
- `MainActor.assumeIsolated` (80 usages) est remplacé par `mainActorNow` (`BrowserCore/MainActorNow.swift`) : même contrat (on est sur le thread principal), vérifié par `dispatchPrecondition` au lieu de la question au runtime Swift qui plante. Cela couvre la première famille.

## Ce qui reste
- La deuxième famille (contrôles `_checkExpectedExecutor` que le compilateur insère dans les points d'entrée `@objc`) ne se corrige pas dans notre code. Le moyen est un réglage de compilation en release : `-Xfrontend -disable-dynamic-actor-isolation -Xfrontend -disable-actor-data-race-checks`. Il retire des vérifications de sécurité d'exécution : **non appliqué, à décider par le propriétaire du projet**.
- Le vrai correctif est la mise à jour de macOS (bug du runtime de la bêta).
