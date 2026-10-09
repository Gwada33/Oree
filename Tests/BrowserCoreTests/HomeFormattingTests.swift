import Testing
import Foundation
@testable import BrowserCore

@Suite struct HomeFormattingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func relativeTimes() {
        #expect(HomeFormatting.relative(now.addingTimeInterval(-20), now: now) == "à l'instant")
        #expect(HomeFormatting.relative(now.addingTimeInterval(-300), now: now) == "il y a 5 min")
        #expect(HomeFormatting.relative(now.addingTimeInterval(-3 * 3600), now: now) == "il y a 3 h")
        #expect(HomeFormatting.relative(now.addingTimeInterval(-30 * 3600), now: now) == "hier")
        #expect(HomeFormatting.relative(now.addingTimeInterval(-4 * 86_400), now: now) == "il y a 4 j")
        #expect(HomeFormatting.relative(now.addingTimeInterval(500), now: now) == "à l'instant")
    }

    @Test func frenchDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 8))!   // a Thursday
        let d = HomeFormatting.frenchDate(date, calendar: cal)
        #expect(d.weekday == "jeudi")
        #expect(d.dayMonth == "8 octobre")
    }

    @Test func hostHelpers() {
        #expect(HomeFormatting.displayHost("https://www.example.com/a") == "example.com")
        #expect(HomeFormatting.hue(forHost: "a.com") == HomeFormatting.hue(forHost: "a.com"))
    }
}
