import AppKit
import NaturalLanguage
import Translation
import WebKit
import BrowserCore

/// Translates the page of one tab with the system's Translation framework: on-device, no model shipped with Orée, nothing
/// sent anywhere. Only text near the screen is translated; scrolling, clicking or a DOM change brings the next batch
/// (see `TranslationScript`). Needs macOS 26 (sessions without a SwiftUI view); older systems never see the feature.
@MainActor
final class PageTranslator {
    enum State: Equatable { case idle, translating, translated }

    enum Failure: Error, Equatable {
        case sameLanguage(String)
        case unknownLanguage
        case unsupported(source: String, target: String)
        case notInstalled(source: String, target: String)
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    /// A round of segments is being translated (drives the progress ring; `state` stays `.translated` between rounds).
    private(set) var isWorking = false { didSet { if isWorking != oldValue { onChange?() } } }
    /// Language of the current page (recognized from its text), nil until known.
    private(set) var pageLanguage: String?
    var onChange: (() -> Void)?
    var onFailure: ((Failure) -> Void)?

    static var isAvailable: Bool { if #available(macOS 26.0, *) { true } else { false } }

    /// The language the user reads: the first of their preferred languages.
    static var targetIdentifier: String { Locale.preferredLanguages.first ?? "en" }

    private let webView: () -> WKWebView?
    private var memory = TranslationMemory()
    private var task: Task<Void, Never>?
    private var session: AnyObject?          // TranslationSession (macOS 26), kept to cancel it
    private var wantsMore = false
    private var detecting = false
    private static let firstRound = 24, nextRound = 40, reach = 2.0

    init(webView: @escaping () -> WKWebView?) { self.webView = webView }

    // MARK: Language of the page

    /// Recognizes the page language once per page; cheap (a few KB of text, read in the isolated world).
    func detectIfNeeded() {
        guard Self.isAvailable, pageLanguage == nil, !detecting, state == .idle,
              let web = webView(), !web.isLoading, TranslationPolicy.canTranslate(url: web.url) else { return }
        detecting = true
        Task {
            defer { detecting = false }
            guard let reply = await run(TranslationScript.call("sample()")) as? [String: Any] else { return }
            // Only keep the result if the user is still on the page that was read.
            guard webView() === web else { return }
            pageLanguage = Self.recognize(text: reply["text"] as? String ?? "", declared: reply["lang"] as? String ?? "") ?? "und"
            onChange?()
        }
    }

    /// The recognizer is more reliable than `<html lang>` (often "en" on a page that is not), but needs enough text.
    static func recognize(text: String, declared: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 { return best.key.rawValue }
        let tag = TranslationPolicy.primary(declared)
        return tag.isEmpty ? nil : declared
    }

    /// Whether the button should be offered for this page.
    var shouldOffer: Bool {
        guard Self.isAvailable else { return false }
        return state != .idle || TranslationPolicy.shouldOffer(pageLanguage: pageLanguage, targetLanguage: Self.targetIdentifier)
    }

    /// Dev tooling (automation channel): where the translation stands.
    var report: String { "state=\(state) working=\(isWorking) lang=\(pageLanguage ?? "nil") remembered=\(memory.count)" }

    // MARK: User actions

    func toggle() { state == .idle ? translate() : restore() }

    func translate() {
        guard Self.isAvailable, state == .idle, let web = webView(), TranslationPolicy.canTranslate(url: web.url) else { return }
        state = .translating
        task = Task { [self] in
            if pageLanguage == nil || pageLanguage == "und", let reply = await run(TranslationScript.call("sample()")) as? [String: Any] {
                pageLanguage = Self.recognize(text: reply["text"] as? String ?? "", declared: reply["lang"] as? String ?? "") ?? "und"
            }
            guard let source = pageLanguage, source != "und" else { return finish(.unknownLanguage) }
            guard TranslationPolicy.shouldOffer(pageLanguage: source, targetLanguage: Self.targetIdentifier) else {
                return finish(.sameLanguage(Self.name(of: source)))
            }
            if #available(macOS 26.0, *) { await translateLoop(source: source) } else { finish(.failed("macOS 26")) }
        }
    }

    /// Puts the original texts back.
    func restore() {
        guard state != .idle else { return }
        task?.cancel()
        cancelSession()
        task = nil
        state = .idle
        isWorking = false
        Task { _ = await run(TranslationScript.call("restore()")) }
    }

    /// A new document replaced the page (or the tab went to sleep): the old script and its texts are gone with it.
    func reset() {
        task?.cancel()
        cancelSession()
        task = nil
        pageLanguage = nil
        detecting = false
        wantsMore = false
        state = .idle
        isWorking = false
    }

    /// The script saw a scroll, a click or a DOM change.
    func pageChanged() {
        guard state != .idle else { return }
        wantsMore = true        // picked up by the running loop, or the loop ends on its own and `kick()` restarts it
        kick()
    }

    // MARK: Translating

    private var loopRunning = false
    private func kick() {
        guard state == .translated, !loopRunning, wantsMore, let source = pageLanguage else { return }
        guard #available(macOS 26.0, *) else { return }
        task = Task { await translateLoop(source: source) }
    }

    @available(macOS 26.0, *)
    private func translateLoop(source sourceTag: String) async {
        guard !loopRunning else { return }
        loopRunning = true
        defer { loopRunning = false }
        let target = Locale.Language(identifier: Self.targetIdentifier)
        let source = Locale.Language(identifier: sourceTag)
        if session == nil {
            switch await Self.makeSession(source: source, target: target) {
            case .success(let made): session = made
            case .failure(let failure): return finish(failure)
            }
        }
        guard let session = session as? TranslationSession else { return }
        _ = await run(TranslationScript.call("watch()"))
        isWorking = true
        defer { isWorking = false }
        var rounds = 0
        repeat {
            wantsMore = false
            while !Task.isCancelled {
                let limit = rounds == 0 ? Self.firstRound : Self.nextRound
                guard let items = await run(TranslationScript.call("collect(\(limit), \(Self.reach))")) as? [[String: Any]], !items.isEmpty else { break }
                let segments = items.compactMap { item -> TranslationSegment? in
                    guard let id = (item["id"] as? NSNumber)?.intValue, let text = item["text"] as? String else { return nil }
                    return TranslationSegment(id: id, text: text)
                }
                let progressed = await translateRound(TranslationRound(segments: segments, memory: memory), with: session)
                if state == .translating { state = .translated }
                rounds += 1
                if !progressed { return finish(.failed("La traduction a échoué.")) }
            }
        } while wantsMore && !Task.isCancelled
        if state == .translating, !Task.isCancelled { state = .translated }
    }

    /// One round: known texts at once, the others through the model, each answer put in the page as soon as it arrives.
    /// Returns false when the model produced nothing at all for texts it was asked about (so the loop cannot spin).
    @available(macOS 26.0, *)
    private func translateRound(_ round: TranslationRound, with session: TranslationSession) async -> Bool {
        if !round.known.isEmpty { _ = await apply(round.known.map { ($0.id, $0.text) }) }
        guard !round.pending.isEmpty else { return true }
        let requests = round.pending.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)") }
        var settled = Set<Int>()
        do {
            for try await response in session.translate(batch: requests) {
                guard let key = response.clientIdentifier.flatMap(Int.init), round.pending.indices.contains(key) else { continue }
                let text = round.pending[key]
                memory.store(response.targetText, for: text)
                settled.insert(key)
                _ = await apply((round.waiting[text] ?? []).map { ($0, response.targetText) })
                if Task.isCancelled { break }
            }
        } catch is CancellationError {
        } catch {
            Log.tabs.error("Translation failed: \(error.localizedDescription, privacy: .public)")
        }
        // Anything the model did not answer goes back to the queue for a later round.
        let left = round.pending.indices.filter { !settled.contains($0) }.flatMap { round.waiting[round.pending[$0]] ?? [] }
        if !left.isEmpty { _ = await run(TranslationScript.call("release(\(left))")) }
        return !settled.isEmpty
    }

