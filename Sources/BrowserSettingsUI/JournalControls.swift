import Foundation

/// Ce que la fenêtre des réglages peut demander au journal d'événements (c'est l'app qui branche les fonctions : les réglages ne connaissent pas le journal en cours).
@MainActor
public enum JournalControls {
    public struct Stats: Equatable, Sendable {
        public var events = 0, files = 0
        public var bytes: Int64 = 0
        public var first: Date?
        public init(events: Int = 0, files: Int = 0, bytes: Int64 = 0, first: Date? = nil) { self.events = events; self.files = files; self.bytes = bytes; self.first = first }
    }
    public static var stats: () -> Stats = { Stats() }
    /// Écrit le journal déchiffré dans le fichier donné ; renvoie le nombre d'événements.
    public static var export: (URL) throws -> Int = { _ in 0 }
    public static var clear: () -> Void = {}
}
