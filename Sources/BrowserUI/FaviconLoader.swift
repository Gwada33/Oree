import AppKit

/// Fetches and caches site favicons. Falls back silently (caller keeps
/// showing its letter badge) if a site has no reachable `/favicon.ico` —
/// no retries, no bitmap decoding beyond what `NSImage` does for free.
///
/// `@MainActor`-bound: it's only ever used to feed AppKit views, and
/// `NSImage` itself isn't `Sendable`, so there's nothing to gain from making
/// this usable off the main actor.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private init() {}

    func icon(for host: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let cached = cache[host] {
            completion(cached)
            return
        }
        guard !inFlight.contains(host), let url = URL(string: "https://\(host)/favicon.ico") else {
            completion(nil)
            return
        }
        inFlight.insert(host)
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            Task { @MainActor in
                self?.inFlight.remove(host)
                guard let data,
                      let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let image = NSImage(data: data) else {
                    completion(nil)
                    return
                }
                self?.cache[host] = image
                completion(image)
            }
        }.resume()
    }
}