    private func apply(_ pairs: [(Int, String)]) async -> Bool {
        let items = pairs.map { ["id": $0.0, "text": $0.1] as [String: Any] }
        return await run(TranslationScript.source + "\nreturn __oreeTr.apply(items);", ["items": items]) != nil
    }

    // MARK: Session

    /// A session on a model that is already installed: `.lowLatency` (the fast translation model Safari uses) if it is,
    /// else `.highFidelity` (Apple Intelligence, about 3 segments a second here). Never asks for a download.
    @available(macOS 26.0, *)
    private static func makeSession(source: Locale.Language, target: Locale.Language) async -> Result<TranslationSession, Failure> {
        let names = (source: name(of: source.minimalIdentifier), target: name(of: target.minimalIdentifier))
        if #available(macOS 26.4, *) {
            var statuses: [LanguageAvailability.Status] = []
            for strategy in [TranslationSession.Strategy.lowLatency, .highFidelity] {
                let status = await LanguageAvailability(preferredStrategy: strategy).status(from: source, to: target)
                if status == .installed { return .success(TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)) }
                statuses.append(status)
            }
            if statuses.allSatisfy({ $0 == .unsupported }) { return .failure(.unsupported(source: names.source, target: names.target)) }
        } else {
            let status = await LanguageAvailability().status(from: source, to: target)
            if status == .installed { return .success(TranslationSession(installedSource: source, target: target)) }
            if status == .unsupported { return .failure(.unsupported(source: names.source, target: names.target)) }
        }
        return .failure(.notInstalled(source: names.source, target: names.target))
    }

    private func cancelSession() {
        if #available(macOS 26.0, *) { (session as? TranslationSession)?.cancel() }
        session = nil
    }

    private func finish(_ failure: Failure) {
        cancelSession()
        state = .idle
        isWorking = false
        Task { _ = await run(TranslationScript.call("restore()")) }
        onFailure?(failure)
    }

    static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: Page access

    /// Runs `body` in the translation world of the main frame (see `WKWebView.callJSON`).
    private func run(_ body: String, _ arguments: [String: Any] = [:], seconds: Double = 8) async -> Any? {
        await webView()?.callJSON(body, arguments: arguments, world: TranslationScript.world, seconds: seconds)
    }
}

/// Receives the page script's "something may have changed" and tells the tab's translator.
final class TranslationMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { Tab.tabsByWebView.object(forKey: message.webView)?.translator.pageChanged() }
    }
}
