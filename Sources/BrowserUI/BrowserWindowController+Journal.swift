import AppKit
import WebKit
import CryptoKit
import BrowserCore
import BrowserStorage
import BrowserSettingsUI

/// Le journal d'événements, côté app : le gardien (réglage, onglets privés, pages protégées) et les points d'observation de la fenêtre.
/// Rien n'est écrit tant que la personne n'a pas activé le journal (Réglages › Confidentialité) ; rien en navigation privée ; jamais d'adresse, de titre ni de texte (voir `JournalSchema`).
@MainActor
final class JournalRecorder {
    static let shared = JournalRecorder()
    private(set) var journal: EventJournal
    private var siteKey: SymmetricKey?
    private var sessionStarted = false
    private let started = Date()
    private var lastPageEvents: [String: (window: Date, count: Int)] = [:]      // limite de débit par onglet : une page ne peut pas inonder le journal

    private init() {
        let override = ProcessInfo.processInfo.environment["HB_JOURNAL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        journal = EventJournal.standard(directory: override)
    }

    var enabled: Bool { SettingsStore.shared.eventJournalEnabled }

    /// Le journal est vidé et pris en compte avec les réglages courants (durée de garde).
    func applySettings() {
        journal.retentionDays = SettingsStore.shared.eventJournalDays
        if !enabled { journal.flushAndWait(); sessionStarted = false }
    }

    func emit(_ name: String, _ d: [String: JournalValue] = [:], tab: Tab? = nil, at time: Date = Date()) {
        guard enabled else { return }
        var fields = d
        if let tab {
            guard !tab.isPrivate else { return }
            fields["tab"] = .string(tab.journalID)
        }
        journal.record(JournalEvent(t: time.timeIntervalSince1970, e: name, d: fields))
    }

    /// L'empreinte du site d'une adresse (nil : pas une page web, ou le Trousseau ne répond pas).
    func site(of url: URL?) -> String? {
        guard let host = url?.host, !host.isEmpty else { return nil }
        if siteKey == nil { siteKey = journal.siteKey() }
        return siteKey.map { SiteHash.hash(host: host, key: $0) }
    }

    func hashHost(_ host: String) -> String {
        if siteKey == nil { siteKey = journal.siteKey() }
        return siteKey.map { SiteHash.hash(host: host, key: $0) } ?? "0000000000000000"
    }

    /// Une seule fois par lancement, quand le journal est actif : la machine, l'état de l'énergie, le temps de démarrage.
    func startSessionIfNeeded(restored: Int) {
        guard enabled, !sessionStarted else { return }
        sessionStarted = true
        let info = ProcessInfo.processInfo
        let scale = Int((NSScreen.main?.backingScaleFactor ?? 2).rounded())
        emit("session.start", ["ver": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"), "os": .int(info.operatingSystemVersion.majorVersion),
                               "scale": .int(scale), "cores": .int(info.activeProcessorCount), "mem": .int(Int(info.physicalMemory >> 30)), "lowpower": .bool(info.isLowPowerModeEnabled),
                               "charging": .bool(Self.isCharging()), "cold": .int(Self.processAgeMilliseconds()), "restored": .int(restored)])
        emitSystemState()
    }

    func emitSystemState(memoryPressure: String = "normal") {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "nominal" }
        emit("sys.state", ["thermal": .string(thermal), "lowpower": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled), "charging": .bool(Self.isCharging()), "mempress": .string(memoryPressure)])
    }

    func endSession() {
        guard enabled, sessionStarted else { return }
        emit("session.end", ["dur": .int(Int(Date().timeIntervalSince(started)))])
        journal.flushAndWait()
    }

    /// Une page ne peut pas envoyer plus de 120 événements par minute (le script en envoie moins de 20).
    func allowPageEvents(for tab: Tab, count: Int) -> Bool {
        let now = Date()
        var entry = lastPageEvents[tab.journalID] ?? (now, 0)
        if now.timeIntervalSince(entry.window) > 60 { entry = (now, 0) }
        entry.count += count
        lastPageEvents[tab.journalID] = entry
        return entry.count <= 120
    }

    static func processAgeMilliseconds() -> Int {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = Double(info.kp_proc.p_un.__p_starttime.tv_sec) + Double(info.kp_proc.p_un.__p_starttime.tv_usec) / 1e6
        return max(0, Int((Date().timeIntervalSince1970 - start) * 1000))
    }

    static func isCharging() -> Bool {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); task.arguments = ["-g", "batt"]
        let pipe = Pipe(); task.standardOutput = pipe
        guard (try? task.run()) != nil else { return true }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !out.contains("Battery Power")
    }
}

