import Foundation

/// An event found on a page: a concert, a webinar, a booking, an appointment.
public struct CalendarEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date?
    /// A date with no time ("2026-10-12"): an all-day event.
    public var allDay: Bool
    public var location: String?
    public var url: String?
    public var notes: String?

    public init(title: String, start: Date, end: Date? = nil, allDay: Bool = false, location: String? = nil, url: String? = nil, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.url = url; self.notes = notes
    }
}

public enum EventParser {
    // MARK: Dates

    /// "2026-10-12T20:30:00+02:00", "…Z", "2026-10-12T20:30:00" (local time) or "2026-10-12" (all day).
    public static func parseDate(_ text: String, timeZone: TimeZone = .current) -> (date: Date, allDay: Bool)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: value) { return (date, false) }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: value) { return (date, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for (format, allDay) in [("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return (date, allDay) }
        }
        return nil
    }

    // MARK: schema.org Event / reservations

    /// Reads the first event in a page's JSON-LD: an `Event` of any kind (concert, festival, webinar…), or a reservation (restaurant, event,
    /// train) that says when it takes place.
    public static func fromStructuredData(_ blocks: [String], timeZone: TimeZone = .current) -> CalendarEvent? {
        for block in blocks {
            guard let data = block.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for node in nodes(in: json) {
                if let event = event(from: node, timeZone: timeZone) { return event }
            }
        }
        return nil
    }

    private static func nodes(in json: Any) -> [[String: Any]] {
        if let array = json as? [Any] { return array.flatMap(nodes(in:)) }
        guard let object = json as? [String: Any] else { return [] }
        return [object] + (object["@graph"].map(nodes(in:)) ?? [])
    }

    private static func types(_ node: [String: Any]) -> [String] {
        if let one = node["@type"] as? String { return [one] }
        return (node["@type"] as? [String]) ?? []
    }

    private static func event(from node: [String: Any], timeZone: TimeZone) -> CalendarEvent? {
        let kinds = types(node)
        if kinds.contains(where: { $0.hasSuffix("Event") || $0 == "Festival" }) { return eventNode(node, timeZone: timeZone) }
        if kinds.contains(where: { $0.hasSuffix("Reservation") }) {
            // A reservation points at what is booked (an event, a restaurant, a trip) and carries its own start time.
            let target = node["reservationFor"] as? [String: Any] ?? [:]
            if let start = (node["startTime"] as? String) ?? (target["startDate"] as? String) ?? (target["departureTime"] as? String),
               let parsed = parseDate(start, timeZone: timeZone) {
                let name = text(target["name"]) ?? text(node["name"]) ?? "Réservation"
                let end = ((node["endTime"] as? String) ?? (target["endDate"] as? String) ?? (target["arrivalTime"] as? String)).flatMap { parseDate($0, timeZone: timeZone)?.date }
                return CalendarEvent(title: name, start: parsed.date, end: end, allDay: parsed.allDay, location: place(target["location"] ?? target["address"] ?? target["departureStation"]),
                                     url: node["url"] as? String)
            }
        }
        return nil
    }

    private static func eventNode(_ node: [String: Any], timeZone: TimeZone) -> CalendarEvent? {
        guard let startText = node["startDate"] as? String, let start = parseDate(startText, timeZone: timeZone),
              let name = text(node["name"]) else { return nil }
        let end = (node["endDate"] as? String).flatMap { parseDate($0, timeZone: timeZone)?.date }
        return CalendarEvent(title: name, start: start.date, end: end, allDay: start.allDay, location: place(node["location"]),
                             url: node["url"] as? String, notes: text(node["description"]).map { String($0.prefix(500)) })
    }

    private static func text(_ value: Any?) -> String? { DigestParser.clean(value as? String) }

    /// "Salle Pleyel, 252 rue du Faubourg Saint-Honoré, 75008 Paris" from a Place, a PostalAddress, a list, or a plain string.
    private static func place(_ value: Any?) -> String? {
        switch value {
        case let text as String: return DigestParser.clean(text)
        case let array as [Any]: return array.compactMap(place).first
        case let object as [String: Any]:
            var parts: [String] = []
            if let name = text(object["name"]) { parts.append(name) }
            if let address = object["address"] { if let found = place(address) { parts.append(found) } }
            else {
                let street = text(object["streetAddress"]), city = [text(object["postalCode"]), text(object["addressLocality"])].compactMap { $0 }.joined(separator: " ")
                parts += [street, city.isEmpty ? nil : city].compactMap { $0 }
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default: return nil
        }
    }

    // MARK: What the local model wrote

    /// Reads the model's JSON ("titre", "debut", "fin", "lieu"): dates in ISO 8601. nil when there is no usable title and start.
    public static func fromModel(_ answer: String, timeZone: TimeZone = .current) -> CalendarEvent? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields: [String: Any] = [:]
        for (key, value) in object { fields[DigestParser.fold(key)] = value }
        guard let title = text(fields["titre"] ?? fields["title"] ?? fields["nom"]), title.count >= 2,
              let startText = (fields["debut"] ?? fields["start"] ?? fields["date"]) as? String, let parsedStart = parseDate(startText, timeZone: timeZone) else { return nil }
        let endDate = ((fields["fin"] ?? fields["end"]) as? String).flatMap { parseDate($0, timeZone: timeZone)?.date }
        return CalendarEvent(title: title, start: parsedStart.date, end: endDate.flatMap { $0 > parsedStart.date ? $0 : nil }, allDay: parsedStart.allDay,
                             location: text(fields["lieu"] ?? fields["location"]))
    }
}

/// The model may invent a date. One is kept only when it is plausible and the page really mentions that day and month.
public enum EventValidator {
    private static let months: [[String]] = [
        ["janvier", "january", "jan"], ["février", "fevrier", "february", "feb", "fév"], ["mars", "march", "mar"], ["avril", "april", "apr", "avr"],
        ["mai", "may"], ["juin", "june", "jun"], ["juillet", "july", "jul", "juil"], ["août", "aout", "august", "aug"], ["septembre", "september", "sep", "sept"],
        ["octobre", "october", "oct"], ["novembre", "november", "nov"], ["décembre", "decembre", "december", "dec", "déc"],
    ]

    public static func isPlausible(_ event: CalendarEvent, pageText: String, now: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        guard event.start > now.addingTimeInterval(-86_400), event.start < now.addingTimeInterval(3 * 365 * 86_400) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month], from: event.start)
        guard let day = parts.day, let month = parts.month else { return false }
        let text = pageText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let hasDay = text.range(of: "(?<![0-9])0?\(day)(?![0-9])", options: .regularExpression) != nil
        let names = months[month - 1].map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() }
        let hasMonthName = names.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        let hasNumeric = text.range(of: "(?<![0-9])0?\(day)[/.\\-]0?\(month)(?![0-9])", options: .regularExpression) != nil
            || text.range(of: "(?<![0-9])0?\(month)[/.\\-]0?\(day)(?![0-9])", options: .regularExpression) != nil
        return hasNumeric || (hasDay && hasMonthName)
    }
}

