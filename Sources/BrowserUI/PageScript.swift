import WebKit

extension WKWebView {
    /// Runs `body` (an async function body) in `world` of the main frame and returns its result decoded from JSON; nil on error, or
    /// when the page does not answer in time (a stuck page must not block a feature). The JSON round trip keeps a non-Sendable
    /// value from crossing the timeout race.
    @MainActor
    func callJSON(_ body: String, arguments: [String: Any] = [:], world: WKContentWorld, seconds: Double = 8) async -> Any? {
        let wrapped = "return JSON.stringify(await (async () => {\n\(body)\n})());"
        let json: String? = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                finish(try? await self.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, contentWorld: world) as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
        return json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }
}