extension BrowserWindowController {
    var journal: JournalRecorder { JournalRecorder.shared }

    // MARK: Onglets

    func journalTabOpened(_ tab: Tab) {
        guard journal.enabled, !tab.isPrivate else { return }
        let how = journalOpenHow; journalOpenHow = "other"
        journal.emit("tab.open", ["how": .string(how), "n": .int(tabs.count), "space": .int(tab.spaceIndex)] .merging(activeTab.map { ["opener": JournalValue.string($0.journalID)] } ?? [:]) { $1 }, tab: tab)
    }

    func journalTabSelected(_ tab: Tab, previous: Tab?) {
        guard journal.enabled else { return }
        let now = Date()
        let via = journalSelectVia; journalSelectVia = "other"
        var dwell = 0
        if let previous, let since = previous.journalForegroundSince {
            dwell = Int(now.timeIntervalSince(since) * 1000)
            previous.journalForegroundTotal += now.timeIntervalSince(since)
            previous.journalForegroundSince = nil
            previous.journalLastForeground = now
        }
        let gap = tab.journalLastForeground.map { Int(now.timeIntervalSince($0)) } ?? Int(now.timeIntervalSince(tab.journalCreated))
        tab.journalForegroundSince = now
        guard previous?.id != tab.id, !tab.isPrivate else { return }
        var fields: [String: JournalValue] = ["via": .string(via), "dwell": .int(dwell), "gap": .int(gap), "asleep": .bool(tab.isSuspended)]
        if let previous, !previous.isPrivate { fields["prev"] = .string(previous.journalID) }
        journal.emit("tab.select", fields, tab: tab)
    }

    func journalTabClosed(_ tab: Tab) {
        guard journal.enabled, !tab.isPrivate else { return }
        let now = Date()
        var foreground = tab.journalForegroundTotal
        if let since = tab.journalForegroundSince { foreground += now.timeIntervalSince(since) }
        let why = journalCloseWhy; journalCloseWhy = "user"
        journal.emit("tab.close", ["life": .int(Int(now.timeIntervalSince(tab.journalCreated))), "fg": .int(Int(foreground)), "why": .string(why), "n": .int(tabs.count)], tab: tab)
    }

    func journalTabSlept(_ tab: Tab, why: String) {
        guard journal.enabled, !tab.isPrivate else { return }
        let footprint = tab.webProcessID.map { Int((MemoryBudget.footprint(ofProcess: $0) ?? 0) >> 20) } ?? 0
        journal.emit("tab.sleep", ["idle": .int(Int(Date().timeIntervalSince(tab.lastActiveDate))), "mb": .int(footprint), "why": .string(why)], tab: tab)
    }

    func journalWake(_ tab: Tab, ms: Int) {
        guard journal.enabled, !tab.isPrivate else { return }
        let trigger = tab.journalWakeTrigger; tab.journalWakeTrigger = "select"
        journal.emit("tab.wake", ["ms": .int(ms), "trigger": .string(trigger), "ghost": .bool(tab.journalWakeGhost)], tab: tab)
    }

    func journalTabMoved(_ tab: Tab, steps: Int) { journal.emit("tab.move", ["steps": .int(steps)], tab: tab) }
    func journalTabHover(_ tab: Tab, dwell: Int, preview: Bool, clicked: Bool) { journal.emit("tab.hover", ["dwell": .int(dwell), "preview": .bool(preview), "clicked": .bool(clicked)], tab: tab) }

    // MARK: Navigation

    func journalNavStart(_ tab: Tab, url: URL?) {
        guard journal.enabled, !tab.isPrivate, let url, url.scheme == "http" || url.scheme == "https" else { return }
        let site = journal.site(of: url)
        var fields: [String: JournalValue] = ["kind": .string(tab.journalNavKind)]
        if let site { fields["site"] = .string(site) }
        if let from = tab.journalNavSite { fields["from"] = .string(from); fields["same"] = .bool(from == site) }
        tab.journalNavStart = Date()
        tab.journalNavKind = "other"
        tab.journalMuted = false
        journal.emit("nav.start", fields, tab: tab)
    }

