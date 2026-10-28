import Foundation

/// La messagerie native de Chrome : une extension parle à un programme de l'ordinateur (un « hôte ») par son entrée et sa sortie standard,
/// chaque message étant du JSON UTF-8 précédé de sa longueur sur 4 octets (ordre de l'ordinateur).
public enum NativeMessaging {
    /// Un message prêt à envoyer à l'hôte.
    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count)
        return Data(bytes: &length, count: 4) + json
    }

    /// Sépare les messages complets d'un flux reçu ; renvoie aussi ce qui reste (un message incomplet). `limit` : taille maximale d'un message (1 Mo chez Chrome pour ce qui vient de l'hôte).
    public static func split(_ buffer: Data, limit: Int = 1_048_576) -> (messages: [Data], rest: Data, tooLarge: Bool) {
        var messages: [Data] = []; var offset = buffer.startIndex
        while buffer.distance(from: offset, to: buffer.endIndex) >= 4 {
            let length = buffer[offset..<offset + 4].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            if length > limit { return (messages, Data(), true) }
            let end = offset + 4 + length
            guard end <= buffer.endIndex else { break }
            messages.append(buffer[(offset + 4)..<end]); offset = end
        }
        return (messages, Data(buffer[offset...]), false)
    }

    public struct Host: Equatable, Sendable {
        public let name: String
        public let path: String
        public let allowedOrigins: [String]
    }

    /// Les dossiers où les navigateurs rangent les déclarations d'hôtes (celles qu'un programme comme Claude Code installe pour Chrome).
    public static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser, extra: [URL] = []) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true), system = URL(fileURLWithPath: "/Library", isDirectory: true)
        let browsers = ["Google/Chrome", "Google/Chrome Beta", "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data"]
        return extra + browsers.map { support.appendingPathComponent($0 + "/NativeMessagingHosts", isDirectory: true) } + browsers.map { system.appendingPathComponent($0 + "/NativeMessagingHosts", isDirectory: true) }
    }

    /// Trouve l'hôte `name` et vérifie qu'il accepte l'extension `extensionID` (`allowed_origins`). Le nom ne doit contenir que a-z 0-9 _ . (comme chez Chrome).
    public static func locate(_ name: String, extensionID: String, directories: [URL]) -> Result<Host, LocateError> {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }), !name.hasPrefix("."), !name.contains("..") else { return .failure(.invalidName) }
        for directory in directories {
            let file = directory.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["name"] as? String) == name, (json["type"] as? String) == "stdio", let path = json["path"] as? String, path.hasPrefix("/") else { continue }
            let origins = (json["allowed_origins"] as? [String]) ?? []
            guard origins.contains("chrome-extension://\(extensionID)/") else { return .failure(.notAllowed(host: name)) }
            return .success(Host(name: name, path: path, allowedOrigins: origins))
        }
        return .failure(.notFound)
    }

    public enum LocateError: Error, Equatable { case invalidName, notFound, notAllowed(host: String) }
}
