import AppKit
import BrowserCore
import BrowserStorage
import WebKit

/// Fait le lien entre le panneau, le fournisseur d'IA (Groq, Mistral ou LM Studio), la page et la recherche. Une conversation par onglet.
///
/// Chaque question lance la boucle d'agent (`AgentLoop`, BrowserCore) : un routage léger décide d'où vient la réponse (connaissances du modèle, page ouverte, web, action),
/// le modèle demande des outils, le navigateur les fait (avec confirmation pour tout geste sensible), jusqu'à la réponse ou un plafond (15 étapes, 3 recherches, 5 pages).
/// Rien n'est installé ni téléchargé : le panneau n'a pas de modèle embarqué.
@MainActor
final class AIPanelController {
    struct Hooks {
        var activeWebView: () -> WKWebView?
        var pageHost: () -> NSView?                // la zone de la page : Luciole s'y déplace au-dessus de la WebView
        var navigate: (String) async -> Bool
        var openTab: (URL) -> Void
        var windowWidth: () -> CGFloat
        var isPrivate: () -> Bool                  // l'onglet actif est privé : rien n'est gardé
        var onLayout: (CGFloat) -> Void           // largeur dont la page doit s'écarter (0 : rien)
        var searchHistory: (String) -> [(title: String, url: String)]     // historique et favoris (jamais appelé en navigation privée)
        var addNote: (String) -> Void
        var openAnswerPage: (_ title: String, _ html: String) -> Void   // la réponse mise en page, dans un nouvel onglet
        var assistantFrame: () -> NSRect?                                // le bouton de Luciole dans la barre d'outils, en coordonnées de fenêtre
        var keepPassage: (_ passage: String) -> Void                      // « Garder » : la page, avec un lien qui ramène au passage, va dans la liste de lecture
    }

    private let panel = AIPanelView()
    private let overlay = LucioleOverlayView()
    private let dim = LucioleDimView()
    /// Les éléments touchés pendant la tâche (repère du document, px CSS), avec le numéro de l'étape : le chemin sur la page.
    private var reveals: [(step: Int, doc: CGRect)] = []
    private var pathClear: Task<Void, Never>?
    /// Luciole dans la page (réglage) : la couche remplace le panneau. Tant que la page ne sait pas montrer une validation, une question ou un état du modèle,
    /// le panneau latéral s'ouvre pour ces moments-là (`panelFallback`) : une confirmation n'est jamais invisible.
    private var overlayOpen = false
    private var panelFallback = false
    /// Luciole est retournée dormir mais le chemin (60 s) et la petite bulle de fin restent affichés par la couche.
    private var restShown = false
    private var restBubbleText: String?
    private var modelPrimaryAction: AIPanelView.ModelAction?
    /// La mascotte de la barre d'outils : nil = elle est partie dans la page (appelée, ou près d'une sélection), sinon sa pose (sleep au repos, happy après une tâche).
    var onRestPose: ((LucioleState?) -> Void)?
    private var inPage: Bool { SettingsStore.shared.lucioleInPage }
    private let hooks: Hooks
    /// Appelé quand le panneau s'ouvre ou se ferme (le bouton de la barre d'outils suit).
    var onVisibilityChange: ((Bool) -> Void)?
    /// Une tâche vient de finir : route, durée, réussite et coût (journal d'événements ; jamais la question ni la réponse).
    var onTaskFinished: ((_ route: String, _ ms: Int, _ ok: Bool, _ usage: AIUsageMeter.Snapshot) -> Void)?
    private var widthConstraint: NSLayoutConstraint!
    private let search = SearchTab()
    private let cursor = AgentCursor()
    private func attachCursor() { if let host = hooks.pageHost() { cursor.attach(to: host) } }

    private var failure: String?
    /// Une tâche arrêtée par une erreur du fournisseur (limite de débit, réseau) : elle peut repartir de là où elle en était.
    private var resumable: (loop: AgentLoop, task: String)?
    /// La question en cours : sert à choisir, dans une page longue, les passages qui y répondent.
    private var currentTask = ""
    /// La pose de Luciole dictée par le dernier événement réel de la tâche (nil : aucune tâche).
    private var eventPose: LucioleState?
    private var eventPoseReset: Task<Void, Never>?
    /// Secondes avant le nouvel essai quand le fournisseur limite le débit (nil : pas d'attente).
    private var rateLimitWait: Int?
    private let searchCache = TTLCache<AgentToolResult>(capacity: 32)
    private var conversations: [UUID: [AIMessage]] = [:]
    private var currentTab: UUID?
    private var currentTitle = ""
    // Mémoire (discussions passées + journal) : un fichier sur ce Mac, jamais en navigation privée.
    private var memory = LucioleMemory.load()
    private var discussionIDs: [UUID: UUID] = [:]            // onglet → discussion en cours
    private var pendingFacts: [String] = []                  // ce que la personne a répondu aux questions de la tâche en cours
    private static let saveQueue = DispatchQueue(label: "oree.luciole.memory")
    private var memoryOn: Bool { SettingsStore.shared.lucioleMemoryEnabled && !hooks.isPrivate() }
    /// Un lien ouvert depuis le panneau s'ouvre dans un nouvel onglet : la discussion l'y suit (sinon elle « disparaît » à chaque lien cliqué).
    private var inheritFrom: UUID?
    private var lastPartialRefresh = Date.distantPast
    private var shareContext = true
    private var cloudKeys: Set<AIProvider> = AIPanelController.presentKeys()
    private static func presentKeys() -> Set<AIProvider> { Set(AIProvider.allCases.filter { $0.isCloud && CloudKeychain($0).hasKey }) }
    private var cloudKeyPresent: Bool { cloudKeys.contains(provider) }
    /// LM Studio : le serveur local répond-il (nil : pas encore essayé) et quels modèles de conversation propose-t-il ?
    private var lmStudio: (reachable: Bool?, models: [String]) = (nil, [])
    private var lmStudioError = ""
    private var lmModel: String? { LMStudio.chooseModel(preferred: SettingsStore.shared.aiModel(for: .lmstudio), available: lmStudio.models) }

