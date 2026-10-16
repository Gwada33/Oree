import Foundation

/// Lire ce que dit un fournisseur d'IA sur le temps d'attente : l'en-tête `Retry-After` (secondes ou date HTTP) et les durées des en-têtes
/// `x-ratelimit-reset-*` de Groq (« 2.5s », « 1m30s », « 250ms »).
public enum RetryAfter {
    /// Secondes à attendre, ou nil si l'en-tête est absent ou illisible.
    public static func seconds(from header: String?, now: Date = Date()) -> Double? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let value = Double(raw), value >= 0, value.isFinite { return value }
        if let duration = duration(raw) { return duration }
        // Date HTTP (« Wed, 21 Oct 2026 07:28:00 GMT »)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    /// « 1m30.5s » → 90,5 ; « 250ms » → 0,25 ; « 2h » → 7200.
    public static func duration(_ text: String) -> Double? {
        var total = 0.0, number = "", matched = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber || c == "." { number.append(c); index = text.index(after: index); continue }
            var unit = String(c)
            let next = text.index(after: index)
            if c == "m", next < text.endIndex, text[next] == "s" { unit = "ms"; index = text.index(after: next) } else { index = next }
            guard let value = Double(number) else { return nil }
            number = ""
            switch unit {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            default: return nil
            }
            matched = true
        }
        return matched && number.isEmpty ? total : nil
    }
}

/// Quand réessayer une requête au modèle, et au bout de combien de temps. Une requête au modèle ne fait rien dans le navigateur : la relancer ne peut pas
/// doubler une action (les actions, elles, ne sont jamais rejouées par ce mécanisme). Pur : l'attente et l'aléa sont fournis par l'appelant.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts = 4                 // la requête initiale comprise
    public var baseDelay = 1.5                 // secondes, doublées à chaque échec
    public var maxDelay = 30.0                 // une attente plus longue demandée par le fournisseur : on rend la main
    public var maxTotalWait = 75.0             // le temps total passé à attendre pour une même requête
    public init() {}

    public enum Decision: Equatable, Sendable {
        case retry(after: Double)
        case giveUp(reason: String)
    }

    /// Les réponses qui valent un nouvel essai : limite de débit, serveur occupé ou en panne passagère, délai dépassé.
    public static func isTransient(status: Int) -> Bool { [408, 425, 429, 500, 502, 503, 504].contains(status) }

    /// - Parameters:
    ///   - status: code HTTP, ou nil pour une erreur de transport (réseau coupé, délai dépassé).
    ///   - attempt: le nombre d'essais déjà faits (1 après le premier échec).
    ///   - retryAfter: ce que le fournisseur a demandé, en secondes.
    ///   - hint: le fournisseur dit que l'échec est un accident à relancer tout de suite (appel d'outil mal écrit).
    ///   - waited: le temps déjà attendu pour cette requête.
    ///   - random: un nombre entre 0 et 1 (la part d'aléa du délai : évite que deux relances partent ensemble).
    public func decide(status: Int?, attempt: Int, retryAfter: Double?, hint: Double? = nil, waited: Double = 0, random: Double = 0.5) -> Decision {
        let transient = status.map(Self.isTransient) ?? true
        guard transient || hint != nil else { return .giveUp(reason: "erreur définitive") }
        guard attempt < maxAttempts else { return .giveUp(reason: "nombre d'essais atteint") }
        var delay: Double
        if let asked = retryAfter ?? hint {
            guard asked <= maxDelay else { return .giveUp(reason: "le fournisseur demande d'attendre \(Int(asked.rounded())) s") }
            // Ce qui est demandé fait foi ; un peu d'aléa au-dessus pour ne pas arriver pile avec les autres.
            delay = asked + 0.25 + 0.5 * random
        } else {
            delay = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
            delay *= 0.8 + 0.4 * random
        }
        delay = (delay * 100).rounded() / 100
        guard waited + delay <= maxTotalWait else { return .giveUp(reason: "attente totale dépassée") }
        return .retry(after: delay)
    }
}

/// Un fournisseur qui vient de dire « attendez N secondes » vaut pour toutes les requêtes qui suivent : elles patientent ensemble au lieu de le marteler.
public final class RateLimitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var until = Date.distantPast
    public init() {}

    public func hold(for seconds: Double, now: Date = Date()) {
        lock.lock(); until = max(until, now.addingTimeInterval(seconds)); lock.unlock()
    }
    /// Combien de temps attendre avant de partir (0 si la voie est libre).
    public func wait(now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        return max(0, until.timeIntervalSince(now))
    }
}
