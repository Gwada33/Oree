import Foundation

/// Un site installé comme application : sa propre fenêtre (sans onglets ni barre latérale), son nom, son icône, et un raccourci macOS (.app) dans Applications.
public struct WebApp: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var startURL: String
    public var createdAt: Date
    /// Application indépendante (son propre processus, sans Orée) ou fenêtre d'Orée.
    public var standalone: Bool

    public init(id: String = UUID().uuidString, name: String, startURL: String, createdAt: Date = Date(), standalone: Bool = false) {
        self.id = id; self.name = name; self.startURL = startURL; self.createdAt = createdAt; self.standalone = standalone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name); startURL = try c.decode(String.self, forKey: .startURL)
        createdAt = try c.decode(Date.self, forKey: .createdAt); standalone = try c.decodeIfPresent(Bool.self, forKey: .standalone) ?? false
    }

    /// Le nom d'hôte qui définit le site de l'application (sans « www. »).
    public var scopeHost: String { WebAppScope.normalized(URL(string: startURL)?.host) }
}

public enum WebAppScope {
    public static func normalized(_ host: String?) -> String {
        let h = (host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Une adresse est « dans l'application » si c'est le même site ou un de ses sous-domaines. Le reste (un lien vers un autre site) s'ouvre dans le navigateur.
    public static func contains(_ url: URL, in app: WebApp) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }     // about:, blob:, data: restent dans la fenêtre
        let host = normalized(url.host), scope = app.scopeHost
        return !scope.isEmpty && (host == scope || host.hasSuffix("." + scope))
    }
}

/// La liste des applications, gardée dans un fichier JSON (et leurs icônes à côté).
public struct WebAppStore: Sendable {
    public let directory: URL

    public init(directory: URL = WebAppStore.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["HB_WEBAPPS_STORE"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HyperBrowser/Apps", isDirectory: true)
    }

    private var file: URL { directory.appendingPathComponent("apps.json") }
    public func iconURL(for id: String) -> URL { directory.appendingPathComponent("icons/\(id).png") }

    public func all() -> [WebApp] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([WebApp].self, from: data)) ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func app(id: String) -> WebApp? { all().first { $0.id == id } }

    /// Une application pour ce site existe-t-elle déjà ?
    public func app(forHost host: String?) -> WebApp? { let h = WebAppScope.normalized(host); return all().first { $0.scopeHost == h } }

    public func add(_ app: WebApp) throws {
        var list = all().filter { $0.id != app.id }
        list.append(app)
        try write(list)
    }

    public func remove(id: String) throws {
        try write(all().filter { $0.id != id })
        try? FileManager.default.removeItem(at: iconURL(for: id))
    }

    private func write(_ list: [WebApp]) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("icons", isDirectory: true), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: file, options: .atomic)
    }
}

/// Le raccourci macOS d'une application : un petit .app qui ouvre la fenêtre de l'application dans Orée et garde son icône dans le Dock tant qu'elle est ouverte.
public enum WebAppShortcut {
    public static let scheme = "oree-app"
    public static let closedNotification = "com.nolhan.hyperbrowser.webapp.closed"

    /// Un nom de dossier sûr pour « Nom.app ».
    public static func folderName(for name: String) -> String {
        let cleaned = name.map { "/:\\\0".contains($0) ? "-" : $0 }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Application" : String(cleaned.prefix(60))) + ".app"
    }

    public static func openURL(for app: WebApp) -> URL { URL(string: "\(scheme)://open/\(app.id)")! }

    /// Le `Info.plist` du raccourci.
    public static func infoPlist(for app: WebApp, oreePath: String) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleExecutable": app.standalone ? "OreeWebApp" : "OreeAppLauncher", "CFBundleIdentifier": "com.nolhan.hyperbrowser.webapp." + app.id.lowercased(), "CFBundleName": app.name, "CFBundleDisplayName": app.name,
            "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true, "LSApplicationCategoryType": "public.app-category.productivity",
            "OreeAppID": app.id, "OreeAppURL": app.startURL, "OreePath": oreePath, "OreeBundleID": "com.nolhan.hyperbrowser",
        ]
        if app.standalone {      // une vraie application : le système demande l'accord pour la caméra, le micro et la position
            plist["NSCameraUsageDescription"] = "\(app.name) peut utiliser la caméra."
            plist["NSMicrophoneUsageDescription"] = "\(app.name) peut utiliser le micro."
            plist["NSLocationWhenInUseUsageDescription"] = "\(app.name) peut utiliser votre position."
            plist["NSAppTransportSecurity"] = ["NSAllowsArbitraryLoads": true]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
