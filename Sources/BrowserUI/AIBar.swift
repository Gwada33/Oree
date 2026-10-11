import AppKit
import BrowserCore
import DownloadKit
import OreeAIClient
import OreeAIEngine
import OreeAIProtocol

/// La barre IA : une carte flottante en haut de la page, où l'on pose une question à l'IA locale et où la réponse s'écrit au fil de l'eau.
/// Elle ne fait que parler au service (`AIBarController`) : tout ce qui est décision d'état est dans `AIAvailability`.
@MainActor
final class AIBarView: SurfaceView, NSTextFieldDelegate {
    let field = NSTextField()
    private let status = oreeLabel("", font: Theme.sans(12.5, .medium), color: Theme.muted, lines: 0)
    private let answer = NSTextView()
    private let scroll = NSScrollView()
    private let stop = TextButton("Stop", style: .secondary)
    private let download = TextButton("Télécharger le modèle", style: .primary)
    private let closeButton = ChromeIconButton(symbol: "xmark", label: "Fermer", size: 26, pointSize: 11)
    private var scrollHeight: NSLayoutConstraint?
    /// Le bas de la carte suit le texte d'état, ou le bouton quand il est visible.
    private lazy var bottomWithoutButton = bottomAnchor.constraint(equalTo: status.bottomAnchor, constant: 14)
    private lazy var bottomWithButton = bottomAnchor.constraint(equalTo: download.bottomAnchor, constant: 14)

    var onSubmit: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onDownload: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(fill: Theme.raised, cornerRadius: Theme.radiusLarge + 4)
        border = Theme.line
        elevation = .three
        isHidden = true

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.sans(16)
        field.textColor = Theme.text
        field.placeholderString = "Demandez quelque chose à l'IA locale…"
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        field.translatesAutoresizingMaskIntoConstraints = false

        answer.isEditable = false
        answer.isSelectable = true
        answer.drawsBackground = false
        answer.font = Theme.sans(14)
        answer.textColor = Theme.text
        answer.textContainerInset = NSSize(width: 0, height: 4)
        scroll.documentView = answer
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.maximumNumberOfLines = 0
        stop.onClick = { [weak self] in self?.onStop?() }
        download.onClick = { [weak self] in self?.onDownload?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        stop.isHidden = true
        download.isHidden = true
        for view in [field, scroll, status, stop, download, closeButton] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = height
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 16), field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8), field.heightAnchor.constraint(equalToConstant: 26),
            closeButton.centerYAnchor.constraint(equalTo: field.centerYAnchor), closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), height,
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(lessThanOrEqualTo: stop.leadingAnchor, constant: -12),
            stop.centerYAnchor.constraint(equalTo: status.centerYAnchor), stop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            download.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10), download.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
        ])
        bottomWithoutButton.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Display

    func show(status line: String, canAsk: Bool, offersDownload: Bool, running: Bool) {
        status.stringValue = line
        download.isHidden = !offersDownload
        bottomWithButton.isActive = offersDownload
        bottomWithoutButton.isActive = !offersDownload
        stop.isHidden = !running
        field.isEnabled = canAsk && !running
        field.placeholderString = canAsk ? "Demandez quelque chose à l'IA locale…" : "L'IA n'est pas encore prête"
    }

    func setAnswer(_ text: String) {
        answer.string = text
        guard !text.isEmpty else { scrollHeight?.constant = 0; return }
        answer.layoutManager?.ensureLayout(for: answer.textContainer!)
        let used = answer.layoutManager?.usedRect(for: answer.textContainer!).height ?? 40
        scrollHeight?.constant = min(max(used + 16, 44), 300)
        answer.scrollToEndOfDocument(nil)
    }

    var answerText: String { answer.string }
    func focus() { window?.makeFirstResponder(field) }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmit?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint { self.priority = priority; return self }
}

/// Fait le lien entre la barre, le service IA, le téléchargement du modèle et l'agent launchd.
///
/// Rien ne démarre avant la première ouverture de la barre : ni l'agent, ni la connexion au service (le service ne se lance qu'à ce moment-là).
/// Une tâche à la fois (le service refuse la seconde) ; chaque question est indépendante à cette étape (pas de mémoire, pas de page lue).
@MainActor
final class AIBarController {
    private let bar = AIBarView()
    private let client: AIClient
    private weak var downloads: DownloadsController?
    private let pin = ModelPin.qwen35_2B
    private let machName = ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName

    private var reachable: Bool?
    private var status: AIStatus?
    private var download: AIDownloadProgress?
    private var downloadID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var started = false
    private var taskID: String?
    private var answer = ""
    private var failure: String?