    private func probeLMStudio() async {
        let url = LMStudio.modelsURL(base: SettingsStore.shared.lmStudioBase)
        // 8 s : la première connexion à une machine du réseau attend la réponse à la fenêtre macOS « Réseau local ».
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { lmStudio = (true, LMStudio.parseModels(data)); lmStudioError = "" }
            else { lmStudio = (false, []); lmStudioError = "réponse HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)" }
        } catch {
            lmStudio = (false, []); lmStudioError = "\((error as NSError).localizedDescription) (code \((error as NSError).code))"
        }
        refresh()
    }
    /// Le fournisseur en usage : Groq, Mistral ou LM Studio. Les pages lues partent chez le fournisseur en nuage quand il est choisi : le panneau le dit.
    private var provider: AIProvider { AIProvider.effective(stored: SettingsStore.shared.aiProviderChoice, keys: cloudKeys) }
    // La tâche en cours
    private var agentTask: Task<Void, Never>?
    private var runTab: UUID?
    private var runID = UUID()           // une tâche arrêtée peut finir plus tard : seule la tâche courante met l'affichage à jour
    private var pending: AIPending?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var questionContinuation: CheckedContinuation<String?, Never>?

    private static let widthKey = "oree.ai.panelWidth"
    private var width = AIPanelMetrics.clamp((UserDefaults.standard.object(forKey: AIPanelController.widthKey) as? Double) ?? AIPanelMetrics.defaultWidth)

    init(contentView: NSView, top: NSLayoutYAxisAnchor, hooks: Hooks) {
        self.hooks = hooks
        panel.isHidden = true
        contentView.addSubview(panel)
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.topAnchor.constraint(equalTo: top), overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                                     overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)])
        overlay.onSubmit = { [weak self] text in self?.ask(text) }
        overlay.onStop = { [weak self] in self?.stop() }
        overlay.onClose = { [weak self] in self?.close() }
        overlay.onToggleShare = { [weak self] in self?.shareContext.toggle(); self?.refresh() }
        overlay.onOpenSource = { [weak self] url in
            guard let self else { return }
            self.inheritFrom = self.currentTab; self.hooks.openTab(url); self.inheritFrom = nil
        }
        overlay.onGesture = { [weak self] gesture in self?.gesture(gesture) }
        overlay.onConfirm = { [weak self] ok in self?.resolveConfirm(ok) }
        overlay.onAnswer = { [weak self] text in self?.resolveQuestion(text) }
        overlay.onModelPrimary = { [weak self] in if let action = self?.modelPrimaryAction { self?.modelAction(action) } }
        cursor.onReveal = { [weak self] rect, web in self?.recordReveal(rect, in: web) }
        cursor.onPresence = { [weak self] working in self?.overlay.setMascotHidden(working) }
        cursor.homeProvider = { [weak self] in self?.homePoint() }
        overlay.onOpenPage = { [weak self] source in self?.hooks.openAnswerPage("Réponse de Luciole", Markdown.page(title: "Réponse de Luciole", source: source)) }
        widthConstraint = panel.widthAnchor.constraint(equalToConstant: CGFloat(width))
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: top), panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), widthConstraint,
        ])
        panel.onSubmit = { [weak self] text in self?.ask(text) }
        panel.onStop = { [weak self] in self?.stop() }
        panel.onModelAction = { [weak self] action in self?.modelAction(action) }
        panel.onClose = { [weak self] in self?.close() }
        panel.onNewChat = { [weak self] in self?.newConversation() }
        panel.onHistory = { [weak self] anchor in self?.showHistory(from: anchor) }
        panel.onToggleShare = { [weak self] in self?.shareContext.toggle(); self?.refresh() }
        panel.onConfirm = { [weak self] ok in self?.resolveConfirm(ok) }
        panel.onAnswer = { [weak self] text in self?.resolveQuestion(text) }
        panel.onCopy = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        panel.onOpenPage = { [weak self] source in self?.hooks.openAnswerPage("Réponse de Luciole", Markdown.page(title: "Réponse de Luciole", source: source)) }
        panel.onOpenSource = { [weak self] url in
            guard let self else { return }
            self.inheritFrom = self.currentTab
            self.hooks.openTab(url)
            self.inheritFrom = nil
        }
        panel.onRefresh = { [weak self] in self?.refresh() }
        panel.currentWidth = { [weak self] in CGFloat(self?.width ?? 380) }
        panel.onResize = { [weak self] wanted in self?.resize(to: Double(wanted)) }
        panel.onResizeEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.width, forKey: Self.widthKey)
        }
        // Les notifications de la fenêtre arrivent sur le fil principal ; on ne passe pas `Notification` (non Sendable) au code isolé.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dock() }
        }
    }

    var view: NSView { panel }
    var isOpen: Bool { overlayOpen || !panel.isHidden }

    private var availability: AIAvailability {
        #if DEBUG
        // Dev (debug seulement) : `HB_AI_FAKE_STATE` montre un état sans le provoquer, `HB_AI_SCRIPTED` répond avec des textes écrits à l'avance (sans fournisseur).
        switch ProcessInfo.processInfo.environment["HB_AI_FAKE_STATE"] {
        case "connecting": return .connecting
        case "unreachable": return .unreachable
        default: break
        }
        if ProcessInfo.processInfo.environment["HB_AI_SCRIPTED"] != nil { return .ready }
        #endif
        if provider == .lmstudio {
            switch lmStudio.reachable { case nil: return .connecting; case false?: return .unreachable; case true?: return lmStudio.models.isEmpty ? .unreachable : .ready }
        }
        return cloudKeyPresent ? .ready : .unreachable
    }
    private var isRunning: Bool { agentTask != nil }
    private var messages: [AIMessage] {
        get { currentTab.flatMap { conversations[$0] } ?? [] }
        set { if let id = currentTab { conversations[id] = newValue } }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        cloudKeys = Self.presentKeys()
        if inPage {
            if restShown { restShown = false; restBubbleText = nil; pathClear?.cancel(); reveals = [] }
            overlayOpen = true
            onRestPose?(nil)
            onVisibilityChange?(true)
            overlay.present(from: hooks.assistantFrame())
            refresh()
            overlay.focusComposer()
            Task { await prepare() }
            return
        }
        panel.isHidden = false
        onVisibilityChange?(true)
        dock()
        panel.focus()
        refresh()
        Task { await prepare() }
    }

    func close() {
        if overlayOpen {
            overlayOpen = false
            endAnchor(); pathClear?.cancel(); reveals = []; restShown = false; restBubbleText = nil; dim.hide()
            let button = hooks.assistantFrame()
            overlay.flyMascotHome(to: button)                       // elle repart vers la barre d'outils avec la même courbe qu'à l'arrivée
            overlay.dismiss()
            if panelFallback { panelFallback = false; panel.isHidden = true; hooks.onLayout(0) }
            onVisibilityChange?(false)
            if Motion.reduced || button == nil { onRestPose?(.sleep) } else { Task { [weak self] in try? await Task.sleep(for: .seconds(0.6)); if self?.overlayOpen == false { self?.onRestPose?(.sleep) } } }
            if isRunning { stop() }
            return
        }
        panel.isHidden = true
        onVisibilityChange?(false)
        hooks.onLayout(0)
        panel.window?.makeFirstResponder(nil)
        if isRunning { stop() }
    }

    /// Le panneau pousse la page si la fenêtre est assez large ; sinon il la recouvre.
    private func dock() {
        guard isOpen, !(overlayOpen && !panelFallback) else { return }
        let windowWidth = hooks.windowWidth()
        let pushes = AIPanelMetrics.pushesPage(windowWidth: Double(windowWidth))
        panel.setOverlay(!pushes)
        widthConstraint.constant = pushes ? CGFloat(width) : min(CGFloat(width), windowWidth * 0.86)      // par-dessus la page : au plus 86 % de la fenêtre
        hooks.onLayout(pushes ? widthConstraint.constant : 0)
    }

    private func resize(to wanted: Double) {
        width = AIPanelMetrics.clamp(wanted)
        dock()
    }

    // MARK: Onglets

    /// L'onglet actif a changé : sa conversation revient. Le titre sert à la puce de contexte.
    func tabChanged(id: UUID?, title: String?) {
        if currentTab != id { failure = nil }                                    // une erreur d'un autre onglet ne s'affiche pas ici
        if let id, let source = inheritFrom, source != id, conversations[id] == nil { conversations[id] = conversations[source] }
        currentTab = id
        currentTitle = title ?? ""
        if passage != nil || !anchoredDoc.isEmpty { passage = nil; overlay.hideFan(); endAnchor(); if !overlayOpen { onRestPose?(.sleep) } }          // le passage appartient à la page d'avant
        refresh()
    }
    func tabClosed(_ id: UUID) { conversations[id] = nil }

    func newConversation() {
        if isRunning { stop() }
        if let tab = currentTab { discussionIDs[tab] = nil }       // l'ancienne reste dans l'historique
        messages = []
        failure = nil
        refresh()
        panel.focus()
    }

    // MARK: Sélection (Luciole dans la page)

    private struct Passage { var text: String; var docRects: [CGRect] }
    private var passage: Passage?
    private var anchoredDoc: [CGRect] = []          // le passage de la réponse en cours, dans le repère du document (px CSS) : il suit le défilement
    private var scroll = CGPoint.zero
    #if DEBUG
    private var debugSelection = ""
    #endif

    /// Ce que le script de lecture voit : une sélection (rectangles en px CSS de la fenêtre d'affichage), sa disparition, ou le défilement.
    func selectionMessage(tab: Tab, json: String) {
        guard inPage, tab.id == currentTab, let web = hooks.activeWebView(),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let type = object["type"] as? String else { return }
        if let view = object["view"] as? [String: Any] { scroll = CGPoint(x: (view["sx"] as? Double) ?? 0, y: (view["sy"] as? Double) ?? 0) }
        if !reveals.isEmpty { refresh() }                                                                    // le chemin et le trou de la validation suivent aussi
        if !anchoredDoc.isEmpty { overlay.setAnchor(overlayRects(fromDoc: anchoredDoc, in: web)) }         // défilement, zoom, redimensionnement : le surlignage et le fil suivent
        switch type {
        case "clear":
            passage = nil
            overlay.hideFan()
            if !overlayOpen, !restShown { onRestPose?(.sleep) }
        case "sel":
            guard !pageIsProtected, !isRunning, !overlayOpen, let rects = object["rects"] as? [[String: Double]], !rects.isEmpty else { return }
            let doc = rects.map { CGRect(x: ($0["x"] ?? 0) + scroll.x, y: ($0["y"] ?? 0) + scroll.y, width: $0["w"] ?? 0, height: $0["h"] ?? 0) }
            let text = (object["text"] as? String) ?? passage?.text
            guard let text, SelectionPassage.isWorthOffering(text) else { return }
            passage = Passage(text: text, docRects: doc)
            #if DEBUG
            debugSelection = "web=\(web.frame.integral) flipped=\(web.isFlipped) inOverlay=\(overlay.convert(web.bounds, from: web).integral) rect0=\(rects[0]) scroll=\(scroll) zoom=\(web.pageZoom) overlayFlipped=\(overlay.isFlipped) overlayFrame=\(overlay.frame.integral) overlayBounds=\(overlay.bounds.integral) sup=\(overlay.superview.map { "\($0.frame.integral) flipped=\($0.isFlipped)" } ?? "-") overlayInWin=\(overlay.convert(overlay.bounds, to: nil).integral) webInWin=\(web.convert(web.bounds, to: nil).integral) winH=\(web.window?.contentView?.bounds.height ?? 0)"
            #endif
            guard !overlayOpen, SettingsStore.shared.lucioleSelectionFan, let last = overlayRects(fromDoc: [doc.last!], in: web).first else { return }
            overlay.showFan(tip: CGPoint(x: last.maxX, y: last.midY), from: hooks.assistantFrame())
            onRestPose?(nil)
        default: break
        }
    }

    /// Le geste vient du clic droit : on demande au script de lecture la sélection et ses rectangles, puis la suite est la même qu'avec l'éventail.
    func gestureFromMenu(_ gesture: SelectionPassage.Gesture) {
        guard inPage, !pageIsProtected, let web = hooks.activeWebView(), !isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let call = LucioleSelectionScript.readCall
            guard let json = await web.safeCall(call.body, arguments: call.arguments, world: LucioleSelectionScript.world) as? String,
                  let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let text = object["text"] as? String,
                  let rects = object["rects"] as? [[String: Double]], !rects.isEmpty else { return }
            if let view = object["view"] as? [String: Any] { self.scroll = CGPoint(x: (view["sx"] as? Double) ?? 0, y: (view["sy"] as? Double) ?? 0) }
            let doc = rects.map { CGRect(x: ($0["x"] ?? 0) + self.scroll.x, y: ($0["y"] ?? 0) + self.scroll.y, width: $0["w"] ?? 0, height: $0["h"] ?? 0) }
            self.passage = Passage(text: text, docRects: doc)
            if let last = self.overlayRects(fromDoc: [doc.last!], in: web).first { self.overlay.setFanTipForMenu(CGPoint(x: last.maxX, y: last.midY), from: self.hooks.assistantFrame()) }
            self.gesture(gesture)
        }
    }

    private func overlayRects(fromDoc rects: [CGRect], in web: WKWebView) -> [CGRect] {
        overlay.prepareGeometry()
        let zoom = max(web.pageZoom, 0.1)
        // Par les coordonnées de la fenêtre : AppKit gère ainsi les vues retournées (la page) et celles qui ne le sont pas (leur parent).
        return rects.map { r in
            let inWeb = NSRect(x: (r.minX - scroll.x) * zoom, y: web.isFlipped ? (r.minY - scroll.y) * zoom : web.bounds.height - (r.maxY - scroll.y) * zoom, width: r.width * zoom, height: r.height * zoom)
            return overlay.convert(web.convert(inWeb, to: nil), from: nil)
        }
    }

    /// Expliquer et Traduire ouvrent une bulle ancrée au passage (sans capsule) et posent la question ; Garder met la page, avec un lien vers le passage, dans la liste de lecture.
    private func gesture(_ gesture: SelectionPassage.Gesture) {
        guard let passage, let web = hooks.activeWebView() else { return }
        overlay.hideFan()
        guard let prompt = gesture.prompt(for: passage.text) else { hooks.keepPassage(passage.text); onRestPose?(.happy); restPoseLater(); return }
        anchoredDoc = passage.docRects
        cloudKeys = Self.presentKeys()
        overlayOpen = true
        onRestPose?(nil)
        onVisibilityChange?(true)
        overlay.presentAnswerOnly()
        overlay.setAnchor(overlayRects(fromDoc: anchoredDoc, in: web))
        let track = LucioleSelectionScript.trackCall(true)
        Task { _ = await web.safeCall(track.body, arguments: track.arguments, world: LucioleSelectionScript.world) }
        refresh()
        ask(prompt)
        Task { await prepare() }
    }

    private func endAnchor() {
        guard !anchoredDoc.isEmpty else { return }
        anchoredDoc = []
        if let web = hooks.activeWebView() { let off = LucioleSelectionScript.trackCall(false); Task { _ = await web.safeCall(off.body, arguments: off.arguments, world: LucioleSelectionScript.world) } }
    }

    // MARK: Fournisseur

    /// À l'ouverture : LM Studio est sondé (il tourne sur ce Mac) ; un fournisseur en nuage n'a rien à préparer.
    private func prepare() async {
        if provider == .lmstudio { await probeLMStudio() } else { refresh() }
    }

    struct AgentFailure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    // MARK: Questions

    func ask(_ text: String) {
        cloudKeys = Self.presentKeys()
        guard availability.canAsk, !isRunning else { return }
        if currentTab == nil { currentTab = UUID() }      // aucune page ouverte (ou essai) : une conversation quand même
        let tab = currentTab!
        runTab = tab
        pathClear?.cancel(); reveals = []
        if overlayOpen, let web = hooks.activeWebView() { let track = LucioleSelectionScript.trackCall(true); Task { _ = await web.safeCall(track.body, arguments: track.arguments, world: LucioleSelectionScript.world) } }       // le défilement est connu avant le premier geste
        let run = UUID()
        runID = run
        failure = nil
        pendingFacts = []
        let context = messages.suffix(6).map { ($0.role == .user ? "Vous : " : "Luciole : ") + String($0.text.prefix(240)) }
        messages += [AIMessage(role: .user, text: text), AIMessage(role: .assistant, text: "", title: String(text.prefix(38)) + (text.count > 38 ? "…" : ""))]
        panel.clearComposer()
        currentTask = text
        eventPose = .think
        // « reprends » (ou la même question) après une erreur du fournisseur : la tâche repart de son état, ce qui est fait n'est pas refait.
        let resuming: AgentLoop? = {
            guard let resumable, resumable.loop.canResume else { return nil }
            let again = Self.isResumeRequest(text) || AIRouter.fold(text) == AIRouter.fold(resumable.task)
            return again ? resumable.loop : nil
        }()
        if resuming != nil { currentTask = resumable?.task ?? text } else { resumable = nil }
        let usageBefore = AIUsageMeter.shared.snapshot, startedAt = Date()
        agentTask = Task { [weak self] in
            guard let self else { return }
            let loop = resuming ?? AgentLoop(environment: self)
            let outcome: AgentOutcome
            if resuming != nil { outcome = await loop.resume() } else {
                let recalled = self.memoryOn ? self.memory.recall(host: self.hooks.activeWebView()?.url?.host, limit: 4) : []
                outcome = await loop.run(task: text, context: context, memory: recalled)
            }
            self.resumable = loop.canResume ? (loop, self.currentTask) : nil
            if !self.hooks.isPrivate(), case .cancelled = outcome.reason {} else if !self.hooks.isPrivate() {
                var used = AIUsageMeter.Snapshot(), now = AIUsageMeter.shared.snapshot
                used.requests = now.requests - usageBefore.requests; used.retries = now.retries - usageBefore.retries
                used.promptTokens = now.promptTokens - usageBefore.promptTokens; used.completionTokens = now.completionTokens - usageBefore.completionTokens
                used.searches = now.searches - usageBefore.searches
                self.onTaskFinished?(loop.route?.rawValue ?? "direct", Int(Date().timeIntervalSince(startedAt) * 1000), outcome.reason == .done, used)
            }
            if self.runID == run { self.finish(outcome, in: tab) }
        }
        refresh()
    }

    /// « reprends », « continue », « réessaie » : la demande de reprendre la tâche arrêtée.
    private static func isResumeRequest(_ text: String) -> Bool {
        let words = AIRouter.fold(text).split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.count <= 3 && !Set(words).isDisjoint(with: ["reprends", "reprendre", "continue", "continuer", "reessaie", "reessayer", "retente"])
    }

    private func finish(_ outcome: AgentOutcome, in tab: UUID) {
        var list = conversations[tab] ?? []
        if var last = list.last, last.role == .assistant {
            switch outcome.reason {
            case .done: last.text = outcome.answer
            case .stepCap, .stalled: last.text = outcome.answer; last.capped = true
            case .cancelled: if last.text.isEmpty { last.text = Self.stoppedText(steps: last.trace.count) }
            case .failed(let message):
                failure = message
                if last.text.isEmpty { last.text = resumable != nil ? "Je n'ai pas pu terminer. Écrivez « reprends » : je repars de là où j'en étais, sans refaire ce qui est fait." : "Je n'ai pas pu terminer." }
            }
            last.sources = outcome.sources
            last.thinking = ""
            list[list.count - 1] = last
            conversations[tab] = list
        }
        remember(outcome, in: tab)
        agentTask = nil
        runTab = nil
        pending = nil
        cursor.settle(failed: { if case .failed = outcome.reason { return true }; return false }())
        refresh()
    }

    /// « Arrêté à l'étape 3. Rien n'a été envoyé ; ce qui est déjà saisi reste dans la page. »
    private static func stoppedText(steps: Int) -> String {
        steps == 0 ? "Arrêté." : "Arrêté à l'étape \(steps). Rien n'a été envoyé ; ce qui est déjà saisi reste dans la page."
    }

    func stop() {
        guard agentTask != nil else { return }
        agentTask?.cancel()
        cursor.hideNow()
        agentTask = nil                    // l'écran est libre tout de suite ; la tâche arrêtée finit en silence (son résultat est ignoré)
        runID = UUID()
        if let tab = runTab, var list = conversations[tab], var last = list.last, last.role == .assistant {
            if last.text.isEmpty { last.text = Self.stoppedText(steps: last.trace.count) }
            if !last.trace.isEmpty { last.stoppedAtStep = last.trace.count }
            list[list.count - 1] = last
            conversations[tab] = list
        }
        runTab = nil
        resolveConfirm(false)
        resolveQuestion(nil)
    }

    private func resolveConfirm(_ ok: Bool) {
        guard let c = confirmContinuation else { return }
        confirmContinuation = nil; pending = nil
        c.resume(returning: ok)
        refresh()
    }

    private func resolveQuestion(_ text: String?) {
        guard let c = questionContinuation else { return }
        questionContinuation = nil; pending = nil
        c.resume(returning: text)
        refresh()
    }

    /// Modifie le texte de la réponse en cours, dans la conversation de l'onglet où la tâche a démarré.
    private func mutateAnswer(_ change: (inout String) -> Void) {
        guard let tab = runTab, var list = conversations[tab], list.last?.role == .assistant else { return }
        change(&list[list.count - 1].text)
        conversations[tab] = list
    }

    private func setThinking(_ text: String) {
        guard let tab = runTab, var list = conversations[tab], list.last?.role == .assistant else { return }
        list[list.count - 1].thinking = text
        conversations[tab] = list
    }

    private func setTrace(_ items: [AgentTraceItem]) {
        guard let tab = runTab, var list = conversations[tab], !list.isEmpty else { return }
        list[list.count - 1].trace = items
        conversations[tab] = list
        refresh()
    }

    // MARK: Mémoire

    private func stored(_ list: [AIMessage]) -> [LucioleMemory.Message] {
        list.map { m in
            LucioleMemory.Message(isUser: m.role == .user, text: m.text, title: m.title, sources: m.sources,
                                  trace: m.trace.map { .init(text: $0.text, detail: $0.detail, failed: $0.state == .failed) }, capped: m.capped, stoppedAtStep: m.stoppedAtStep)
        }
    }

    private func restored(_ list: [LucioleMemory.Message]) -> [AIMessage] {
        list.enumerated().map { index, m in
            AIMessage(role: m.isUser ? .user : .assistant, text: m.text,
                      trace: m.trace.enumerated().map { AgentTraceItem(id: $0.offset + 1, text: $0.element.text, detail: $0.element.detail, state: $0.element.failed ? .failed : .done) },
                      sources: m.sources, title: m.title, stoppedAtStep: m.stoppedAtStep, capped: m.capped)
        }
    }

    /// Après chaque tâche : la discussion est enregistrée (pour la rouvrir) et le journal retient ce qui a été fait (pour s'en souvenir). Sans valeurs saisies.
    private func remember(_ outcome: AgentOutcome, in tab: UUID) {
        guard memoryOn, let list = conversations[tab], let last = list.last, last.role == .assistant, let task = list.dropLast().last(where: { $0.role == .user }) else { return }
        let host = hooks.activeWebView()?.url?.host
        let id = discussionIDs[tab] ?? UUID()
        discussionIDs[tab] = id
        let first = list.first(where: { $0.role == .user })?.text ?? task.text
        memory.upsert(.init(id: id, title: LucioleMemory.title(for: first), host: host, updatedAt: Date(), messages: stored(list)))
        let actions = last.trace.map { ($0.detail ?? $0.text) + ($0.state == .failed ? " (échec)" : "") }
        if !actions.isEmpty || !pendingFacts.isEmpty || !last.text.isEmpty {
            memory.record(.init(date: Date(), host: host, task: task.text, actions: actions, answer: outcome.reason == .done ? last.text : "", facts: pendingFacts))
        }
        pendingFacts = []
        let snapshot = memory
        Self.saveQueue.async { snapshot.save() }          // une seule file : les copies s'écrivent dans l'ordre
    }

    /// Le bouton « Discussions précédentes » : un menu des dernières discussions ; en choisir une la rouvre dans cet onglet.
    private func showHistory(from anchor: NSView) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Discussions précédentes", action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        if memory.discussions.isEmpty {
            let none = NSMenuItem(title: SettingsStore.shared.lucioleMemoryEnabled ? "Aucune pour l'instant" : "La mémoire est coupée (Réglages › Assistant IA)", action: nil, keyEquivalent: ""); none.isEnabled = false
            menu.addItem(none)
        }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "fr_FR"); formatter.unitsStyle = .short
        for discussion in memory.discussions.prefix(15) {
            let when = formatter.localizedString(for: discussion.updatedAt, relativeTo: Date())
            let item = ClosureMenuItem(title: discussion.title + (discussion.host.map { " — \($0)" } ?? "") + "  ·  " + when) { [weak self] in self?.open(discussion) }
            menu.addItem(item)
        }
        if !memory.discussions.isEmpty || !memory.journal.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Effacer la mémoire de Luciole…") { [weak self] in self?.confirmErase() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func open(_ discussion: LucioleMemory.Discussion) {
        if isRunning { stop() }
        if currentTab == nil { currentTab = UUID() }
        messages = restored(discussion.messages)
        if let tab = currentTab { discussionIDs[tab] = discussion.id }
        failure = nil
        refresh()
        panel.focus()
    }

    private func confirmErase() {
        let alert = NSAlert()
        alert.messageText = "Effacer la mémoire de Luciole ?"
        alert.informativeText = "Toutes les discussions enregistrées et le journal de ses actions seront supprimés de ce Mac. La discussion ouverte reste affichée."
        alert.addButton(withTitle: "Effacer"); alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        memory.clear(); LucioleMemory.erase(); discussionIDs = [:]
    }

    // MARK: Modèle

    private func modelAction(_ action: AIPanelView.ModelAction) {
        switch action {
        case .later, .cancelDownload, .deleteReceived, .download, .resume: close()
        case .retry: failure = nil; lmStudio = (nil, []); refresh(); Task { await prepare() }
        }
    }

    // MARK: Affichage

    private var pageIsReadable: Bool {
        guard let url = hooks.activeWebView()?.url else { return false }
        return !ActionPolicy.isForbiddenPage(url)
    }

    /// « 1,3 Go », « 640 Mo ».
    private func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f Go", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",") : "\(Int((Double(bytes) / 1e6).rounded())) Mo"
    }

    /// Une page qu'Orée garde hors de portée de l'IA (ni http(s), ni la page de démarrage) : le panneau passe en lecture seule.
    private var pageIsProtected: Bool {
        guard let url = hooks.activeWebView()?.url, let scheme = url.scheme?.lowercased() else { return false }
        return !["http", "https", "oree", "about"].contains(scheme)
    }

    private func modelScreen(_ state: AIAvailability) -> AIPanelView.ModelScreen? {
        if provider == .lmstudio, lmStudio.reachable == false || lmStudio.models.isEmpty, lmStudio.reachable != nil {
            let base = SettingsStore.shared.lmStudioBase.absoluteString
            return lmStudio.reachable == true
                ? .init(title: "Aucun modèle chargé dans LM Studio.", text: "Le serveur répond, mais il ne propose aucun modèle de conversation. Chargez-en un dans LM Studio, puis réessayez.", primary: ("Réessayer", .retry))
                : .init(title: "LM Studio n'est pas joignable.", text: "Lancez LM Studio, chargez un modèle et démarrez le serveur local (onglet Developer › Start Server). Adresse essayée : \(base). Erreur : \(lmStudioError.isEmpty ? "aucune réponse" : lmStudioError). Si LM Studio est sur une autre machine : Réglages Système › Confidentialité et sécurité › Réseau local › activez Orée. Le reste d'Orée fonctionne normalement.", primary: ("Réessayer", .retry))
        }
        if provider.isCloud, !cloudKeyPresent {
            return .init(title: "Ajoutez votre clé \(provider.displayName).", text: "Réglages › Assistant IA › \(provider.displayName) : collez votre clé API. Elle reste dans le Trousseau de ce Mac.")
        }
        if pageIsProtected, messages.isEmpty {
            return .init(title: "Je détourne les yeux.", text: "Les réglages d'Orée, les paiements et les mots de passe restent hors de portée de l'IA. Sur un autre onglet, je reprends là où nous en étions.")
        }
        switch state {
        case .ready: return nil
        case .connecting: return .init(title: "Luciole se réveille.", text: "Un instant.", indeterminate: true)
        case .unreachable:
            return .init(title: "Luciole n'est pas joignable pour l'instant.", text: "Vérifiez votre connexion, puis réessayez. Le reste d'Orée fonctionne normalement.", primary: ("Réessayer", .retry))
        }
    }

    private func refresh() {
        let state = availability
        let list = messages
        let running = isRunning && runTab == currentTab
        let streaming = running && !(list.last?.text.isEmpty ?? true)
        let hasPending = pending != nil && runTab == currentTab
        let model = modelScreen(state)
        var pose: LucioleState
        if pageIsProtected { pose = .off }
        else if hasPending { pose = pending.map { if case .question = $0.kind { .ask } else { .wait } } ?? .wait }
        else if rateLimitWait != nil, running { pose = .wait }                                                                     // le fournisseur fait patienter : Luciole attend, elle ne paraît pas bloquée
        else if let moment = eventPose, running || moment == .happy || moment == .err { pose = moment }       // ce que la tâche fait vraiment, d'après ses événements
        else { pose = LucioleState.pose(availability: state, running: running, streaming: streaming, failed: failure != nil) }
        if provider.isCloud, !cloudKeyPresent { pose = .sleep }

        // Puce d'état
        var chipText = "Prêt", dot = AIPanelView.Dot.accent
        switch state {
        case .connecting: chipText = "Réveil"
        case .unreachable where provider.isCloud: chipText = "Clé manquante"; dot = .outline
        case .unreachable: chipText = "Indisponible"; dot = .muted
        case .ready:
            if failure != nil { chipText = "Erreur"; dot = .alert }
            else if hasPending { chipText = "Attend votre accord" }
            else if let wait = rateLimitWait { chipText = "Limite de débit · \(wait) s"; dot = .outline }
            else if running { chipText = "Au travail" }
            else { chipText = provider.displayName }
        }

        // Puce de contexte
        let url = hooks.activeWebView()?.url
        let host = url?.host
        var contextText = "Lit : " + (currentTitle.isEmpty ? (host ?? "cette page") : currentTitle)
        var locked = false
        if pageIsProtected { contextText = "Page protégée · Luciole ne lit pas"; locked = true }
        else if host == nil { contextText = "Aucune page à lire"; locked = true }
        else if !shareContext { contextText = "Ne lit pas cette page" }

        // Corps
        let canRead = shareContext && !locked
        let mode: AIPanelView.Mode
        if let model { mode = .model(model) }
        else if list.isEmpty {
            let suggestions: [(symbol: String, label: String, fill: String, web: Bool)] = canRead
                ? [("text.alignleft", "Résumer cette page", "Résume cette page.", false), ("globe", "Chercher sur le web…", "Cherche sur le web : ", true), ("magnifyingglass", "Quels sont les points clés ?", "Quels sont les points clés de cette page ?", false)]
                : [("globe", "Chercher sur le web…", "Cherche sur le web : ", true), ("text.alignleft", "Expliquer un mot ou une idée", "Explique-moi simplement : ", false), ("pencil", "Écrire un court e-mail", "Écris un court e-mail pour ", false)]
            mode = .empty(title: "Bonjour, je suis Luciole.", text: "Je lis la page ouverte, je cherche sur le web et je peux remplir un formulaire à votre place. Avant tout envoi, je vous montre ce qui part.", suggestions: suggestions)
        } else { mode = .conversation }

        // Composeur
        let placeholder: String
        if pageIsProtected { placeholder = "Indisponible sur cette page protégée" }
        else if hasPending { placeholder = "Validez ou annulez d'abord" }
        else if running { placeholder = "Luciole travaille… Arrêter reste possible" }
        else if !state.canAsk { placeholder = "Luciole n'est pas encore prête" }
        else { placeholder = "Demandez à Luciole…" }
        panel.show(.init(
            pose: pose, chipText: chipText, chipDot: dot, contextText: contextText, contextLetter: host, contextShared: shareContext, contextLocked: locked,
            mode: mode, placeholder: placeholder, composerEnabled: state.canAsk && !pageIsProtected && !hasPending, running: running, showsStop: !(pending.map { if case .confirm = $0.kind { true } else { false } } ?? false),
            note: provider == .lmstudio ? (LMStudio.isLoopback(SettingsStore.shared.lmStudioBase) ? "LM Studio : tout reste sur ce Mac · Luciole peut se tromper" : "LM Studio (réseau) : les pages lues sont envoyées à \(SettingsStore.shared.lmStudioBase.host ?? "ce serveur") · Luciole peut se tromper") : provider.isCloud ? "\(provider.displayName) (nuage) : les pages lues lui sont envoyées · Luciole peut se tromper" : "Tout reste sur ce Mac · Luciole peut se tromper"))
        panel.setTranscript(list, writing: running, pending: hasPending ? pending : nil)
        if overlayOpen || restShown { updateOverlay(state: state, pose: pose, mode: mode, model: model, running: running, hasPending: hasPending, host: host, locked: locked) }
        if let p = pending, !p.armed {            // « Valider » devient actif après 1,2 s : on redessine à ce moment-là
            Task { try? await Task.sleep(for: .milliseconds(1250)); self.refresh() }
        }
    }

    /// La couche dans la page. Une validation, une question ou un état du modèle (à installer, téléchargement, erreur) ouvrent le panneau latéral en renfort.
    private func updateOverlay(state: AIAvailability, pose: LucioleState, mode: AIPanelView.Mode, model: AIPanelView.ModelScreen?, running: Bool, hasPending: Bool, host: String?, locked: Bool) {
        if panelFallback { panelFallback = false; panel.isHidden = true; hooks.onLayout(0) }          // l'ancien renfort : plus utilisé, l'état du modèle s'affiche dans la page
        modelPrimaryAction = model?.primary?.action
        var suggestions: [(symbol: String, label: String, fill: String, web: Bool)] = []
        if case .empty(_, _, let list) = mode { suggestions = list }
        let last = messages.last(where: { $0.role == .assistant })
        let canRead = shareContext && !locked
        let acted = last?.trace.contains { !$0.text.hasPrefix("Recherche") && !$0.text.hasPrefix("Lecture") && !$0.text.hasPrefix("Question") } ?? false
        var confirm: ConfirmRequest?, question: String?
        if let p = pending, runTab == currentTab { switch p.kind { case .confirm(let request): confirm = request; case .question(let q): question = q } }
        let stage = LucioleStage.stage(for: .init(isOpen: true, pageProtected: pageIsProtected, running: running, actingOnPage: acted, pendingConfirm: confirm != nil, pendingQuestion: question != nil,
                                                  hasAnswer: !(last?.text.isEmpty ?? true)))
        let note = provider == .lmstudio ? (LMStudio.isLoopback(SettingsStore.shared.lmStudioBase) ? "Sur ce Mac · Luciole peut se tromper" : "LM Studio (réseau) · Luciole peut se tromper")
            : provider.isCloud ? "\(provider.displayName) · Luciole peut se tromper" : "Sur ce Mac · Luciole peut se tromper"
        // Le voile (validation) et le chemin vivent dans le repère de la page.
        attachCursor(); attachDim()
        let web = hooks.activeWebView()
        let target = reveals.last.flatMap { reveal in web.map { overlayRects(fromDoc: [reveal.doc], in: $0).first } ?? nil }
        if confirm != nil, let web, let last = reveals.last { dim.show(hole: dimRect(fromDoc: last.doc, in: web)) } else if confirm != nil { dim.show(hole: nil) } else { dim.hide() }
        let path: [(step: Int, rect: CGRect)] = web.map { web in reveals.map { (step: $0.step, rect: overlayRects(fromDoc: [$0.doc], in: web).first ?? .zero) } } ?? []
        let modelScreenForOverlay = model
        var model = LucioleOverlayModel(
            stage: stage, pose: pose, placeholder: pageIsProtected ? "Indisponible sur cette page protégée" : (running ? "Luciole travaille… Échap pour arrêter" : "Demandez à Luciole…"),
            composerEnabled: state.canAsk && !pageIsProtected && !hasPending, running: running, suggestions: suggestions,
            answer: last?.text ?? "", sources: last?.sources ?? [], note: note, hasConversation: !messages.isEmpty, contextShared: canRead, contextLocked: locked,
            protectedLine: pageIsProtected ? "Je détourne les yeux : les réglages d'Orée, les paiements et les mots de passe restent hors de portée de Luciole." : nil)
        model.confirm = confirm; model.confirmArmed = pending?.armed ?? true; model.question = question; model.decisionRect = target
        if acted, running { model.actionTitle = last?.title ?? "Luciole travaille"; model.actionStep = last?.trace.count ?? 0; model.actionLines = last?.trace.map(\.text) ?? [] }
        model.path = path
        if let screen = modelScreenForOverlay { model.modelTitle = screen.title; model.modelText = screen.text; model.modelPrimary = screen.primary?.title }
        if restShown { model.rest = true; model.restBubble = restBubbleText; model.stage = .rest; model.actionTitle = nil }
        overlay.apply(model)
    }

    // MARK: Chemin et validation dans la page

    /// Un élément vient d'être visé (px CSS de la fenêtre d'affichage) : une étape de plus sur le chemin, et la cible d'une éventuelle validation.
    private func recordReveal(_ rect: CGRect, in web: WKWebView) {
        guard overlayOpen else { return }
        let doc = rect.offsetBy(dx: scroll.x, dy: scroll.y)
        let step = messages.last?.trace.count ?? (reveals.count + 1)
        if let previous = reveals.last, previous.doc.equalTo(doc) { reveals[reveals.count - 1].step = step } else { reveals.append((step: step, doc: doc)) }
        if reveals.count > 12 { reveals.removeFirst() }
        pathClear?.cancel()
        let track = LucioleSelectionScript.trackCall(true)
        Task { _ = await web.safeCall(track.body, arguments: track.arguments, world: LucioleSelectionScript.world) }
        refresh()
    }

    /// Là où Luciole était avant de partir travailler dans la page (et où elle revient) : sa mascotte dans la capsule ou au bout du passage, sinon la barre d'outils.
    private func homePoint() -> CGPoint? {
        guard overlayOpen || restShown else { return nil }
        let window: CGPoint
        if let mascot = overlay.mascotCenterInWindow() { window = mascot }
        else if let button = hooks.assistantFrame() { window = CGPoint(x: button.midX, y: button.midY) }
        else { return nil }
        cursor.layoutSubtreeIfNeeded()
        return cursor.convert(window, from: nil)
    }

    private func attachDim() {
        guard dim.superview == nil, let host = hooks.pageHost() else { return }
        host.addSubview(dim, positioned: .below, relativeTo: cursor.superview === host ? cursor : nil)
        NSLayoutConstraint.activate([dim.topAnchor.constraint(equalTo: host.topAnchor), dim.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     dim.leadingAnchor.constraint(equalTo: host.leadingAnchor), dim.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        host.layoutSubtreeIfNeeded()
    }

    private func dimRect(fromDoc rect: CGRect, in web: WKWebView) -> CGRect {
        dim.superview?.layoutSubtreeIfNeeded()
        let zoom = max(web.pageZoom, 0.1)
        let inWeb = NSRect(x: (rect.minX - scroll.x) * zoom, y: web.isFlipped ? (rect.minY - scroll.y) * zoom : web.bounds.height - (rect.maxY - scroll.y) * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return dim.convert(web.convert(inWeb, to: nil), from: nil)
    }

    /// Après une tâche qui a agi sur la page : un saut de joie, puis Luciole retourne dormir dans la barre d'outils ; une petite bulle de 4 s dit l'essentiel,
    /// et le chemin reste 60 s. La conversation reste là : ⌘J la rouvre. Elle ne parle jamais la première.
    private func retractToRest() {
        guard overlayOpen, pending == nil, !isRunning else { return }
        let last = messages.last(where: { $0.role == .assistant })
        restBubbleText = Self.restLine(from: last?.text ?? "")
        overlayOpen = false; restShown = true
        let button = hooks.assistantFrame()
        overlay.flyMascotHome(to: button)
        overlay.presentRest()
        onVisibilityChange?(false)
        Task { [weak self] in try? await Task.sleep(for: .seconds(Motion.reduced || button == nil ? 0 : 0.65)); if self?.overlayOpen == false { self?.onRestPose?(.happy); self?.restPoseLater() } }
        refresh()
        Task { [weak self] in try? await Task.sleep(for: .seconds(4)); self?.restBubbleText = nil; self?.refresh() }
    }

    private func restPoseLater() { Task { [weak self] in try? await Task.sleep(for: .seconds(2.4)); if self?.overlayOpen == false { self?.onRestPose?(.sleep) } } }

    /// La première phrase de la réponse, sans mise en forme, en 80 caractères au plus (« C'est réservé. », « Rien n'est parti. »).
    static func restLine(from answer: String) -> String {
        let plain = Markdown.plainText(answer).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sentence = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map { String($0) + "." } ?? plain
        let clean = sentence.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "C'est fait." }
        return clean.count > 80 ? String(clean.prefix(79)) + "…" : clean
    }

    /// Le chemin reste visible 60 s après la fin de la tâche, puis s'efface.
    private func schedulePathClear() {
        pathClear?.cancel()
        pathClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            if self.restShown, !self.overlayOpen { self.restShown = false; self.overlay.dismiss() }
            self.reveals = []
            if self.anchoredDoc.isEmpty, let web = self.hooks.activeWebView() { let off = LucioleSelectionScript.trackCall(false); _ = await web.safeCall(off.body, arguments: off.arguments, world: LucioleSelectionScript.world) }
            self.refresh()
        }
    }

    // MARK: Automatisation

    /// Dev : ce que le panneau dit et montre (même format que l'ancienne barre, pour `ai_check.py`).
    var report: String {
        let last = messages.last(where: { $0.role == .assistant })
        let trace = last?.trace.map { "\($0.state):\($0.text)" + ($0.detail.map { " — " + $0 } ?? "") }.joined(separator: " | ") ?? ""
        var prefix = ""
        #if DEBUG
        if overlayOpen || restShown || overlay.fanIsVisible { prefix = "DIM[hidden=\(dim.isHidden) bounds=\(dim.bounds.integral) super=\(dim.superview.map { String(describing: type(of: $0)) } ?? "-")] OVERLAY[\(overlay.report)] panelFallback=\(panelFallback) SEL[\(debugSelection)] rest=\(restShown) restBubble=\(restBubbleText ?? "-") " }
        #endif
        return prefix + "open=\(isOpen) state=\(availability) running=\(isRunning) width=\(Int(width)) pose=\(panel.mascot.state.rawValue) wait=\(rateLimitWait.map(String.init) ?? "-") pending=\(pending.map { "\($0.kind)" } ?? "none") cursor=[\(cursor.report)] think=\(last?.thinking.count ?? 0) trace=[\(trace)] line=\(failure ?? "")| answer=\((last?.text ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))"
    }

    #if DEBUG
    /// Dev (debug seulement) : comme une touche E, T ou G pendant que l'éventail est visible.
    func devGesture(_ name: String) { if let g = SelectionPassage.Gesture(rawValue: name) { gesture(g) } }

    /// Dev (debug seulement) : le voile de la validation seul, en PNG transparent.
    func devDimShot(to path: String) -> String {
        dim.layoutSubtreeIfNeeded()
        guard let rep = dim.bitmapImageRepForCachingDisplay(in: dim.bounds) else { return "no rep" }
        dim.cacheDisplay(in: dim.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "no png" }
        try? png.write(to: URL(fileURLWithPath: path)); return path
    }

    /// Dev (debug seulement) : la couche seule en PNG transparent (le verre n'y est pas rendu : seuls les contenus le sont).
    func devOverlayShot(to path: String) -> String {
        overlay.layoutSubtreeIfNeeded()
        guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return "no rep" }
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "no png" }
        try? png.write(to: URL(fileURLWithPath: path)); return path
    }

    /// Dev (debug seulement) : comme un clic sur une source du panneau.
    func devOpenSource(_ url: URL) { panel.onOpenSource?(url) }

    /// Dev (debug seulement) : les treize poses de Luciole à 64 pt, côte à côte, pour les comparer à la fiche de la mascotte.
    static func devLucioleSheet(to path: String) -> String {
        let states = LucioleState.allCases
        let cell: CGFloat = 96, scale: CGFloat = 2
        let width = cell * CGFloat(states.count), height = cell
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(Theme.cg(Theme.chrome, in: NSView()))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (i, state) in states.enumerated() {
            let view = LucioleView(size: 64)
            view.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            view.apply(state)
            view.layoutSubtreeIfNeeded()
            context.saveGState()
            context.translateBy(x: CGFloat(i) * cell + 16, y: 16)
            view.layer?.render(in: context)
            context.restoreGState()
        }
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "no image" }
        try? png.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Dev (debug seulement) : une image fidèle du panneau seul (les captures de fenêtre déforment les vues à fond posé sur le calque).
    func devSnapshot(to path: String) -> String {
        panel.layoutSubtreeIfNeeded()
        let size = panel.bounds.size
        var target: CALayer? = panel.layer
        if let path = try? String(contentsOfFile: "/tmp/oree-panel-which.txt", encoding: .utf8) {
            var view: NSView = panel
            for part in path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
                guard let i = Int(part), view.subviews.indices.contains(i) else { break }
                view = view.subviews[i]
            }
            target = view.layer      // diagnostic : un seul sous-ensemble du panneau (indices de sous-vues séparés par des virgules)
        }
        guard size.width > 0, let layer = target else { return "panel not visible" }
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)       // le calque est en y vers le haut
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return "no image" }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "no png" }
        try? png.write(to: URL(fileURLWithPath: path))
        return "\(path) \(Int(size.width))x\(Int(size.height)) subviews=" + panel.subviews.map { "\(type(of: $0)):\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " ")
    }
    #endif

    /// Dev : répond à la carte « à valider » ou à la question affichées.
    func devResolve(_ text: String) {
        switch pending?.kind {
        case .confirm: resolveConfirm(text == "yes")
        case .question: resolveQuestion(text)
        case nil: break
        }
    }
}