    func journalNavCommit(_ tab: Tab) {
        guard journal.enabled, !tab.isPrivate, let start = tab.journalNavStart else { return }
        tab.journalNavSite = journal.site(of: tab.webView?.url) ?? tab.journalNavSite
        journal.emit("nav.commit", ["ms": .int(Int(Date().timeIntervalSince(start) * 1000))], tab: tab)
    }

    func journalNavDone(_ tab: Tab, ok: Bool, code: Int = 0) {
        guard journal.enabled, !tab.isPrivate, let start = tab.journalNavStart else { return }
        tab.journalNavStart = nil
        var fields: [String: JournalValue] = ["ms": .int(Int(Date().timeIntervalSince(start) * 1000)), "ok": .bool(ok)]
        if !ok { fields["code"] = .int(code) }
        if let site = tab.journalNavSite { fields["site"] = .string(site) }
        journal.emit("nav.done", fields, tab: tab)
    }

    /// Un résumé envoyé par le script d'une page (pointeur, liens, défilement, forme, vitesse).
    func handleJournal(tab: Tab, body: Any) {
        guard journal.enabled, JournalPolicy.allowsPage(url: tab.webView?.url, isPrivate: tab.isPrivate), !tab.journalMuted else { return }
        let count = ((body as? [String: Any])?["ev"] as? [Any])?.count ?? 0
        guard journal.allowPageEvents(for: tab, count: count) else { return }
        let site = journal.site(of: tab.webView?.url) ?? "0000000000000000"
        let events = JournalIngest.events(from: body, tab: tab.journalID, pageSite: site, now: Date().timeIntervalSince1970) { [journal] host in journal.hashHost(host) }
        for event in events {
            // Une page à champ de mot de passe : sa forme est notée (« formulaire »), puis plus rien d'elle.
            if event.e == "page.shape", event.d["password"]?.bool == true { tab.journalMuted = true }
            journal.journal.record(event)
        }
    }

    // MARK: Interface

    func journalPanel(_ name: String, open: Bool) { journal.emit("ui.panel", ["name": .string(name), "open": .bool(open)]) }

    func journalWindowLayout() {
        guard journal.enabled, let window else { return }
        let store = SettingsStore.shared
        journal.emit("window.layout", ["w": .int(JournalBucket.hundreds(window.frame.width)), "h": .int(JournalBucket.hundreds(window.frame.height)), "sidebar": .string(store.sidebarMode.rawValue),
                                       "tabs": .string(store.tabLayout.rawValue), "fs": .bool(isFullScreen), "mini": .bool(isMini)])
    }

    func journalMemory() {
        guard journal.enabled else { return }
        let awake = tabs.filter { $0.webView != nil && !$0.isPrivate }
        let sizes = awake.compactMap { $0.webProcessID }.map { Int((MemoryBudget.footprint(ofProcess: $0) ?? 0) >> 20) }
        journal.emit("perf.mem", ["tabs": .int(tabs.count), "awake": .int(awake.count), "sleeping": .int(tabs.filter(\.isSuspended).count), "mb": .int(sizes.reduce(0, +)), "top": .int(sizes.max() ?? 0)])
    }
}

// MARK: Barre d'adresse : comment on tape, ce qu'on nous propose, ce qu'on choisit (jamais ce qui est tapé)
extension BrowserWindowController {
    func journalAddressFocused(how: String) {
        guard journal.enabled, !(activeTab?.isPrivate ?? false) else { return }
        journalAddress = (Date(), 0, 0, 0, 0, [:], false)
        journal.emit("addr.focus", ["how": .string(how)], tab: activeTab)
    }

    func journalAddressTyped(_ text: String, sections: [PaletteSection]) {
        guard journal.enabled, var state = journalAddress else { return }
        state.keys += 1
        if text.count < state.last { state.deletes += 1 }
        state.last = text.count; state.longest = max(state.longest, text.count)
        var shown: [String: Int] = ["n": 0]
        for section in sections {
            let n = section.items.count
            shown["n", default: 0] += n
            switch section.title {
            case "Historique": shown["hist", default: 0] += n
            case "Favoris": shown["bookmark", default: 0] += n
            case "Rechercher": shown["search", default: 0] += n
            case "Ouvrir": shown["site", default: 0] += n
            default: break
            }
        }
        state.shown = shown
        journalAddress = state
    }