/// An iCalendar (.ics) file for an event: opened with Calendar, it shows its own "add this event" window, so the app needs no access to
/// the user's calendars.
public enum ICSBuilder {
    public static func build(_ event: CalendarEvent, uid: String = UUID().uuidString, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        func utc(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        func day(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: date)
        }
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Orée//Événement//FR", "CALSCALE:GREGORIAN", "BEGIN:VEVENT", "UID:\(uid)@oree", "DTSTAMP:\(utc(now))"]
        if event.allDay {
            let last = event.end ?? event.start
            lines.append("DTSTART;VALUE=DATE:\(day(event.start))")
            lines.append("DTEND;VALUE=DATE:\(day(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: max(last, event.start)) ?? last))")
        } else {
            lines.append("DTSTART:\(utc(event.start))")
            lines.append("DTEND:\(utc(event.end ?? event.start.addingTimeInterval(3600)))")      // no end given: an hour
        }
        lines.append("SUMMARY:\(escape(event.title))")
        if let location = event.location { lines.append("LOCATION:\(escape(location))") }
        if let url = event.url, URL(string: url) != nil { lines.append("URL:\(url)") }
        if let notes = event.notes { lines.append("DESCRIPTION:\(escape(notes))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.flatMap(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Commas, semicolons, backslashes and line breaks have a meaning in iCalendar text.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Lines are cut at 75 bytes, each continuation starting with a space (never in the middle of a character).
    static func fold(_ line: String) -> [String] {
        var result: [String] = [], current = "", bytes = 0
        for character in line {
            let size = String(character).utf8.count
            if bytes + size > 75 { result.append(current); current = " "; bytes = 1 }
            current.append(character); bytes += size
        }
        result.append(current)
        return result
    }
}

/// What the local model is asked to find a date.
public enum EventPrompt {
    public static func instructions(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return """
        Tu cherches dans le texte d'une page web l'événement principal (rendez-vous, billet, réservation, concert, webinaire) et tu donnes sa date. \
        Réponds uniquement avec un objet JSON, sans texte autour : {"titre": "...", "debut": "2026-10-12T20:30:00", "fin": "2026-10-12T22:00:00", "lieu": "..."}. \
        Les dates sont au format ISO 8601, en heure locale ; "fin" et "lieu" sont vides si le texte ne les donne pas ; si seul le jour est connu, mets "debut": "2026-10-12". \
        Nous sommes le \(formatter.string(from: now)) : utilise-le pour comprendre "demain" ou "vendredi", et pour l'année si elle manque. \
        N'invente rien : si le texte ne contient pas d'événement avec une date, réponds {}.
        """
    }
}
