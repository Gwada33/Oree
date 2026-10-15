import Testing
import Foundation
@testable import BrowserStorage

struct NoteRepositoryTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        return (try AppDatabase(path: url.path), { try? FileManager.default.removeItem(at: url) })
    }

    @Test func saveThenUpdateKeepsOneNote() throws {
        let (database, cleanup) = try makeTestDatabase(); defer { cleanup() }
        let repo = NoteRepository(database: database)
        var note = try repo.save(Note(body: "Courses\nlait"))
        #expect(note.id != nil)
        note.body = "Courses\nlait, pain"
        try repo.save(note)
        let all = try repo.all()
        #expect(all.count == 1)
        #expect(all[0].body == "Courses\nlait, pain")
    }

    @Test func titleIsFirstNonEmptyLineAndShortened() {
        #expect(Note(body: "\n  \nBonjour\nsuite").title == "Bonjour")
        #expect(Note(body: "  ").title == "Note vide")
        #expect(Note(body: String(repeating: "a", count: 100)).title.count == 61)
    }

    @Test func latestForPageAndNewestFirst() throws {
        let (database, cleanup) = try makeTestDatabase(); defer { cleanup() }
        let repo = NoteRepository(database: database)
        try repo.save(Note(body: "a", url: "https://a.example"))
        Thread.sleep(forTimeInterval: 0.01)
        try repo.save(Note(body: "b", url: "https://b.example"))
        Thread.sleep(forTimeInterval: 0.01)
        var a2 = try repo.save(Note(body: "a2", url: "https://a.example"))
        #expect(try repo.latest(forURL: "https://a.example")?.body == "a2")
        #expect(try repo.latest(forURL: "https://none.example") == nil)
        #expect(try repo.all().first?.body == "a2")
        a2.body = ""
        try repo.save(a2)
        try repo.deleteEmpty()
        #expect(try repo.all().count == 2)
    }

    @Test func deleteRemovesTheNote() throws {
        let (database, cleanup) = try makeTestDatabase(); defer { cleanup() }
        let repo = NoteRepository(database: database)
        let note = try repo.save(Note(body: "x"))
        try repo.delete(id: note.id!)
        #expect(try repo.all().isEmpty)
    }
}
