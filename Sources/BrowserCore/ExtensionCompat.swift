import Foundation
import CryptoKit

/// Rend une extension Chrome utilisable dans WebKit : WebKit n'a que 16 des ~70 API `chrome.*`. On copie l'extension déjà décompressée,
/// puis on y fait charger `__oree/compat.js` AVANT tout autre script (service worker, page de fond, popup, réglages, panneau…) ;
/// ce script ajoute les API manquantes (voir `Resources/ExtCompat/oree-compat.js`). Le manifeste d'origine est gardé dans `__oree/manifest.orig.json`.
/// L'opération est idempotente : la refaire (nouvelle version du script) donne le même résultat.
public enum ExtensionCompat {
    public static let folder = "__oree"
    static let marker = "<!--oree-compat-->"
    static let tag = marker + "<script charset=\"utf-8\" src=\"/__oree/compat.js\"></script>"

    public enum CompatError: Error { case noManifest }

    /// L'identifiant que Chrome donne à une extension qui a une clé (`key` du manifeste) : SHA-256 de la clé publique, 16 premiers octets, chaque demi-octet écrit a…p.
    /// Les services (connexion OAuth, pages externes) reconnaissent l'extension à cet identifiant ; Orée le lui donne pour qu'ils la reconnaissent aussi.
    public static func chromeID(forKey base64Key: String) -> String? {
        guard let der = Data(base64Encoded: base64Key.filter { !$0.isWhitespace }), !der.isEmpty else { return nil }
        let digest = SHA256.hash(data: der)
        return String(digest.prefix(16).flatMap { byte in [byte >> 4, byte & 0xF] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    /// L'identifiant Chrome de l'extension décompressée dans `root` (nil si son manifeste n'a pas de `key`).
    public static func chromeID(at root: URL) -> String? {
        let original = root.appendingPathComponent("\(folder)/manifest.orig.json")
        let file = FileManager.default.fileExists(atPath: original.path) ? original : root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let key = json["key"] as? String else { return nil }
        return chromeID(forKey: key)
    }

    /// Le script complet : le noyau (`core.js`) avec les sections (`sections/NN-nom.js`, dans l'ordre des noms) à la place de son repère.
    public static func assemble(core: String, sections: [String]) -> String {
        core.replacingOccurrences(of: "//@@SECTIONS@@", with: sections.joined(separator: "\n"))
    }

    /// `root` : le dossier qui contient `manifest.json`. `shim` : le contenu de `oree-compat.js`.
    /// `backgroundAsPage` : un service worker devient une page de fond persistante (voir `patched`).
    public static func apply(to root: URL, shim: Data, backgroundAsPage: Bool = false) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json"), originalURL = dir.appendingPathComponent("manifest.orig.json")
        if !fm.fileExists(atPath: originalURL.path) {
            guard fm.fileExists(atPath: manifestURL.path) else { throw CompatError.noManifest }
            try fm.copyItem(at: manifestURL, to: originalURL)
        }
        guard var manifest = (try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL))) as? [String: Any] else { throw CompatError.noManifest }
        try write(shim, to: dir.appendingPathComponent("compat.js"))
        manifest = patched(manifest, root: root, folderURL: dir, backgroundAsPage: backgroundAsPage)
        try write(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]), to: manifestURL)
        try patchHTMLFiles(under: root)
    }

    /// Le manifeste modifié : le script de compatibilité passe en premier dans le fond, et `nativeMessaging` (le pont vers l'app) est demandé.
    static func patched(_ original: [String: Any], root: URL, folderURL: URL, backgroundAsPage: Bool = false) -> [String: Any] {
        var m = original
        var permissions = (m["permissions"] as? [String]) ?? []
        if !permissions.contains("nativeMessaging") { permissions.append("nativeMessaging") }
        m["permissions"] = permissions
        guard var background = m["background"] as? [String: Any] else { return m }
        let shimPath = "\(folder)/compat.js"
        if let worker = background["service_worker"] as? String {
            let isModule = (background["type"] as? String) == "module"
            let target = worker.hasPrefix("/") ? worker : "/" + worker
            if backgroundAsPage {
                // WebKit arrête le service worker quelques secondes après son démarrage et ne le réveille pas pour un clic sur le bouton (Claude) : on le charge dans une page
                // de fond persistante, qui reste en vie (comme une page de fond Manifest V2). Le script de compatibilité passe en premier.
                let html = "<!doctype html><meta charset=\"utf-8\">\(marker)<script charset=\"utf-8\" src=\"/\(shimPath)\"></script><script \(isModule ? "type=\"module\" " : "")charset=\"utf-8\" src=\"\(target)\"></script>\n"
                try? write(Data(html.utf8), to: folderURL.appendingPathComponent("background.html"))
                background = ["page": "\(folder)/background.html", "persistent": true]
            } else {
                // Le service worker d'origine est chargé par un petit fichier qui charge d'abord le script de compatibilité (ES module ou script classique).
                let source = isModule ? "import \"/\(shimPath)\";\nimport \"\(target)\";\n" : "importScripts(\"/\(shimPath)\", \"\(target)\");\n"
                try? write(Data(source.utf8), to: folderURL.appendingPathComponent("sw.js"))
                background["service_worker"] = "\(folder)/sw.js"
            }
        }
        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll { $0 == shimPath }
            background["scripts"] = [shimPath] + scripts
        }
        m["background"] = background
        return m
    }

    /// Insère la balise du script de compatibilité en tête de chaque page HTML de l'extension (popup, réglages, page de fond, panneau latéral…).
    static func patchHTMLFiles(under root: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension.lowercased() == "html" && !url.path.contains("/\(folder)/") && !url.path.contains("/node_modules/") {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = injected(into: text)
            if updated != text { try write(Data(updated.utf8), to: url) }
        }
    }

    static func injected(into html: String) -> String {
        if html.contains(marker) { return html }
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) { return html.replacingCharacters(in: head, with: String(html[head]) + tag) }
        if let doctype = html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) { return html.replacingCharacters(in: doctype, with: String(html[doctype]) + tag) }
        return tag + html
    }

    private static func write(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }
}
