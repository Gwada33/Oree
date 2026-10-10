import Foundation

/// What may be written to disk when the session is saved for the next launch.
public enum SessionPolicy {
    /// Private tabs are never saved (their addresses, titles and back/forward history would otherwise land
    /// in the database), nor are blank pages and Orée's own pages.
    public static func isSavable(url: URL?, isPrivate: Bool) -> Bool {
        guard !isPrivate, let url else { return false }
        return url.absoluteString != "about:blank" && url.scheme != "oree"
    }
}
