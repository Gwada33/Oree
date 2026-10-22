import AppKit
import CoreSpotlight
import UniformTypeIdentifiers
import BrowserCore
import BrowserStorage

/// Spotlight : les favoris et l'historique récent d'Orée se retrouvent depuis la recherche du système, et un clic ouvre la page dans Orée. Désactivé par défaut (un historique est sensible) ;
/// jamais un onglet privé, jamais rien sans le réglage ; tout s'efface avec l'historique et quand on coupe le réglage. Seuls le titre et l'adresse sont donnés à Spotlight.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    static let bookmarkDomain = "oree.bookmarks", historyDomain = "oree.history"
    static let historyLimit = 300
    private let index = CSSearchableIndex.default()
    private var observer: NSObjectProtocol?

    private init() {
        // Effacer l'historique (Réglages, ou à la fermeture) l'efface aussi de Spotlight.
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("Oree.historyCleared"), object: nil, queue: .main) { [weak self] _ in
            mainActorNow { self?.removeHistory() }
        }
    }

    static func identifier(for url: String) -> String { "oree:" + url }
    static func url(fromIdentifier id: String) -> URL? { id.hasPrefix("oree:") ? URL(string: String(id.dropFirst(5))) : nil }

    private func item(url: String, title: String, domain: String) -> CSSearchableItem? {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, scheme == "http" || scheme == "https", let host = parsed.host else { return nil }
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = title.isEmpty ? host : title
        attributes.contentDescription = host
        attributes.contentURL = parsed
        attributes.keywords = [host]
        let item = CSSearchableItem(uniqueIdentifier: Self.identifier(for: url), domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(domain == Self.historyDomain ? 30 * 86_400 : 365 * 86_400)
        return item
    }

    /// Reconstruit l'index : tous les favoris et les derniers sites visités. Appelé au lancement et quand le réglage s'allume.
    func reindex(bookmarks: [Bookmark], history: [HistoryEntry], completion: (@Sendable (Error?) -> Void)? = nil) {
        guard ProfileContext.id == nil else { completion?(nil); return }       // un seul index pour toute l'app : celui du profil principal
        let items = bookmarks.compactMap { item(url: $0.url, title: $0.title, domain: Self.bookmarkDomain) }
            + history.prefix(Self.historyLimit).filter { URL(string: $0.url)?.scheme != "oree" }.compactMap { item(url: $0.url, title: $0.title, domain: Self.historyDomain) }
        // Les rappels de CoreSpotlight arrivent sur une file à eux : `@Sendable`, jamais isolés à l'interface.
        index.deleteSearchableItems(withDomainIdentifiers: [Self.bookmarkDomain, Self.historyDomain]) { @Sendable [index] _ in
            index.indexSearchableItems(items) { @Sendable error in completion?(error) }
        }
    }

    /// Une page vient d'être visitée.
    func add(url: String, title: String) {
        guard ProfileContext.id == nil, SettingsStore.shared.spotlightIndexing, let item = item(url: url, title: title, domain: Self.historyDomain) else { return }
        index.indexSearchableItems([item]) { @Sendable _ in }
    }

    func addBookmark(url: String, title: String) {
        guard ProfileContext.id == nil, SettingsStore.shared.spotlightIndexing, let item = item(url: url, title: title, domain: Self.bookmarkDomain) else { return }
        index.indexSearchableItems([item]) { @Sendable _ in }
    }

    func remove(url: String) { guard ProfileContext.id == nil else { return }; index.deleteSearchableItems(withIdentifiers: [Self.identifier(for: url)]) { @Sendable _ in } }
    func removeHistory() { guard ProfileContext.id == nil else { return }; index.deleteSearchableItems(withDomainIdentifiers: [Self.historyDomain]) { @Sendable _ in } }
    func removeAll(completion: (@Sendable (Error?) -> Void)? = nil) { guard ProfileContext.id == nil else { completion?(nil); return }; index.deleteAllSearchableItems { @Sendable error in completion?(error) } }

    /// Essais : les identifiants des résultats Spotlight dont le titre contient `text`.
    nonisolated static func find(titleContaining text: String, completion: @escaping @Sendable ([String]) -> Void) {
        let query = CSSearchQuery(queryString: "title == \"*\(text)*\"cd", queryContext: nil)
        let box = FoundBox()
        query.foundItemsHandler = { @Sendable items in box.append(items.map(\.uniqueIdentifier)) }
        query.completionHandler = { @Sendable _ in completion(box.values.sorted()) }
        query.start()
    }

    private final class FoundBox: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func append(_ more: [String]) { lock.lock(); items += more; lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
