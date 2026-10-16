import Testing
import Foundation
import BrowserCore
import GRDB
@testable import BrowserStorage

struct AutofillStoreTests {
    private func makeStore() throws -> (AutofillStore, AppDatabase, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let db = try AppDatabase(path: url.path)
        return (AutofillStore(database: db, keys: StaticKeyProvider()), db, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func addressAndCardRoundTrip() throws {
        let (store, _, cleanup) = try makeStore(); defer { cleanup() }
        var a = AddressProfile(label: "Maison"); a.firstName = "Ana"; a.street = "12 rue des Lilas"
        var c = CardProfile(label: "Perso"); c.number = "4242424242424242"; c.holder = "ANA"; c.expMonth = 8; c.expYear = 2027
        try store.save(a); try store.save(c)
        let addresses = try store.addresses(), cards = try store.cards()
        #expect(addresses == [a] && cards == [c])
        #expect(store.count(kind: "address") == 1 && store.count(kind: "card") == 1 && store.count(kind: "nothing") == 0)
    }

    @Test func secretsAreNeverOnDiskInTheClear() throws {
        let (store, db, cleanup) = try makeStore(); defer { cleanup() }
        var c = CardProfile(label: "Perso"); c.number = "4242424242424242"; c.holder = "ANA DUPONT"
        var a = AddressProfile(label: "Maison"); a.street = "12 rue des Lilas"
        try store.save(c); try store.save(a)
        let raw: String = try db.dbPool.read { d in try Row.fetchAll(d, sql: "SELECT label, kind, hex(sealed) AS s FROM autofill").map { "\($0["label"] ?? "") \($0["s"] ?? "")" }.joined() }
        let plain = ["4242", "DUPONT", "Lilas"].map { Data($0.utf8).map { String(format: "%02X", $0) }.joined() }
        #expect(!plain.contains { raw.contains($0) })
    }

    @Test func aBoxMovedOntoAnotherRowDoesNotOpen() throws {
        let (store, db, cleanup) = try makeStore(); defer { cleanup() }
        var a = AddressProfile(label: "A"); a.city = "Paris"
        try store.save(a)
        try db.dbPool.write { d in try d.execute(sql: "UPDATE autofill SET kind = 'card'") }          // une adresse déguisée en carte
        #expect(try store.cards().isEmpty)
    }

    @Test func updatingKeepsOneRowAndDeletingRemovesIt() throws {
        let (store, _, cleanup) = try makeStore(); defer { cleanup() }
        var a = AddressProfile(label: "Maison"); a.city = "Paris"
        try store.save(a); a.city = "Lyon"; try store.save(a)
        #expect(try store.addresses().map(\.city) == ["Lyon"])
        try store.delete(id: a.id)
        #expect(try store.addresses().isEmpty)
        try store.save(a); try store.deleteAll()
        #expect(store.count(kind: "address") == 0)
    }
}
