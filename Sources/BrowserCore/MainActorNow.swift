import Foundation

/// Exécute `body` tout de suite en le tenant pour isolé au thread principal, SANS demander au runtime Swift s'il est sur l'exécuteur principal.
///
/// Pourquoi pas `mainActorNow` : sur macOS 27 bêta, `swift_task_isCurrentExecutorWithFlags` → `isMainExecutor` plante de temps en temps
/// (objc_opt_class / swift_getObjectType sur une référence d'exécuteur invalide) dans les minuteurs et les rappels d'AppKit, et ce plantage ne dépend pas de notre code
/// (voir Docs/plantages-macos27.md). Le contrôle de fil est fait par Dispatch à la place, qui ne passe pas par ce chemin.
public func mainActorNow<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    dispatchPrecondition(condition: .onQueue(.main))
    typealias Plain = () throws -> T
    return try withoutActuallyEscaping(body) { try unsafeBitCast($0, to: Plain.self)() }
}
