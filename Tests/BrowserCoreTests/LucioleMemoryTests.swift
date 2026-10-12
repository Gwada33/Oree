import Testing
import Foundation
@testable import BrowserCore

@Suite struct LucioleMemoryTests {
    let now = Date()

    private func entry(_ task: String, host: String?, daysAgo: Int = 0, actions: [String] = [], answer: String = "", facts: [String] = []) -> LucioleMemory.Entry {
        .init(date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!, host: host, task: task, actions: actions, answer: answer, facts: facts)
    }

    @Test func recallPutsTheOpenSiteFirstThenTheMostRecent() {
        var memory = LucioleMemory()
        memory.record(entry("Réserver la visite", host: "alfama.pt", daysAgo: 3, actions: ["Saisie dans « Nom »."], answer: "Réservation annulée par vous."))
        memory.record(entry("Chercher le tram 28", host: nil, daysAgo: 1, answer: "40 minutes."))
        memory.record(entry("Résumer Lisbonne", host: "fr.wikipedia.org", daysAgo: 0))
        let lines = memory.recall(host: "alfama.pt", limit: 3, now: now)
        #expect(lines.count == 3)
        #expect(lines[0].contains("alfama.pt") && lines[0].contains("il y a 3 j") && lines[0].contains("Saisie dans « Nom »."))
        #expect(lines[1].contains("Résumer Lisbonne") && lines[2].contains("hier"))
        #expect(memory.recall(host: nil, limit: 0, now: now).isEmpty)
    }

    @Test func factsLearnedFromTheUserAreRecalled() {
        var memory = LucioleMemory()
        memory.record(entry("Salue-moi", host: nil, facts: ["Quel est votre prénom ? → Nolhan"]))
        #expect(memory.recall(host: nil, limit: 1, now: now)[0].contains("Appris : Quel est votre prénom ? → Nolhan"))
    }

    @Test func discussionsAreCappedAndMostRecentFirst() {
        var memory = LucioleMemory()
        for i in 0..<(LucioleMemory.maxDiscussions + 5) {
            memory.upsert(.init(title: "d\(i)", host: nil, updatedAt: Date(timeIntervalSince1970: Double(i)), messages: []))
        }
        #expect(memory.discussions.count == LucioleMemory.maxDiscussions)
        #expect(memory.discussions.first?.title == "d\(LucioleMemory.maxDiscussions + 4)")
        let id = memory.discussions[3].id
        memory.upsert(.init(id: id, title: "renommée", host: nil, updatedAt: Date(timeIntervalSince1970: 1_000), messages: []))
        #expect(memory.discussions.first?.title == "renommée" && memory.discussions.filter { $0.id == id }.count == 1)
    }

    @Test func journalIsCappedAndClearable() {
        var memory = LucioleMemory()
        for i in 0..<(LucioleMemory.maxJournal + 10) { memory.record(entry("t\(i)", host: nil)) }
        #expect(memory.journal.count == LucioleMemory.maxJournal && memory.journal.first?.task == "t10")
        memory.clear()
        #expect(memory.journal.isEmpty && memory.discussions.isEmpty)
    }

    @Test func fileRoundTripAndErase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luciole-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var memory = LucioleMemory()
        memory.upsert(.init(title: "Une discussion", host: "a.fr", updatedAt: now, messages: [.init(isUser: true, text: "Bonjour"), .init(isUser: false, text: "Salut", trace: [.init(text: "Clic", detail: "ok")])]))
        memory.record(entry("Tâche", host: "a.fr", actions: ["Clic"], answer: "Fait"))
        #expect(memory.save(to: dir))
        let loaded = LucioleMemory.load(from: dir)
        #expect(loaded.discussions.first?.messages.count == 2 && loaded.journal.first?.task == "Tâche")
        LucioleMemory.erase(in: dir)
        #expect(LucioleMemory.load(from: dir) == LucioleMemory())
    }

    @Test func secretsAreNeverKeptAsFacts() {
        #expect(LucioleMemory.isSafeFact(question: "Quel est votre prénom ?", answer: "Nolhan"))
        #expect(!LucioleMemory.isSafeFact(question: "Le site demande un mot de passe", answer: "x"))
        #expect(!LucioleMemory.isSafeFact(question: "Numéro de carte ?", answer: "4111 1111 1111 1111"))
        #expect(!LucioleMemory.isSafeFact(question: "Votre code ?", answer: "4111111111111111"))
    }

    @Test func titleIsShortenedOnOneLine() {
        #expect(LucioleMemory.title(for: "Réserve\nla visite  guidée") == "Réserve la visite guidée")
        #expect(LucioleMemory.title(for: String(repeating: "a", count: 80)).count == 44)
    }
}
