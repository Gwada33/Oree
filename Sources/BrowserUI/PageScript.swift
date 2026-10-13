import WebKit
import OreeObjC
import BrowserCore

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
                finish(await self.safeCall(wrapped, arguments: arguments, world: world) as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
        return json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }
}


/// Les appels JavaScript « sans filet » plantaient l'application quand WebKit levait une exception Objective-C (onglet fermé ou endormi pendant le
/// script) : ces versions l'attrapent et répondent nil, comme pour une erreur ordinaire. À utiliser à la place de `evaluateJavaScript` /
/// `callAsyncJavaScript` en `async`.
/// Un résultat JavaScript (valeur de liste de propriétés) qui traverse un `await` : il n'est lu que par l'appelant, sur le fil principal.
struct JSResult: @unchecked Sendable { var value: Any? }

/// Garantit qu'une suite (`continuation`) n'est reprise qu'une fois : une seconde reprise ferait planter l'application.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func callAsFunction(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } }
}

extension WKWebView {
    /// Lance un script sans attendre sa réponse (avec le même filet contre les exceptions).
    @MainActor
    func safeRun(_ script: String, world: WKContentWorld = .page, completion: (@MainActor () -> Void)? = nil) {
        var reason: NSString?
        let started = OreeEvaluateJS(self, script, nil, world, { _, _ in
            if let completion { MainActor.assumeIsolated { completion() } }
        }, &reason)
        if !started { Log.tabs.error("evaluateJavaScript a levé une exception, ignorée : \((reason as String?) ?? "?", privacy: .public)") }
    }

    @MainActor
    func safeEvaluate(_ script: String, frame: WKFrameInfo? = nil, world: WKContentWorld = .page) async -> Any? {
        let boxed: JSResult = await withCheckedContinuation { (continuation: CheckedContinuation<JSResult, Never>) in
            var reason: NSString?
            let once = ResumeOnce()
            let started = OreeEvaluateJS(self, script, frame, world, { value, error in
                once { continuation.resume(returning: JSResult(value: error == nil ? value : nil)) }
            }, &reason)
            if !started {
                Log.tabs.error("evaluateJavaScript a levé une exception, ignorée : \((reason as String?) ?? "?", privacy: .public)")
                once { continuation.resume(returning: JSResult(value: nil)) }
            }
        }
        return boxed.value
    }

    @MainActor
    func safeCall(_ body: String, arguments: [String: Any] = [:], world: WKContentWorld) async -> Any? {
        let boxed: JSResult = await withCheckedContinuation { (continuation: CheckedContinuation<JSResult, Never>) in
            var reason: NSString?
            let once = ResumeOnce()
            let started = OreeCallAsyncJS(self, body, arguments, world, { value, error in
                once { continuation.resume(returning: JSResult(value: error == nil ? value : nil)) }
            }, &reason)
            if !started {
                Log.tabs.error("callAsyncJavaScript a levé une exception, ignorée : \((reason as String?) ?? "?", privacy: .public)")
                once { continuation.resume(returning: JSResult(value: nil)) }
            }
        }
        return boxed.value
    }
}
