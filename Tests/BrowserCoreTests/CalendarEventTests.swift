import Testing
import Foundation
@testable import BrowserCore

@Suite struct CalendarEventTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private func date(_ iso: String) -> Date { EventParser.parseDate(iso, timeZone: paris)!.date }

    @Test func datesAreReadWithOrWithoutTimeAndZone() {
        #expect(EventParser.parseDate("2026-10-12T20:30:00+02:00", timeZone: paris)?.date == EventParser.parseDate("2026-10-12T18:30:00Z", timeZone: paris)?.date)
        let local = EventParser.parseDate("2026-10-12T20:30:00", timeZone: paris)
        #expect(local?.date == EventParser.parseDate("2026-10-12T18:30:00Z")?.date && local?.allDay == false)    // Paris is UTC+2 in October
        #expect(EventParser.parseDate("2026-10-12", timeZone: paris)?.allDay == true)
        #expect(EventParser.parseDate("bientôt", timeZone: paris) == nil)
    }

    @Test func anEventIsReadFromStructuredData() throws {
        let ld = """
        {"@context":"https://schema.org","@graph":[{"@type":"WebSite"},{"@type":"MusicEvent","name":"Concert d'automne","startDate":"2026-11-05T20:00:00+01:00",
         "endDate":"2026-11-05T22:30:00+01:00","description":"Un <b>beau</b> concert.","url":"https://example.com/e",
         "location":{"@type":"Place","name":"Salle Pleyel","address":{"@type":"PostalAddress","streetAddress":"252 rue du Faubourg Saint-Honoré","postalCode":"75008","addressLocality":"Paris"}}}]}
        """
        let event = try #require(EventParser.fromStructuredData([ld], timeZone: paris))
        #expect(event.title == "Concert d'automne" && !event.allDay)
        #expect(event.end?.timeIntervalSince(event.start) == 9000)
        #expect(event.location == "Salle Pleyel, 252 rue du Faubourg Saint-Honoré, 75008 Paris")
        #expect(event.notes == "Un beau concert." && event.url == "https://example.com/e")
    }

    @Test func reservationsAreEventsToo() throws {
        let restaurant = #"{"@type":"FoodEstablishmentReservation","startTime":"2026-12-24T20:00:00+01:00","reservationFor":{"@type":"FoodEstablishment","name":"Chez Paul","address":"12 rue X, Paris"}}"#
        let event = try #require(EventParser.fromStructuredData([restaurant], timeZone: paris))
        #expect(event.title == "Chez Paul" && event.location == "12 rue X, Paris")
        let train = #"{"@type":"TrainReservation","reservationFor":{"@type":"TrainTrip","name":"TGV 6203","departureTime":"2026-12-20T08:15:00+01:00","arrivalTime":"2026-12-20T10:20:00+01:00"}}"#
        #expect(try #require(EventParser.fromStructuredData([train], timeZone: paris)).title == "TGV 6203")
        #expect(EventParser.fromStructuredData([#"{"@type":"Recipe","name":"x"}"#, "pas du json", #"{"@type":"Event","name":"Sans date"}"#]) == nil)
    }

    @Test func theModelsAnswerIsReadAndBadOnesRejected() throws {
        let answer = "Voici :\n```json\n{\"titre\": \"Rendez-vous chez le Dr Martin\", \"debut\": \"2026-10-14T09:15:00\", \"fin\": \"\", \"lieu\": \"12 rue Haute\"}\n```"
        let event = try #require(EventParser.fromModel(answer, timeZone: paris))
        #expect(event.title == "Rendez-vous chez le Dr Martin" && event.location == "12 rue Haute" && event.end == nil)
        #expect(EventParser.fromModel("{}") == nil)
        #expect(EventParser.fromModel(#"{"titre":"x","debut":"demain"}"#) == nil)
        #expect(EventParser.fromModel(#"{"titre":"Fête","debut":"2026-10-14","fin":"2026-10-13"}"#, timeZone: paris)?.end == nil)      // an end before the start is dropped
    }

    @Test func aDateTheModelInventedIsRejected() {
        let now = date("2026-10-10T12:00:00")
        let event = CalendarEvent(title: "RDV", start: date("2026-10-14T09:15:00"))
        #expect(EventValidator.isPlausible(event, pageText: "Votre rendez-vous est confirmé le mardi 14 octobre à 9h15.", now: now, timeZone: paris))
        #expect(EventValidator.isPlausible(event, pageText: "RDV le 14/10 à 9h15", now: now, timeZone: paris))
        #expect(EventValidator.isPlausible(event, pageText: "Appointment on October 14 at 9:15", now: now, timeZone: paris))
        #expect(!EventValidator.isPlausible(event, pageText: "Votre rendez-vous est confirmé le 15 novembre.", now: now, timeZone: paris))      // not on the page
        #expect(!EventValidator.isPlausible(event, pageText: "le 14 du mois, rien d'autre", now: now, timeZone: paris))                      // a day alone is not a date
        #expect(!EventValidator.isPlausible(CalendarEvent(title: "x", start: date("2020-01-05T10:00:00")), pageText: "le 5 janvier", now: now, timeZone: paris))   // long past
        #expect(!EventValidator.isPlausible(CalendarEvent(title: "x", start: date("2031-01-05T10:00:00")), pageText: "le 5 janvier", now: now, timeZone: paris))   // too far
    }

    @Test func theICSFileIsWellFormed() {
        let event = CalendarEvent(title: "Concert, avec; accents é", start: date("2026-11-05T20:00:00"), end: date("2026-11-05T22:00:00"),
                                  location: "Salle Pleyel\n75008 Paris", url: "https://example.com/e", notes: String(repeating: "é", count: 120))
        let ics = ICSBuilder.build(event, uid: "u1", now: date("2026-10-10T12:00:00"), timeZone: paris)
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n") && ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(ics.contains("DTSTART:20261105T190000Z\r\n") && ics.contains("DTEND:20261105T210000Z\r\n"))
        #expect(ics.contains("SUMMARY:Concert\\, avec\\; accents é\r\n") && ics.contains("LOCATION:Salle Pleyel\\n75008 Paris\r\n"))
        #expect(ics.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })                  // long lines are folded
        #expect(!ics.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("DESCRIPTION:" + String(repeating: "é", count: 120)))                 // folding never cuts a character
    }

    @Test func anAllDayEventEndsTheNextDayAndAMissingEndIsAnHour() {
        let allDay = ICSBuilder.build(CalendarEvent(title: "Fête", start: date("2026-12-24"), allDay: true), now: date("2026-10-10T12:00:00"), timeZone: paris)
        #expect(allDay.contains("DTSTART;VALUE=DATE:20261224") && allDay.contains("DTEND;VALUE=DATE:20261225"))
        let timed = ICSBuilder.build(CalendarEvent(title: "RDV", start: date("2026-10-14T09:00:00")), now: date("2026-10-10T12:00:00"), timeZone: paris)
        #expect(timed.contains("DTSTART:20261014T070000Z") && timed.contains("DTEND:20261014T080000Z"))
    }
}
