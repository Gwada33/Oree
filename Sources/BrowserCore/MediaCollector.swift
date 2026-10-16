import Foundation

/// Un média trouvé dans une page : son adresse et son genre.
public struct PageMedia: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video, audio }
    public let url: URL
    public let kind: Kind
}

/// Trie ce que le script de la page a trouvé (adresses brutes) : garde http(s), retire les doublons, garde l'ordre de la page.
/// Les `data:` et `blob:` sont écartés : ils n'ont pas d'adresse que l'on puisse retélécharger.
public enum MediaCollector {
    public static func parse(json: String, base: URL?) -> [PageMedia] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        var seen = Set<String>(), result: [PageMedia] = []
        for entry in raw {
            guard let text = entry["url"], let kind = PageMedia.Kind(rawValue: entry["kind"] ?? ""),
                  let url = URL(string: text, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(PageMedia(url: url, kind: kind))
        }
        return result
    }

    /// Un nom de fichier par média, sans collision (`photo.jpg`, `photo 2.jpg`…) et sans caractère dangereux.
    public static func fileNames(for media: [PageMedia]) -> [String] {
        var used = Set<String>()
        return media.enumerated().map { index, item in
            var name = item.url.lastPathComponent.removingPercentEncoding ?? item.url.lastPathComponent
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty || name == "-" { name = "\(item.kind.rawValue) \(index + 1)" }
            if name.hasPrefix(".") { name = "_" + name }
            var candidate = name, n = 2
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            while !used.insert(candidate.lowercased()).inserted {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; n += 1
            }
            return candidate
        }
    }
}
