import Foundation

/// Turns a failed page load into something a person can act on, in French
/// (the system's own messages are English and technical).
public enum LoadFailure: Equatable, Sendable {
    public enum CertificateProblem: Equatable, Sendable {
        case expired, notYetValid, untrusted, unknownAuthority, other
    }

    case offline
    case timeout
    case hostNotFound
    case cannotConnect
    case connectionLost
    case certificate(CertificateProblem)
    case other(String)

    public static func classify(_ error: Error) -> LoadFailure {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .other(nsError.localizedDescription) }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet: return .offline
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .hostNotFound
        case NSURLErrorCannotConnectToHost: return .cannotConnect
        case NSURLErrorNetworkConnectionLost: return .connectionLost
        case NSURLErrorServerCertificateHasBadDate: return .certificate(.expired)
        case NSURLErrorServerCertificateNotYetValid: return .certificate(.notYetValid)
        case NSURLErrorServerCertificateUntrusted: return .certificate(.untrusted)
        case NSURLErrorServerCertificateHasUnknownRoot: return .certificate(.unknownAuthority)
        case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired: return .certificate(.other)
        default: return .other(nsError.localizedDescription)
        }
    }

    /// One sentence for the error screen.
    public var message: String {
        switch self {
        case .offline: return "Vous n'êtes pas connecté à Internet."
        case .timeout: return "Le site met trop de temps à répondre."
        case .hostNotFound: return "Cette adresse n'existe pas ou son serveur est introuvable. Vérifiez l'orthographe."
        case .cannotConnect: return "Le serveur refuse la connexion ou n'est pas démarré."
        case .connectionLost: return "La connexion a été interrompue pendant le chargement."
        case .certificate(let problem): return problem.message
        case .other(let description): return description
        }
    }
}

extension LoadFailure.CertificateProblem {
    public var message: String {
        switch self {
        case .expired: return "son certificat de sécurité a expiré"
        case .notYetValid: return "son certificat de sécurité n'est pas encore valide (vérifiez la date de votre Mac)"
        case .untrusted: return "son certificat de sécurité n'est pas fiable"
        case .unknownAuthority: return "son certificat vient d'une autorité inconnue"
        case .other: return "le certificat demandé ou présenté a été refusé"
        }
    }
}