    init(container: NSView, downloads: DownloadsController) {
        self.downloads = downloads
        self.client = AIClient(machService: ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 56), bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.widthAnchor.constraint(equalToConstant: 640).withPriority(.defaultHigh),
            bar.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])
        bar.onSubmit = { [weak self] text in self?.ask(text) }
        bar.onStop = { [weak self] in self?.stop() }
        bar.onDownload = { [weak self] in self?.downloadModel() }
        bar.onClose = { [weak self] in self?.close() }
    }

    var view: NSView { bar }
    var isOpen: Bool { !bar.isHidden }

    private var availability: AIAvailability { AIAvailability(reachable: reachable, status: status, download: download) }
    private var isRunning: Bool { taskID != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        bar.isHidden = false
        bar.focus()
        refresh()
        Task { await prepare() }
    }

    func close() {
        if isRunning { stop() }
        bar.isHidden = true
    }

    // MARK: Service

    /// Installe l'agent (une fois, sans danger à répéter), vérifie l'état du service puis le réveille pour que la première question parte vite.
    private func prepare() async {
        if !started {
            started = true
            reachable = await ensureAgent() ? nil : false
            if reachable == nil { startListening() }
        }
        refresh()
        guard reachable != false else { return }
        guard var current = await client.status() else { reachable = false; refresh(); return }
        reachable = true
        status = current
        refresh()
        // « Vérification » = fichier présent mais pas encore vérifié : c'est `warmUp` qui lance la vérification (≈ 1 s pour 1,3 Go, une fois par
        // lancement du service) puis réveille le modèle. On le fait dès que la barre s'ouvre, pour que la première question parte vite.
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
            guard id == taskID else { return }
            answer += text
            bar.setAnswer(answer)
        case .done(let id, let final, _):
            guard id == taskID else { return }
            if !final.isEmpty { answer = final; bar.setAnswer(answer) }
            taskID = nil
        case .error(let id, let message):
            guard id == nil || id == taskID else { return }
            failure = message
            taskID = nil
        default: break
        }
        refresh()
    }

    // MARK: Questions

    func ask(_ text: String) {
        guard availability.canAsk, !isRunning else { return }
        let request = AIRunRequest(userText: text)
        taskID = request.taskID
        answer = ""
        failure = nil
        bar.setAnswer("")
        refresh()
        Task {
            if await client.run(request) == false, taskID == request.taskID {
                failure = "Le service IA n'a pas pris la question. Réessayez dans un instant."
                taskID = nil
                refresh()
            }
        }
        watchdog(request.taskID)
    }

    /// Une tâche sans aucune réponse depuis trop longtemps : on le dit au lieu d'attendre indéfiniment.
    private func watchdog(_ id: String) {
        Task { [weak self] in
            var lastLength = -1
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.taskID == id else { return }
                if self.answer.count == lastLength {
                    self.failure = "Pas de réponse du service IA depuis une minute."
                    self.taskID = nil
                    await self.client.cancel(taskID: id)
                    self.refresh()
                    return
                }
                lastLength = self.answer.count
            }
        }
    }

    func stop() {
        guard let id = taskID else { return }
        taskID = nil                       // les événements qui arrivent encore pour cette tâche sont ignorés
        failure = answer.isEmpty ? nil : "Arrêté."
        refresh()
        Task { await client.cancel(taskID: id) }
    }

    // MARK: Modèle

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
                self.download = AIDownloadProgress(received: item.received, total: item.total ?? self.pin.size)
                self.refresh()
                if item.phase == .finished { break }
                if item.phase == .failed || item.phase == .cancelled { self.failure = item.error ?? "Téléchargement interrompu."; break }
            }
            self.download = nil
            self.downloadID = nil
            await self.prepare()               // le service vérifie le fichier (SHA-256) puis le réveille
        }
    }

    // MARK: Affichage

    private func refresh() {
        let state = availability
        var line = state.line(modelBytes: pin.size)
        if let failure { line = failure + " " + (state.canAsk ? "" : line) }
        bar.show(status: line.trimmingCharacters(in: .whitespaces), canAsk: state.canAsk, offersDownload: state.offersDownload, running: isRunning)
    }

    // MARK: Automatisation

    /// Dev : ce que la barre dit et montre.
    var report: String {
        "open=\(isOpen) state=\(availability) running=\(isRunning) line=\(bar.field.placeholderString ?? "")| answer=\(bar.answerText.replacingOccurrences(of: "\n", with: " ⏎ "))"
    }
}
