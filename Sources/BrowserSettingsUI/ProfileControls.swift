import Foundation

/// Ce que la fenêtre des réglages demande à l'app pour les profils (ouvrir un profil : c'est l'app qui lance l'autre Orée).
@MainActor
public enum ProfileControls {
    public static var open: (String?) -> Void = { _ in }
}
