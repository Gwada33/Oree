import Foundation

/// Chrome Web Store pages and downloads: recognises an extension's page and builds the address its package (.crx) comes from,
/// so Orée can offer to install it without the user having to find the file.
public enum WebStoreExtension {
    /// The 32-letter identifier (a–p) of the extension shown on a Web Store page, or nil for any other page.
    /// Both store addresses: `chromewebstore.google.com/detail/<name>/<id>` and the old `chrome.google.com/webstore/detail/<name>/<id>`.
    public static func id(from url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let detail: ArraySlice<String>
        switch host {
        case "chromewebstore.google.com": detail = parts[...]
        case "chrome.google.com": guard parts.first == "webstore" else { return nil }; detail = parts.dropFirst()
        default: return nil
        }
        guard detail.first == "detail", let id = detail.last, isIdentifier(id) else { return nil }
        return id
    }

    public static func isIdentifier(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Where Google serves the package of an extension (a redirect to the .crx file).
    public static func packageURL(id: String, chromeVersion: String = "130.0.0.0") -> URL? {
        guard isIdentifier(id) else { return nil }
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        parts?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"), URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"), URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts?.url
    }

    /// The extension's name as the store writes it in the tab title ("uBlock Origin - Chrome Web Store").
    public static func name(fromTitle title: String?) -> String {
        guard let title else { return "cette extension" }
        let name = title.replacingOccurrences(of: #"\s*[-–]\s*Chrome Web Store\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Chrome Web Store" ? "cette extension" : name
    }
}