    func journalAddressCommitted(kind: String, index: Int, newTab: Bool) {
        guard journal.enabled, var state = journalAddress else { return }
        state.committed = true; journalAddress = state
        let ms = Int(Date().timeIntervalSince(state.focusedAt) * 1000)
        journalAddressSummary(state, ms: ms, pick: index, pickKind: kind == "suggestion" ? "history" : (kind == "url" ? "typed" : (kind == "search" ? "search" : "none")))
        journal.emit("addr.commit", ["kind": .string(kind), "ms": .int(ms), "newtab": .bool(newTab)], tab: activeTab)
    }

    func journalAddressEnded() {
        guard journal.enabled, let state = journalAddress else { return }
        journalAddress = nil
        if !state.committed { journalAddressSummary(state, ms: Int(Date().timeIntervalSince(state.focusedAt) * 1000), pick: -1, pickKind: "none") }
    }

    private func journalAddressSummary(_ state: (focusedAt: Date, keys: Int, deletes: Int, longest: Int, last: Int, shown: [String: Int], committed: Bool), ms: Int, pick: Int, pickKind: String) {
        journal.emit("addr.input", ["keys": .int(state.keys), "ms": .int(ms), "len": .int(JournalBucket.log2(state.longest)), "deletes": .int(state.deletes)])
        var fields: [String: JournalValue] = ["pick": .int(pick), "kind": .string(pickKind)]
        for (key, value) in state.shown { fields[key] = .int(value) }
        journal.emit("addr.suggest", fields)
    }
}

// MARK: Démarrage, état du système, réglages
extension BrowserWindowController {
    /// À la fermeture de l'app : la fin de session est écrite et le tampon vidé.
    public static func endJournalSession() { JournalRecorder.shared.endSession() }
}

extension BrowserWindowController {
    /// Une fois la session restaurée : la session commence dans le journal (si actif), et les observateurs de l'état du système se mettent en place.
    public func journalStart() {
        JournalControls.stats = { [journal] in
            let stats = journal.journal.stats()
            return JournalControls.Stats(events: stats.events, files: stats.files, bytes: stats.bytes, first: stats.first)
        }
        JournalControls.export = { [journal] url in try journal.journal.export(to: url) }
        JournalControls.clear = { [journal] in journal.journal.clear() }
        journalObserve()
        journal.applySettings()
        journal.startSessionIfNeeded(restored: tabs.count)
        journalWindowLayout()
    }

    /// Le réglage vient de changer (ou autre chose : cette fonction est appelée à chaque changement de réglage, elle ne fait rien si rien n'a changé pour le journal).
    func journalSettingsChanged() {
        let on = journal.enabled
        if on != journalWasEnabled {
            journalWasEnabled = on
            journal.applySettings()
            if on { journal.startSessionIfNeeded(restored: tabs.count); journalWindowLayout() }
        }
        journal.journal.retentionDays = SettingsStore.shared.eventJournalDays
    }

    private func journalObserve() {
        guard journalTimer == nil else { return }
        journalWasEnabled = journal.enabled
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.journal.emit("app.active", ["on": .bool(true)]) } }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.journal.emit("app.active", ["on": .bool(false)]) } }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.journal.emitSystemState() } }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.journal.emitSystemState() } }
        // Toutes les minutes : ce que coûtent les onglets en mémoire (seulement si le journal est actif).
        journalTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.journalMemory() } }
    }

    /// La mise en page change en rafale quand on redimensionne : un seul événement, une seconde après la dernière.
    func journalLayoutSoon() {
        guard journal.enabled else { return }
        journalLayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.journalWindowLayout() } }
        journalLayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

// MARK: Téléchargements : la taille en classe et la durée, jamais le nom ni l'origine du fichier
extension BrowserWindowController {
    func journalDownloadStarted() {
        guard journal.enabled, !(activeTab?.isPrivate ?? false) else { return }
        journalDownloadStart = Date()
        let site = journal.site(of: activeTab?.webView?.url)
        var fields: [String: JournalValue] = ["size": .int(JournalBucket.log2(Int((downloads.items.last?.total ?? 0) >> 10)))]
        if let site { fields["site"] = .string(site) }
        journal.emit("dl.start", fields)
    }

    func journalDownloadFinished() {
        guard journal.enabled, let start = journalDownloadStart else { return }
        journalDownloadStart = nil
        let item = downloads.items.last
        journal.emit("dl.done", ["ms": .int(Int(Date().timeIntervalSince(start) * 1000)), "size": .int(JournalBucket.log2(Int((item?.received ?? 0) >> 10))), "ok": .bool(item?.phase == .finished)])
    }
}
