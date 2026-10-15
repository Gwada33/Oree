import Foundation
import Testing
@testable import BrowserCore

@Suite("Archivage des onglets")
struct TabArchiveTests {
    @Test("jamais par défaut, puis après N jours pleins")
    func stale() {
        #expect(!TabArchivePolicy.isStale(idle: 10_000_000, days: 0))
        #expect(!TabArchivePolicy.isStale(idle: 86_399, days: 1))
        #expect(TabArchivePolicy.isStale(idle: 86_400, days: 1))
        #expect(!TabArchivePolicy.isStale(idle: 6 * 86_400, days: 7))
        #expect(TabArchivePolicy.isStale(idle: 30 * 86_400, days: 30))
    }

    @Test("ni l'onglet affiché, ni le son, ni le privé, ni une page sans adresse web")
    func canArchive() {
        let web = URL(string: "https://example.com/a")
        #expect(TabArchivePolicy.canArchive(url: web, isPrivate: false, isActive: false, playsAudio: false))
        #expect(!TabArchivePolicy.canArchive(url: web, isPrivate: true, isActive: false, playsAudio: false))
        #expect(!TabArchivePolicy.canArchive(url: web, isPrivate: false, isActive: true, playsAudio: false))
        #expect(!TabArchivePolicy.canArchive(url: web, isPrivate: false, isActive: false, playsAudio: true))
        #expect(!TabArchivePolicy.canArchive(url: URL(string: "oree://home/"), isPrivate: false, isActive: false, playsAudio: false))
        #expect(!TabArchivePolicy.canArchive(url: nil, isPrivate: false, isActive: false, playsAudio: false))
    }

    @Test("une seule entrée par adresse, la plus récente en tête, plafonnée")
    func adding() {
        let now = Date()
        var list: [ArchivedTab] = []
        list = TabArchivePolicy.adding(ArchivedTab(url: "https://a", title: "A", space: 0, archivedAt: now), to: list)
        list = TabArchivePolicy.adding(ArchivedTab(url: "https://b", title: "B", space: 0, archivedAt: now), to: list)
        list = TabArchivePolicy.adding(ArchivedTab(url: "https://a", title: "A2", space: 1, archivedAt: now), to: list)
        #expect(list.map(\.url) == ["https://a", "https://b"])
        #expect(list.first?.title == "A2")
        for i in 0..<300 { list = TabArchivePolicy.adding(ArchivedTab(url: "https://x/\(i)", title: "", space: 0, archivedAt: now), to: list) }
        #expect(list.count == TabArchivePolicy.limit)
        #expect(list.first?.url == "https://x/299")
    }

    @Test("l'archive survit à un aller-retour sur disque")
    func store() {
        let suite = UserDefaults(suiteName: "oree.test.archive.\(UUID().uuidString)")!
        let store = TabArchiveStore(key: "k")
        #expect(store.load(suite).isEmpty)
        let item = ArchivedTab(url: "https://a", title: "A", space: 2, archivedAt: Date(timeIntervalSince1970: 1000))
        store.save([item], suite)
        #expect(store.load(suite) == [item])
    }
}
