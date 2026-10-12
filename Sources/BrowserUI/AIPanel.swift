import AppKit
import BrowserCore
import DownloadKit
import OreeAIClient
import OreeAIEngine
import OreeAIProtocol
import BrowserStorage
import WebKit

/// Fait le lien entre le panneau, le service IA, la page, la recherche, le téléchargement du modèle et l'agent launchd. Une conversation par onglet.
///
/// Rien ne démarre avant la première ouverture : ni l'agent, ni la connexion au service. Une tâche à la fois (le service refuse la seconde).
/// Chaque question lance la boucle d'agent (`AgentLoop`, BrowserCore) : le modèle voit la page (si elle est partagée), demande un outil, le
/// navigateur le fait (avec confirmation pour tout geste sensible), jusqu'à la réponse ou un plafond (15 étapes, 3 recherches, 5 pages).
/// Le service n'a ni génération contrainte ni appels d'outils natifs (étape 5 du plan) : le modèle écrit une ligne JSON que `AgentParser`
/// lit avec indulgence. Avec un modèle de 2 milliards de paramètres, les actions longues réussiront souvent à moitié : la trace et les
/// confirmations sont là pour que la personne garde la main.
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
    }

    private let panel = AIPanelView()
    private let client: AIClient
    private weak var downloads: DownloadsController?
    private let hooks: Hooks
    /// Appelé quand le panneau s'ouvre ou se ferme (le bouton de la barre d'outils suit).
    var onVisibilityChange: ((Bool) -> Void)?
    private let pin = ModelPin.default
    private let machName = ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName
    private var widthConstraint: NSLayoutConstraint!
    private let search = SearchTab()
    private let cursor = AgentCursor()
    private func attachCursor() { if let host = hooks.pageHost() { cursor.attach(to: host) } }

    private var reachable: Bool?
    private var status: AIStatus?
    private var download: AIDownloadProgress?
    private var downloadSpeed: Double = 0
    private var lastSample: (date: Date, bytes: Int64)?
    private var downloadID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var started = false
    private var failure: String?
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
    private var lmModel: String? { LMStudio.chooseModel(preferred: SettingsStore.shared.aiModel(for: .lmstudio), available: lmStudio.models) }

    private func probeLMStudio() async {
        let url = LMStudio.modelsURL(base: SettingsStore.shared.lmStudioBase)
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
            lmStudio = (true, LMStudio.parseModels(data))
        } else { lmStudio = (false, []) }
        refresh()
    }
    /// Le fournisseur en usage : Groq (nuage) ou le modèle local. Les pages lues partent chez Groq quand il est choisi : le panneau le dit.
    private var provider: AIProvider { AIProvider.effective(stored: SettingsStore.shared.aiProviderChoice, keys: cloudKeys) }
    // La tâche en cours
    private var agentTask: Task<Void, Never>?
    private var runTab: UUID?
    private var runID = UUID()           // une tâche arrêtée peut finir plus tard : seule la tâche courante met l'affichage à jour
    private var turn: (id: String, buffer: String, continuation: CheckedContinuation<String, Error>)?
    private var pending: AIPending?
    private var cancelling: Task<Void, Never>?    // le service finit d'arrêter l'ancien tour : on attend avant d'en lancer un autre
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var questionContinuation: CheckedContinuation<String?, Never>?

    private static let widthKey = "oree.ai.panelWidth"
    private var width = AIPanelMetrics.clamp((UserDefaults.standard.object(forKey: AIPanelController.widthKey) as? Double) ?? AIPanelMetrics.defaultWidth)

    init(contentView: NSView, top: NSLayoutYAxisAnchor, downloads: DownloadsController, hooks: Hooks) {
        self.downloads = downloads
        self.hooks = hooks
        self.client = AIClient(machService: ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName)
        panel.isHidden = true
        contentView.addSubview(panel)
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
    var isOpen: Bool { !panel.isHidden }

    private var availability: AIAvailability {
        #if DEBUG
        // Dev (debug seulement) : `HB_AI_FAKE_STATE` montre un état du modèle sans le provoquer, pour relire les écrans.
        switch ProcessInfo.processInfo.environment["HB_AI_FAKE_STATE"] {
        case "needsModel": return .needsModel
        case "downloading": return .downloading(AIDownloadProgress(received: Int64(Double(pin.size) * 0.56), total: pin.size))
        case "verifying": return .verifying
        case "corrupt": return .corrupt
        case "connecting": return .connecting
        case "unreachable": return .unreachable
        default: break
        }
        #endif
        if provider == .lmstudio {
            switch lmStudio.reachable { case nil: return .connecting; case false?: return .unreachable; case true?: return lmStudio.models.isEmpty ? .unreachable : .ready(.warm) }
        }
        return provider.isCloud ? (cloudKeyPresent ? .ready(.warm) : .unreachable) : AIAvailability(reachable: reachable, status: status, download: download)
    }
    private var isRunning: Bool { agentTask != nil }
    private var messages: [AIMessage] {
        get { currentTab.flatMap { conversations[$0] } ?? [] }
        set { if let id = currentTab { conversations[id] = newValue } }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        cloudKeys = Self.presentKeys()
        panel.isHidden = false
        onVisibilityChange?(true)
        dock()
        panel.focus()
        refresh()
        Task { await prepare() }
    }

    func close() {
        panel.isHidden = true
        onVisibilityChange?(false)
        hooks.onLayout(0)
        panel.window?.makeFirstResponder(nil)
        if isRunning { stop() }
    }

    /// Le panneau pousse la page si la fenêtre est assez large ; sinon il la recouvre.
    private func dock() {
        guard isOpen else { return }
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

    // MARK: Service

    /// Installe l'agent (une fois, sans danger à répéter), vérifie l'état du service puis le réveille pour que la première question parte vite.
    private func prepare() async {
        if provider == .lmstudio { await probeLMStudio(); return }
        guard provider == .local else { refresh(); return }          // fournisseur en nuage : rien à installer ni à réveiller sur ce Mac
        if !started {
            started = true
            reachable = await ensureAgent() ? nil : false
            if reachable == nil { startListening() }
        }
        refresh()
        guard reachable != false else { return }
        guard let current = await client.status() else { reachable = false; refresh(); return }
        reachable = true
        status = current
        refresh()
        // « Vérification » = fichier présent mais pas encore vérifié : c'est `warmUp` qui lance la vérification (≈ 1 s pour 1,3 Go, une fois par
        // lancement du service) puis réveille le modèle. On le fait dès que le panneau s'ouvre, pour que la première question parte vite.
        if current.model == .ready || current.model == .verifying, let warmed = await client.warmUp(timeout: 40) { status = warmed; refresh() }
    }

    /// L'agent pointe vers l'exécutable `OreeAI` de CETTE copie de l'app. `HB_AI_NO_AGENT=1` : l'agent est géré à la main (essais).
    private func ensureAgent() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["HB_AI_NO_AGENT"] != nil { return true }
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OreeAI") else { return false }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.nolhan.hyperbrowser"
        let name = machName
        // launchctl prend du temps : jamais sur le fil principal.
        let result = await Task.detached { Result { try AIAgentInstaller.ensureInstalled(executable: executable, bundleIdentifier: bundleID, machName: name) } }.value
        if case .failure(let error) = result { Log.security.error("Agent IA indisponible : \(error.localizedDescription, privacy: .public)"); return false }
        return true
    }

    private func startListening() {
        guard eventsTask == nil else { return }
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    private func handle(_ event: AIEvent) {
        switch event {
        case .stateChanged(let current):
            status = current
        case .textDelta(let id, let text):
            if turn?.id == id { turn?.buffer += text }
        case .done(let id, let final, _):
            if let t = turn, t.id == id { turn = nil; t.continuation.resume(returning: final.isEmpty ? t.buffer : final) }
        case .error(let id, let message):
            if let t = turn, id == nil || id == t.id { turn = nil; t.continuation.resume(throwing: AgentFailure(message: message)) }
            else if id == nil { failure = message }
        default: break
        }
        refresh()
    }

    struct AgentFailure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    // MARK: Questions

    func ask(_ text: String) {
        cloudKeys = Self.presentKeys()
        guard availability.canAsk, !isRunning else { return }
        if currentTab == nil { currentTab = UUID() }      // aucune page ouverte (ou essai) : une conversation quand même
        let tab = currentTab!
        runTab = tab
        let run = UUID()
        runID = run
        failure = nil
        pendingFacts = []
        let context = messages.suffix(6).map { ($0.role == .user ? "Vous : " : "Luciole : ") + String($0.text.prefix(240)) }
        messages += [AIMessage(role: .user, text: text), AIMessage(role: .assistant, text: "", title: String(text.prefix(38)) + (text.count > 38 ? "…" : ""))]
        panel.clearComposer()
        agentTask = Task { [weak self] in
            guard let self else { return }
            let recalled = self.memoryOn ? self.memory.recall(host: self.hooks.activeWebView()?.url?.host, limit: self.provider.usesAPI ? 6 : 3) : []
            let outcome = await AgentLoop(environment: self, style: self.provider.usesAPI ? .nativeTools : .jsonLine).run(task: text, context: context, memory: recalled)
            if self.runID == run { self.finish(outcome, in: tab) }
        }
        refresh()
    }

    private func finish(_ outcome: AgentOutcome, in tab: UUID) {
        var list = conversations[tab] ?? []
        if var last = list.last, last.role == .assistant {
            switch outcome.reason {
            case .done: last.text = outcome.answer
            case .stepCap: last.text = outcome.answer; last.capped = true
            case .cancelled: if last.text.isEmpty { last.text = Self.stoppedText(steps: last.trace.count) }
            case .failed(let message): failure = message; if last.text.isEmpty { last.text = "Je n'ai pas pu terminer." }
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
        cursor.settle()
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
        if let t = turn { turn = nil; t.continuation.resume(throwing: CancellationError()); cancelling = Task { await client.cancel(taskID: t.id) } }
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
        case .download, .resume: downloadModel()
        case .later: close()
        case .retry: failure = nil; reachable = nil; started = false; lmStudio = (nil, []); refresh(); Task { await prepare() }
        case .cancelDownload:
            if let id = downloadID { downloads?.cancel(id) }
            downloadTask?.cancel(); downloadTask = nil; downloadID = nil; download = nil; downloadSpeed = 0; lastSample = nil
            refresh()
        case .deleteReceived:
            try? FileManager.default.removeItem(at: ModelFile.url(for: pin))
            failure = nil; refresh()
        }
    }

    /// Après l'accord de l'utilisateur (le bouton) : télécharge le modèle avec le moteur de téléchargement d'Orée (reprise, vitesse), puis le service le vérifie.
    private func downloadModel() {
        guard let downloads, downloadID == nil else { return }
        let target = ModelFile.url(for: pin)
        if status?.model == .corrupt { try? FileManager.default.removeItem(at: target) }     // sinon le moteur numéroterait le nouveau fichier
        failure = nil
        download = AIDownloadProgress(received: 0, total: pin.size)
        refresh()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            guard let id = await downloads.startModelDownload(url: self.pin.url, name: self.pin.name, directory: ModelFile.directory) else {
                self.download = nil
                self.failure = "Le téléchargement n'a pas pu démarrer."
                self.refresh()
                return
            }
            self.downloadID = id
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let item = downloads.items.first(where: { $0.id == id }) else { break }
                let now = Date()
                if let last = self.lastSample, now.timeIntervalSince(last.date) > 0 {
                    let instant = Double(item.received - last.bytes) / now.timeIntervalSince(last.date)
                    self.downloadSpeed = self.downloadSpeed == 0 ? max(instant, 0) : self.downloadSpeed * 0.7 + max(instant, 0) * 0.3      // lissée
                }
                self.lastSample = (now, item.received)
                self.download = AIDownloadProgress(received: item.received, total: item.total ?? self.pin.size)
                self.refresh()
                if item.phase == .finished { break }
                if item.phase == .failed || item.phase == .cancelled { self.failure = item.error ?? "Téléchargement interrompu."; break }
            }
            self.download = nil
            self.downloadID = nil
            self.downloadSpeed = 0; self.lastSample = nil
            await self.prepare()               // le service vérifie le fichier (SHA-256) puis le réveille
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
        let total = pin.size
        if provider == .lmstudio, lmStudio.reachable == false || lmStudio.models.isEmpty, lmStudio.reachable != nil {
            let base = SettingsStore.shared.lmStudioBase.absoluteString
            return lmStudio.reachable == true
                ? .init(title: "Aucun modèle chargé dans LM Studio.", text: "Le serveur répond, mais il ne propose aucun modèle de conversation. Chargez-en un dans LM Studio, puis réessayez.", primary: ("Réessayer", .retry))
                : .init(title: "LM Studio n'est pas joignable.", text: "Lancez LM Studio, chargez un modèle et démarrez le serveur local (onglet Developer › Start Server). Adresse essayée : \(base). Le reste d'Orée fonctionne normalement.", primary: ("Réessayer", .retry))
        }
        if provider.isCloud, !cloudKeyPresent {
            return .init(title: "Ajoutez votre clé \(provider.displayName).", text: "Réglages › Assistant IA › \(provider.displayName) : collez votre clé API. Elle reste dans le Trousseau de ce Mac.")
        }
        if pageIsProtected, messages.isEmpty {
            return .init(title: "Je détourne les yeux.", text: "Les réglages d'Orée, les paiements et les mots de passe restent hors de portée de l'IA. Sur un autre onglet, je reprends là où nous en étions.")
        }
        switch state {
        case .ready: return nil
        case .connecting: return .init(title: "Luciole se réveille.", text: "Moins d'une seconde.", indeterminate: true)
        case .unreachable:
            return .init(title: "Luciole n'est pas joignable pour l'instant.", text: "Le service IA ne répond pas. Il se lance au premier usage : réessayez, ou relancez Orée si cela dure. Le reste d'Orée fonctionne normalement.",
                         primary: ("Réessayer", .retry))
        case .needsModel:
            if let failure {
                var screen = AIPanelView.ModelScreen(title: "Le téléchargement s'est interrompu.", text: "Ce qui a déjà été reçu est gardé : la reprise repart de là.",
                                                    primary: ("Reprendre", .resume), secondary: ("Supprimer ce qui a été reçu", .deleteReceived))
                screen.footnote = "Détail : " + failure
                return screen
            }
            var free = ""
            if let bytes = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                free = "Il faut \(size(Int64(Double(total) * 1.6))) d'espace libre pendant l'installation ; ce Mac en a \(size(bytes))."
            }
            return .init(title: "Luciole dort encore.", text: "Pour lire, résumer et agir sans internet, Luciole a besoin de son modèle. Rien ne se télécharge sans votre accord.",
                         facts: [("arrow.down", size(total), ", téléchargé une seule fois."), ("lock", "", "Reste sur ce Mac. Ce que vous lisez ne part sur aucun serveur."),
                                 ("slider.horizontal.3", "", "Supprimable à tout moment dans Réglages › Assistant IA.")],
                         primary: ("Télécharger (\(size(total)))", .download), secondary: ("Plus tard", .later), footnote: free.isEmpty ? nil : free)
        case .downloading(let progress):
            let done = progress.received, all = progress.total ?? total
            var right = ""
            if downloadSpeed > 0 { right = "\(ByteFormat.speed(downloadSpeed)) · environ \(Int(max(Double(all - done) / downloadSpeed, 1))) s" }
            return .init(title: "Téléchargement du modèle", text: "Vous pouvez continuer à naviguer. Luciole s'allume tout seul à la fin.",
                         progress: all > 0 ? Double(done) / Double(all) : nil, indeterminate: all <= 0,
                         progressLeft: "\(size(done)) sur \(size(all))", progressRight: right, secondary: ("Annuler le téléchargement", .cancelDownload))
        case .verifying: return .init(title: "Vérification du modèle", text: "Orée vérifie le fichier avant de le charger : quelques secondes.", indeterminate: true)
        case .corrupt:
            return .init(title: "Le modèle est abîmé.", text: "Le fichier reçu ne correspond pas à ce qui était attendu. Il sera remplacé par une nouvelle copie.", primary: ("Télécharger à nouveau", .download))
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
        else if running, list.last?.trace.last?.state == .running { pose = .act }
        else { pose = LucioleState.pose(availability: state, running: running, streaming: streaming, failed: failure != nil) }
        if provider.isCloud, !cloudKeyPresent { pose = .sleep }

        // Puce d'état
        var chipText = "Prêt", dot = AIPanelView.Dot.accent
        switch state {
        case .connecting: chipText = "Réveil"
        case .unreachable where provider.isCloud: chipText = "Clé manquante"; dot = .outline
        case .unreachable: chipText = "Indisponible"; dot = .muted
        case .needsModel: chipText = failure != nil ? "Erreur" : "Non installé"; dot = failure != nil ? .alert : .outline
        case .downloading(let p):
            chipText = p.total.map { $0 > 0 ? "Téléchargement · \(Int(Double(p.received) / Double($0) * 100)) %" : "Téléchargement" } ?? "Téléchargement"
        case .verifying: chipText = "Vérification"
        case .corrupt: chipText = "Erreur"; dot = .alert
        case .ready:
            if failure != nil { chipText = "Erreur"; dot = .alert }
            else if hasPending { chipText = "Attend votre accord" }
            else if running { chipText = "Au travail" }
            else { chipText = provider.usesAPI ? provider.displayName : "Prêt" }
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
        if let p = pending, !p.armed {            // « Valider » devient actif après 1,2 s : on redessine à ce moment-là
            Task { try? await Task.sleep(for: .milliseconds(1250)); self.refresh() }
        }
    }

    // MARK: Automatisation

    /// Dev : ce que le panneau dit et montre (même format que l'ancienne barre, pour `ai_check.py`).
    var report: String {
        let last = messages.last(where: { $0.role == .assistant })
        let trace = last?.trace.map { "\($0.state):\($0.text)" + ($0.detail.map { " — " + $0 } ?? "") }.joined(separator: " | ") ?? ""
        return "open=\(isOpen) state=\(availability) running=\(isRunning) width=\(Int(width)) pose=\(panel.mascot.state.rawValue) pending=\(pending.map { "\($0.kind)" } ?? "none") cursor=[\(cursor.report)] think=\(last?.thinking.count ?? 0) trace=[\(trace)] line=\(failure ?? "")| answer=\((last?.text ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))"
    }

    #if DEBUG
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
    private static func logTurn(_ prompt: String, _ text: String) {
        guard let path = ProcessInfo.processInfo.environment["HB_AI_TRACE"] else { return }
        let entry = "=== PROMPT (\(PageMap.estimatedTokens(prompt)) jetons estimés)\n\(prompt)\n=== RÉPONSE\n\(text)\n\n"
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

    func askModel(_ prompt: String) async throws -> String {
        #if DEBUG
        if let scripted = Self.scriptedReply() { Self.logTurn(prompt, scripted); return scripted }
        #endif
        if provider.usesAPI {
            guard let model = provider == .lmstudio ? lmModel : SettingsStore.shared.aiModel(for: provider) else { throw AgentFailure(message: "Aucun modèle chargé dans LM Studio.") }
            do {
                mutateAnswer { $0 = "" }                      // un nouveau tour : on repart d'un texte vide
                setThinking("")
                let text = try await CloudClient(provider: provider, model: model, endpoint: SettingsStore.shared.aiEndpoint(for: provider)).complete(prompt: prompt) { [weak self] partial, thinking in
                    self?.showPartial(partial, thinking: thinking)
                }
                Self.logTurn(prompt, text)
                return text
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as CloudClient.Failure { throw AgentFailure(message: error.message) }
            catch { throw AgentFailure(message: "\(provider.displayName) est injoignable : \(error.localizedDescription)") }
        }
        await cancelling?.value
        let request = AIRunRequest(userText: prompt)
        let id = request.taskID
        let text: String = try await withCheckedThrowingContinuation { continuation in
            turn = (id, "", continuation)
            Task { [weak self] in
                guard let self else { return }
                var accepted = await self.client.run(request)
                for _ in 0..<3 where !accepted && self.turn?.id == id {       // le service peut finir d'arrêter l'ancien tour
                    try? await Task.sleep(for: .milliseconds(600))
                    accepted = await self.client.run(request)
                }
                if !accepted, let t = self.turn, t.id == id {
                    self.turn = nil
                    t.continuation.resume(throwing: AgentFailure(message: "Le service IA n'a pas pris la demande. Réessayez dans un instant."))
                }
            }
            // Un tour sans fin de réponse en 90 s : on le dit au lieu d'attendre indéfiniment.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, let t = self.turn, t.id == id else { return }
                self.turn = nil
                await self.client.cancel(taskID: id)
                t.continuation.resume(throwing: AgentFailure(message: "Pas de réponse du service IA depuis 90 secondes."))
            }
        }
        Self.logTurn(prompt, text)
        return text
    }

    /// Carte de la page affichée, réduite pour tenir dans les 4 096 jetons du contexte (avec la réponse et les consignes).
    func pageMap() async -> String? {
        guard shareContext, pageIsReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return nil }
        return provider.usesAPI ? map.render(maxElements: 45, maxText: 2800) : map.render(maxElements: 30, maxText: 1200)
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
            return await search.search(query)
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
            guard pageIsReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return AgentToolResult(ok: false, text: "Aucune page lisible.", summary: "Page non lisible") }
            return AgentToolResult(ok: true, text: map.render(maxElements: 0, maxText: 2400), summary: "Lecture de la page")
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

    func ask(_ question: String) async -> String? {
        await withCheckedContinuation { continuation in
            questionContinuation = continuation
            cursor.hold(.ask)
            pending = AIPending(kind: .question(question), since: Date())
            refresh()
        }
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
