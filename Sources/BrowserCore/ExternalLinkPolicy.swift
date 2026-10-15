import Foundation

/// What to do with a link whose scheme a web view cannot show (mailto:, tel:, zoommtg:…): it belongs to another app.
public enum ExternalLinkPolicy {
    public enum Decision: Equatable, Sendable {
        /// The page is ours to show (http, https, about, data, blob, oree…): not an external link.
        case notExternal
        /// Opens straight away: the schemes everyone expects to leave the browser (mail, phone, messages, FaceTime).
        case openDirectly
        /// Opens only after the user agrees, naming the site and the app.
        case askFirst
        /// Never opens from a web page.
        case block
    }

    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "oree", "ws", "wss", "javascript", "view-source", "applewebdata"]
    static let direct: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "callto"]
    /// Local files and system plumbing: a web page has no business launching them.
    static let blocked: Set<String> = ["file", "x-apple.systempreferences", "applescript", "osascript", "x-man-page", "shortcuts", "ssh", "telnet", "vnc", "smb", "afp", "nfs", "ftp", "sftp"]

    /// `userInitiated`: a click or a form, not a script that redirects by itself.
    public static func decision(for url: URL?, userInitiated: Bool) -> Decision {
        guard let scheme = url?.scheme?.lowercased(), !scheme.isEmpty else { return .notExternal }
        if webSchemes.contains(scheme) { return .notExternal }
        if blocked.contains(scheme) { return .block }
        if !userInitiated { return .block }                          // an app does not launch because a page redirected
        return direct.contains(scheme) ? .openDirectly : .askFirst
    }
}
