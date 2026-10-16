import Foundation
import Testing
@testable import BrowserCore

@Suite("Relances et limites de débit")
struct RetryPolicyTests {
    @Test("durées des en-têtes de limite : secondes, minutes, millisecondes")
    func durations() {
        #expect(RetryAfter.duration("2.5s") == 2.5)
        #expect(RetryAfter.duration("1m30s") == 90)
        #expect(RetryAfter.duration("1m30.5s") == 90.5)
        #expect(RetryAfter.duration("250ms") == 0.25)
        #expect(RetryAfter.duration("2h") == 7200)
        #expect(RetryAfter.duration("abc") == nil)
        #expect(RetryAfter.duration("12") == nil)
    }

    @Test("Retry-After : nombre, date HTTP, absent, illisible")
    func header() {
        #expect(RetryAfter.seconds(from: "6") == 6)
        #expect(RetryAfter.seconds(from: " 0.5 ") == 0.5)
        #expect(RetryAfter.seconds(from: nil) == nil)
        #expect(RetryAfter.seconds(from: "bientôt") == nil)
        #expect(RetryAfter.seconds(from: "-3") == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = Date(timeIntervalSince1970: 1_800_000_000 + 12)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(RetryAfter.seconds(from: formatter.string(from: date), now: now) == 12)
    }

    @Test("le délai double à chaque échec, plafonné, avec un peu d'aléa")
    func backoff() {
        let policy = RetryPolicy()
        func delay(_ attempt: Int, random: Double = 0.5) -> Double {
            if case .retry(let d) = policy.decide(status: 503, attempt: attempt, retryAfter: nil, random: random) { return d }
            return -1
        }
        #expect(delay(1) == 1.5)        // 1,5 × 1 × (0,8 + 0,4 × 0,5)
        #expect(delay(2) == 3)
        #expect(delay(3) == 6)
        #expect(delay(1, random: 0) == 1.2 && delay(1, random: 1) == 1.8)
    }

    @Test("Retry-After fait foi ; trop long : on rend la main")
    func retryAfter() {
        let policy = RetryPolicy()
        #expect(policy.decide(status: 429, attempt: 1, retryAfter: 6, random: 0) == .retry(after: 6.25))
        if case .giveUp(let reason) = policy.decide(status: 429, attempt: 1, retryAfter: 3600) { #expect(reason.contains("3600")) } else { Issue.record("une attente d'une heure ne doit pas être attendue") }
    }

    @Test("jamais de boucle infinie : nombre d'essais et attente totale bornés")
    func bounded() {
        let policy = RetryPolicy()
        #expect(policy.decide(status: 429, attempt: 4, retryAfter: 1) == .giveUp(reason: "nombre d'essais atteint"))
        #expect(policy.decide(status: 429, attempt: 1, retryAfter: 20, waited: 70) == .giveUp(reason: "attente totale dépassée"))
        // Même avec des 429 à répétition, la somme des attentes reste sous le plafond.
        var waited = 0.0, attempt = 1
        while case .retry(let d) = policy.decide(status: 429, attempt: attempt, retryAfter: nil, waited: waited, random: 1) { waited += d; attempt += 1 }
        #expect(waited <= policy.maxTotalWait && attempt <= policy.maxAttempts)
    }

    @Test("seules les erreurs passagères sont relancées")
    func transient() {
        let policy = RetryPolicy()
        for status in [400, 401, 403, 404, 422] { #expect(policy.decide(status: status, attempt: 1, retryAfter: nil) == .giveUp(reason: "erreur définitive")) }
        for status in [408, 429, 500, 502, 503, 504] { if case .giveUp = policy.decide(status: status, attempt: 1, retryAfter: nil) { Issue.record("\(status) mérite un nouvel essai") } }
        if case .giveUp = policy.decide(status: nil, attempt: 1, retryAfter: nil) { Issue.record("une erreur réseau mérite un nouvel essai") }
        // Un appel d'outil mal écrit (400 + indice du fournisseur) est un accident de génération : relancé tout de suite.
        if case .retry = policy.decide(status: 400, attempt: 1, retryAfter: nil, hint: 0.5) {} else { Issue.record("l'accident de génération doit être relancé") }
    }

    @Test("la barrière : après un « attendez », tout le monde attend")
    func gate() {
        let gate = RateLimitGate()
        let now = Date(timeIntervalSince1970: 1000)
        #expect(gate.wait(now: now) == 0)
        gate.hold(for: 8, now: now)
        #expect(gate.wait(now: now.addingTimeInterval(3)) == 5)
        gate.hold(for: 2, now: now)                      // une attente plus courte ne raccourcit pas la première
        #expect(gate.wait(now: now.addingTimeInterval(3)) == 5)
        #expect(gate.wait(now: now.addingTimeInterval(9)) == 0)
    }
}

@Suite("Attente écrite dans un message d'erreur")
struct RetryMessageTests {
    @Test("« try again in … » donne l'attente ; une limite de débit est reconnue")
    func parse() {
        #expect(RetryAfter.fromMessage("Rate limit reached for model. Please try again in 6.8s. Need more tokens?") == 6.8)
        #expect(RetryAfter.fromMessage("Please try again in 1m5.2s.") == 65.2)
        #expect(RetryAfter.fromMessage("Please try again in 250ms") == 0.25)
        #expect(RetryAfter.fromMessage("erreur sans attente") == nil)
        #expect(RetryAfter.isRateLimitMessage("Rate limit reached for model"))
        #expect(RetryAfter.isRateLimitMessage("Too many requests"))
        #expect(!RetryAfter.isRateLimitMessage("Invalid API key"))
    }
}
