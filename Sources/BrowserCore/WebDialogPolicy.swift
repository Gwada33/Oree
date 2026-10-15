import Foundation

/// What the window for a page's `alert`, `confirm` or `prompt` says. Always names the site: a page must not be able to pass as Orée.
public struct WebDialogContent: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var cancelTitle: String?
}

public enum WebDialogPolicy {
    /// A page can send a message of any length: the window shows the beginning.
    public static let maxMessageLength = 1000

    static func site(_ url: URL?) -> String {
        guard let host = url?.host, !host.isEmpty else { return "Une page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func shown(_ message: String) -> String {
        message.count > maxMessageLength ? String(message.prefix(maxMessageLength)) + "…" : message
    }

    public static func alert(message: String, frame: URL?) -> WebDialogContent {
        WebDialogContent(title: "« \(site(frame)) » indique", message: shown(message), confirmTitle: "OK", cancelTitle: nil)
    }

    public static func confirm(message: String, frame: URL?) -> WebDialogContent {
        WebDialogContent(title: "« \(site(frame)) » demande confirmation", message: shown(message), confirmTitle: "OK", cancelTitle: "Annuler")
    }

    public static func prompt(message: String, frame: URL?) -> WebDialogContent {
        WebDialogContent(title: "« \(site(frame)) » demande une réponse", message: shown(message), confirmTitle: "OK", cancelTitle: "Annuler")
    }
}
