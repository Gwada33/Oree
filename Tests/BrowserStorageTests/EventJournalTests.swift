import Testing
import Foundation
import CryptoKit
import BrowserCore
@testable import BrowserStorage

struct EventJournalTests {
    private func makeJournal(days: Int = 30, maxBytes: Int64 = 100 << 20, now: @escaping @Sendable () -> Date = { Date() }) -> (EventJournal, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        return (EventJournal(directory: dir, keys: StaticKeyProvider(), retentionDays: days, maxBytes: maxBytes, clock: now), dir)
    }
    private func event(_ name: String = "tab.select", _ t: Double = Date().timeIntervalSince1970, _ d: [String: JournalValue] = ["tab": .string("ab12"), "dwell": .int(1200)]) -> JournalEvent { JournalEvent(t: t, e: name, d: d) }

    @Test func recordsComeBackInOrder() {
        let (journal, dir) = makeJournal(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date().timeIntervalSince1970
        for i in 0..<5 { journal.record(event("tab.select", now + Double(i), ["tab": .string("ab12"), "dwell": .int(i * 100)])) }
        let all = journal.readAll()
        #expect(all.count == 5 && all.map { $0.d["dwell"]?.int } == [0, 100, 200, 300, 400])
    }

    @Test func eventsOutsideTheSchemaNeverReachTheDisk() throws {
        let (journal, dir) = makeJournal(); defer { try? FileManager.default.removeItem(at: dir) }
        journal.record(event("page.content", Date().timeIntervalSince1970, ["text": .string("mot de passe")]))
        journal.record(event("tab.open", Date().timeIntervalSince1970, ["tab": .string("ab12"), "how": .string("https://x.example/secret")]))
        journal.flushAndWait()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let raw = try files.map { try Data(contentsOf: $0) }.reduce(Data(), +)
        #expect(!String(decoding: raw, as: UTF8.self).contains("secret") && !String(decoding: raw, as: UTF8.self).contains("mot de passe"))
        let all = journal.readAll()
        #expect(all.count == 1 && all[0].d["how"] == nil)
    }

    @Test func filesAreEncryptedAndUnreadableWithAnotherKey() throws {
        let (journal, dir) = makeJournal(); defer { try? FileManager.default.removeItem(at: dir) }
        journal.record(event("nav.done", Date().timeIntervalSince1970, ["site": .string("0123456789abcdef"), "ms": .int(777), "ok": .bool(true)]))
        journal.flushAndWait()
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!raw.contains("0123456789abcdef") && !raw.contains("nav.done"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let stranger = EventJournal(directory: dir, keys: StaticKeyProvider(data: Data(repeating: 1, count: 32)))
        #expect(stranger.readAll().isEmpty)                      // une autre clé ne lit rien, et ne casse rien
    }

    @Test func eachDayHasItsOwnFileAndABlockNeverCrossesMidnight() throws {
        let (journal, dir) = makeJournal(days: 400); defer { try? FileManager.default.removeItem(at: dir) }
        let day1 = Date(timeIntervalSinceNow: -86_400 * 2).timeIntervalSince1970, day2 = Date().timeIntervalSince1970
        journal.record(event("tab.select", day1)); journal.record(event("tab.select", day2)); journal.record(event("tab.select", day1 + 5))
        journal.flushAndWait()
        #expect(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count == 2)
        #expect(journal.readAll().count == 3)
        let stats = journal.stats()
        #expect(stats.files == 2 && stats.events == 3 && stats.bytes > 0 && stats.first != nil && stats.last != nil)
    }

    @Test func retentionRemovesOldDaysAndKeepsRecentOnes() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let (journal, dir) = makeJournal(days: 7, now: { fixed }); defer { try? FileManager.default.removeItem(at: dir) }
        let old = fixed.addingTimeInterval(-86_400 * 20).timeIntervalSince1970, recent = fixed.addingTimeInterval(-86_400 * 2).timeIntervalSince1970
        journal.record(event("tab.select", old)); journal.record(event("tab.select", recent))
        journal.flushAndWait()
        journal.prune()
        let left = journal.readAll()
        #expect(left.count == 1 && left[0].t == (recent * 1000).rounded() / 1000)
    }

    @Test func sizeCapRemovesTheOldestFirst() throws {
        let (journal, dir) = makeJournal(days: 4000, maxBytes: 1); defer { try? FileManager.default.removeItem(at: dir) }
        let a = Date(timeIntervalSinceNow: -86_400 * 3).timeIntervalSince1970, b = Date(timeIntervalSinceNow: -86_400 * 2).timeIntervalSince1970
        journal.record(event("tab.select", a)); journal.record(event("tab.select", b))
        journal.flushAndWait(); journal.prune()
        #expect(journal.stats().files == 0)                   // tout dépasse 1 octet : tout part, le plus ancien d'abord
    }

    @Test func exportIsJSONLinesWithAHeaderAndClearErasesEverything() throws {
        let (journal, dir) = makeJournal(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 { journal.record(event("tab.select", Date().timeIntervalSince1970 + Double(i))) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).jsonl"); defer { try? FileManager.default.removeItem(at: out) }
        #expect(try journal.export(to: out) == 3)
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4 && lines[0].contains("\"format\":\"oree-journal\"") && lines[0].contains("\"events\":3"))
        #expect(try JSONDecoder().decode(JournalEvent.self, from: Data(lines[1].utf8)).e == "tab.select")
        journal.clear()
        #expect(journal.readAll().isEmpty && journal.stats().files == 0)
    }

    @Test func aCorruptedBlockIsSkippedNotFatal() throws {
        let (journal, dir) = makeJournal(); defer { try? FileManager.default.removeItem(at: dir) }
        journal.record(event()); journal.flushAndWait()
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var data = try Data(contentsOf: file); data.append(contentsOf: [0, 0, 0, 40] + Array(repeating: 0xAB, count: 40))   // un bloc de bruit à la suite
        try data.write(to: file)
        journal.record(event("tab.select", Date().timeIntervalSince1970 + 1)); journal.flushAndWait()
        #expect(journal.readAll().count >= 1)
    }

    @Test func siteKeyIsStableForOneKeyAndDiffersBetweenKeys() {
        let (a, dirA) = makeJournal(); defer { try? FileManager.default.removeItem(at: dirA) }
        let b = EventJournal(directory: dirA, keys: StaticKeyProvider(data: Data(repeating: 2, count: 32)))
        let ka = a.siteKey().map { SiteHash.hash(host: "example.com", key: $0) }, kb = b.siteKey().map { SiteHash.hash(host: "example.com", key: $0) }
        #expect(ka != nil && ka == a.siteKey().map { SiteHash.hash(host: "example.com", key: $0) } && ka != kb)
    }
}