// MARK: - L'environnement de l'agent : le vrai (modèle, page, recherche, confirmation)

extension AIPanelController: AgentEnvironment {
    /// Dev : chaque tour (consigne comprise) dans le fichier `HB_AI_TRACE`, pour lire ce que dit le modèle.
    private static func logTurn(_ request: ModelRequest, _ text: String) {
        guard let path = ProcessInfo.processInfo.environment["HB_AI_TRACE"] else { return }
        let body = request.messages.map { "[\($0.role.rawValue)] " + ($0.calls.isEmpty ? $0.content : $0.calls.map { "\($0.call.name) \($0.call.argumentsJSON)" }.joined(separator: "\n")) }.joined(separator: "\n---\n")
        let entry = "=== REQUÊTE (\(request.messages.count) messages, outils : \(request.tools.joined(separator: ","))), \(PageMap.estimatedTokens(body)) jetons estimés)\n\(body)\n=== RÉPONSE\n\(text)\n\n"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close() }
        else { try? entry.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    #if DEBUG
    /// Dev (build de debug seulement) : des réponses du modèle écrites à l'avance dans /tmp/oree-ai-script.json (liste de textes), pour tester la boucle
    /// et les cartes sans dépendre d'un petit modèle capricieux. Chaque tour en consomme une.
    private static func scriptedReply() -> String? {
        let path = "/tmp/oree-ai-script.json"
        guard var list = (FileManager.default.contents(atPath: path)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String] }), !list.isEmpty else { return nil }
        let first = list.removeFirst()
        try? JSONSerialization.data(withJSONObject: list).write(to: URL(fileURLWithPath: path))
        return first
    }
    #endif

    /// Le texte qui s'écrit : affiché dans la réponse en cours (au plus 10 fois par seconde), sauf si le modèle écrit une ligne JSON (un appel d'outil, pas une réponse).
    private func showPartial(_ text: String, thinking: String) {
        guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("{") else { return }
        mutateAnswer { $0 = text }
        setThinking(text.isEmpty ? thinking : "")
        let now = Date()
        if now.timeIntervalSince(lastPartialRefresh) > 0.1 { lastPartialRefresh = now; refresh() }
    }

    func askModel(_ request: ModelRequest) async throws -> String {
        #if DEBUG
        if let scripted = Self.scriptedReply() { Self.logTurn(request, scripted); return scripted }
        #endif
        guard let model = provider == .lmstudio ? lmModel : SettingsStore.shared.aiModel(for: provider) else { throw AgentFailure(message: "Aucun modèle chargé dans LM Studio.") }
        do {
            mutateAnswer { $0 = "" }                      // un nouveau tour : on repart d'un texte vide
            setThinking("")
            let client = CloudClient(provider: provider, model: model, endpoint: SettingsStore.shared.aiEndpoint(for: provider))
            let text = try await client.complete(request, onText: { [weak self] partial, thinking in
                self?.setRateLimitWait(nil)
                self?.showPartial(partial, thinking: thinking)
            }, onWait: { [weak self] seconds in
                self?.setRateLimitWait(seconds)
            })
            setRateLimitWait(nil)
            Self.logTurn(request, text)
            return text
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as CloudClient.Failure { setRateLimitWait(nil); throw AgentFailure(message: error.message) }
        catch { setRateLimitWait(nil); throw AgentFailure(message: "\(provider.displayName) est injoignable : \(error.localizedDescription)") }
    }

    /// Une attente imposée par le fournisseur : le panneau le dit (« Limite de débit · 6 s ») et Luciole attend, au lieu de paraître bloquée.
    private func setRateLimitWait(_ seconds: Int?) {
        guard rateLimitWait != seconds else { return }
        rateLimitWait = seconds
        refresh()
    }

    var pageReadable: Bool { shareContext && pageIsReadable && hooks.activeWebView() != nil }
    var currentURL: String? { hooks.activeWebView()?.url?.absoluteString }

    /// La page affichée pour le modèle : les passages qui répondent à la question quand elle est longue, plus ses éléments cliquables.
    /// La signature change quand le contenu change vraiment (adresse, texte, éléments), pas à chaque lecture.
    func pageSnapshot(focus: String) async -> PageSnapshot? {
        guard pageReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return nil }
        let text = map.render(maxElements: 40, maxText: 2400, focus: focus)
        return PageSnapshot(text: text, signature: ContentSignature.of(text))
    }

    func event(_ event: AgentEvent) {
        eventPoseReset?.cancel()
        eventPose = LucioleState.pose(for: event)
        if case .waitingForProvider(let seconds) = event { rateLimitWait = seconds } else if case .thinking = event { /* l'attente du fournisseur est gérée par la requête */ }
        attachCursor()
        cursor.follow(eventPose ?? .idle)
        if case .finished(let reason) = event {
            schedulePathClear()
            if reason == .done, overlayOpen, !reveals.isEmpty { Task { [weak self] in try? await Task.sleep(for: .seconds(1.6)); self?.retractToRest() } }
            // La pose de fin (contente, ou en erreur) reste un instant, puis Luciole revient au repos.
            eventPoseReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                self?.eventPose = nil; self?.refresh()
            }
        }
        refresh()
    }

    func perform(_ call: AgentCall) async -> AgentToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "search_web":
            guard let query = args["query"] as? String, !query.isEmpty else { return AgentToolResult(ok: false, text: "Il manque « query ».", summary: "Requête vide") }
            if query.count > 120 {       // une très longue requête peut transporter du texte de la page vers le moteur de recherche
                let request = ConfirmRequest(title: "Lancer cette recherche ?", rows: [(key: "Requête", value: String(query.prefix(200)))], warning: "Je vais envoyer ce texte à un moteur de recherche.", host: "duckduckgo.com")
                guard await confirm(request) else { return AgentToolResult(ok: false, text: "La personne a refusé cette recherche. N'insiste pas : réponds avec done.", summary: "Recherche refusée par vous") }
            }
            return await searchWithCache(query)
        case "open_url":
            guard let string = args["url"] as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return AgentToolResult(ok: false, text: "Adresse refusée : seules les adresses http(s) s'ouvrent.", summary: "Adresse refusée")
            }
            // Une adresse vers un autre site avec des paramètres (ou très longue) peut transporter du texte de la page : on demande d'abord.
            let current = hooks.activeWebView()?.url?.host
            if url.host != current, url.query != nil || string.count > 80 {
                let request = ConfirmRequest(title: "Ouvrir cette adresse ?", rows: [(key: "Site", value: url.host ?? string), (key: "Adresse", value: String(string.prefix(160)))],
                                             warning: "Je vais ouvrir cette adresse dans votre onglet. Elle contient des paramètres : vérifiez qu'elle ne transporte rien de privé.", host: url.host ?? string)
                guard await confirm(request) else { return AgentToolResult(ok: false, text: "La personne a refusé d'ouvrir cette adresse. N'insiste pas : réponds avec done.", summary: "Adresse refusée par vous") }
            }
            let ok = await hooks.navigate(string)
            return AgentToolResult(ok: ok, text: ok ? "Page ouverte : \(hooks.activeWebView()?.title ?? string)" : "La page n'a pas chargé.", summary: ok ? "Ouverture de \(url.host ?? string)" : "Page non chargée", sources: ok ? [string] : [])
        case "read_page":
            AIUsageMeter.shared.record { $0.pageReads += 1 }
            guard pageIsReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return AgentToolResult(ok: false, text: "Aucune page lisible.", summary: "Page non lisible") }
            return AgentToolResult(ok: true, text: map.render(maxElements: 0, maxText: 2400, focus: currentTask), summary: "Lecture de la page")
        case "calculate":
            return AgentLocalTools.calculate(args["expression"] as? String ?? "")
        case "search_history":
            guard !hooks.isPrivate() else { return AgentToolResult(ok: false, text: "L'historique n'est pas consulté depuis un onglet privé.", summary: "Onglet privé") }
            guard let query = args["query"] as? String, !query.isEmpty else { return AgentToolResult(ok: false, text: "Il manque « query ».", summary: "Requête vide") }
            return AgentLocalTools.history(query: query, entries: hooks.searchHistory(query))
        case "add_note":
            guard !hooks.isPrivate() else { return AgentToolResult(ok: false, text: "Aucune note n'est écrite depuis un onglet privé.", summary: "Onglet privé") }
            guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return AgentToolResult(ok: false, text: "Il manque « text ».", summary: "Texte vide") }
            hooks.addNote(text)
            return AgentToolResult(ok: true, text: "Ajouté à la note.", summary: "Ajouté à votre note")
        case "history_nav":
            guard let web = hooks.activeWebView() else { return AgentToolResult(ok: false, text: "Aucune page ouverte.") }
            switch args["direction"] as? String {
            case "back": guard web.canGoBack else { return AgentToolResult(ok: false, text: "Il n'y a pas de page précédente.", summary: "Pas de page précédente") }; web.goBack()
            case "forward": guard web.canGoForward else { return AgentToolResult(ok: false, text: "Il n'y a pas de page suivante.", summary: "Pas de page suivante") }; web.goForward()
            case "reload": web.reload()
            default: return AgentToolResult(ok: false, text: "direction : back, forward ou reload.", summary: "Direction inconnue")
            }
            try? await Task.sleep(for: .seconds(1.2))
            return AgentToolResult(ok: true, text: "Page affichée : \(web.title ?? web.url?.host ?? "chargement")", summary: "Navigation faite")
        case "wait":
            let limit = Date().addingTimeInterval(AgentLocalTools.waitSeconds(args["seconds"]))
            try? await Task.sleep(for: .seconds(0.5))
            while Date() < limit, hooks.activeWebView()?.isLoading == true { try? await Task.sleep(for: .seconds(0.25)) }
            return AgentToolResult(ok: true, text: "J'ai attendu.", summary: "Attente")
        case "ask_user":
            guard let question = args["question"] as? String, !question.isEmpty else { return AgentToolResult(ok: false, text: "Il manque « question ».") }
            guard let answer = await ask(question) else { return AgentToolResult(ok: false, text: "La personne n'a pas répondu.", summary: "Sans réponse") }
            if LucioleMemory.isSafeFact(question: question, answer: answer) { pendingFacts.append("\(question) → \(answer)") }
            return AgentToolResult(ok: true, text: "Réponse de la personne : \(answer)", summary: "Réponse reçue")
        default:
            guard let web = hooks.activeWebView() else { return AgentToolResult(ok: false, text: "Aucune page ouverte.") }
            let action: AIAction
            do { action = try AIAction.parse(name: call.name, argumentsJSON: call.argumentsJSON) }
            catch { return AgentToolResult(ok: false, text: "Arguments invalides pour \(call.name) : \(error).", summary: "Arguments invalides") }
            let result = await ActionExecutor.execute(action, in: web, profile: ProfileKeychain().load(), presence: { attachCursor(); return cursor }()) { [weak self] request in
                await self?.confirm(request) ?? false
            }
            return AgentToolResult(ok: result.ok, text: result.message, summary: result.message)
        }
    }

    /// La recherche, une seule fois par requête : un résultat de moins de dix minutes est réutilisé (aucune requête, aucune page chargée).
    private func searchWithCache(_ query: String) async -> AgentToolResult {
        let key = ActionLedger.key(for: AgentCall(name: "search_web", argumentsJSON: "{\"query\":\"\(query)\"}"))
        if let cached = searchCache.value(for: key) {
            AIUsageMeter.shared.record { $0.searchesCached += 1 }
            return cached
        }
        AIUsageMeter.shared.record { $0.searches += 1 }
        let result = await search.search(query)
        if result.ok { searchCache.set(result, for: key, ttl: 600) }
        return result
    }

    func ask(_ question: String) async -> String? {
        await withCheckedContinuation { continuation in
            questionContinuation = continuation
            cursor.hold(.ask)
            pending = AIPending(kind: .question(question), since: Date())
            refresh()
        }
    }

    func confirmUnfamiliarAddress(_ address: String) async -> Bool {
        let host = URL(string: address)?.host ?? address
        return await confirm(ConfirmRequest(title: "Ouvrir ce site ?", rows: [(key: "Site", value: host), (key: "Adresse", value: String(address.prefix(160)))],
                                            warning: "Ni votre demande ni une recherche ne mentionnaient ce site. Une page peut l'avoir suggéré : ouvrez-le seulement si vous le reconnaissez.", host: host))
    }

    private func confirm(_ request: ConfirmRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmContinuation = continuation
            pending = AIPending(kind: .confirm(request), since: Date())
            refresh()
        }
    }

    func trace(_ items: [AgentTraceItem]) { setTrace(items) }
}
