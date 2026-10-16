import AppKit
import WebKit
import SwiftUI
import BrowserCore
import BrowserStorage
import BrowserSettingsUI
import DownloadKit
import OreeObjC
import MediaPlayer

extension BrowserWindowController {

    // MARK: - Memory budget

    func startMemoryBudgetTimer() {
        memoryBudgetTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.enforceMemoryBudget() }
        }
    }


    func memoryBudgetBytes() -> UInt64? {
        let setting = SettingsStore.shared.memoryBudgetMB
        guard setting >= 0 else { return nil }
        return setting == 0 ? MemoryBudget.automaticBudgetBytes() : UInt64(setting) * 1_048_576
    }


    func enforceMemoryBudget() async {
        // Two timers call this and a pass awaits (media checks, a 4 s pause): never run two at once.
        guard !isLifecyclePassRunning else { return }
        isLifecyclePassRunning = true
        defer { isLifecyclePassRunning = false }
        // Safety net: a paused page must never be the one on screen.
        for tab in tabs where tab.isFrozen && isOnScreen(tab) { tab.thaw() }
        await cleanHiddenTabsIfDue()

        var reading = measureTabMemory()
        recordSiteSamples(reading)

        let budget = memoryBudgetBytes() ?? UInt64.max
        isOverBudget = reading.total > budget

        if isOverBudget, releaseJavaScriptMemory(reason: "over budget") {
            try? await Task.sleep(for: .seconds(4))
            reading = measureTabMemory()
            isOverBudget = reading.total > budget
        }
        let plan = await lifecyclePlan(reading: reading, budget: budget, timing: lifecycleTiming())
        let slept = await apply(plan)
        if slept > 0 {
            Log.tabs.notice("Tab lifecycle: \(reading.total / 1_048_576) MB used, froze \(plan.freeze.count), slept \(slept)")
        }
    }

    func lifecycleTiming() -> TabLifecyclePolicy.Timing {
        var sleepAfter = TimeInterval(SettingsStore.shared.autoSuspendMinutes * 60)
        // After a recent memory warning, be much less patient.
        if sleepAfter > 0, let last = lastMemoryPressure, Date().timeIntervalSince(last) < 600 { sleepAfter = min(sleepAfter, 180) }
        let timing = TabLifecyclePolicy.Timing(freezeAfter: TimeInterval(SettingsStore.shared.freezeAfterSeconds), sleepAfter: sleepAfter)
        return EnergyPolicy.adjusted(timing, active: EnergyPolicy.isActive(mode: SettingsStore.shared.energyMode, systemLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }

    /// Why a tab may or may not be touched: on screen, playing sound, using camera/mic, a messaging
    /// or "never sleep" site → left alone; unsaved input → frozen but never torn down.
    func lifecycleExemption(of tab: Tab) async -> TabLifecyclePolicy.Exemption {
        if isOnScreen(tab) || tab.isCapturingMedia || tab.isInFullscreen || tab.audioState == .playing { return .full }
        if SleepExemptions.isExempt(host: tab.currentURL?.host, userHosts: SettingsStore.shared.neverSleepHosts) { return .full }
        if await tab.isPlayingMedia() { return .full }
        return tab.isDirty ? .noSleep : .none
    }

    func lifecyclePlan(reading: MemoryReading, budget: UInt64, timing: TabLifecyclePolicy.Timing) async -> TabLifecyclePolicy.Plan {
        let tabsPerProcess = Dictionary(grouping: reading.processOfTab.values, by: { $0 }).mapValues(\.count)
        let now = Date()
        var entries: [TabLifecyclePolicy.Entry] = []
        for tab in tabs where !tab.isSuspended && tab.webView != nil {
            guard let pid = reading.processOfTab[tab.id], let bytes = reading.bytesByProcess[pid] else { continue }
            var limit = timing.sleepAfter
            if limit > 0 {
                // A space you've switched away from is out of sight: its tabs sleep after 2 minutes at most.
                if tab.spaceIndex != currentSpace { limit = min(limit, 120) }
                limit = SiteMemoryPolicy.idleLimit(base: limit, profile: siteProfile(forHost: SiteMemoryPolicy.normalizedHost(tab.currentURL)))
            }
            entries.append(.init(id: tab.id, bytes: bytes / UInt64(max(tabsPerProcess[pid] ?? 1, 1)),
                                 idleSeconds: now.timeIntervalSince(tab.lastActiveDate),
                                 state: tab.isFrozen ? .frozen : .awake,
                                 exemption: await lifecycleExemption(of: tab),
                                 keepWeight: tab.spaceIndex == currentSpace ? 0.5 : 1,
                                 sleepAfter: limit))
        }
        return TabLifecyclePolicy.plan(entries: entries, budgetBytes: budget, timing: timing)
    }

    /// Carries out a plan; returns how many tabs were put to sleep.
    @discardableResult
    func apply(_ plan: TabLifecyclePolicy.Plan, captureGhost: Bool = true) async -> Int {
        for id in plan.freeze { tabs.first { $0.id == id }?.freeze() }
        var slept = 0
        for id in plan.sleep {
            guard let tab = tabs.first(where: { $0.id == id }), !isOnScreen(tab) else { continue }
            journalTabSlept(tab, why: "budget")
            await tab.suspend(captureGhost: captureGhost)
            slept += 1
        }
        return slept
    }

    /// Puts the best-scoring hidden tabs to sleep until the total should fit `target` (the active tab,
    /// sound/camera tabs and tabs with unsaved input are never torn down). Returns how many slept.
    func sleepTabs(toReach target: UInt64, reading: MemoryReading, minimumIdle: Double) async -> Int {
        let timing = TabLifecyclePolicy.Timing(freezeAfter: 0, sleepAfter: 0, minimumIdle: minimumIdle, hysteresis: 1)
        var plan = await lifecyclePlan(reading: reading, budget: target, timing: timing)
        plan.freeze = []
        return await apply(plan)
    }

    // MARK: - Audio indicators

    func startAudioTimer() {
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioIndicators() }
        }
    }

    func refreshAudioIndicators() {
        for tab in tabs where tab.webView != nil { tab.tabButton.setAudio(tab.audioState) }
    }

    // MARK: Now playing card

    /// A page's script found the site already dark: remember it, so night mode leaves it alone.
    func nativeDarkDetected(_ host: String) {
        let settings = SettingsStore.shared
        let updated = NightPolicy.adding(host, to: settings.nightNativeHosts)
        guard updated != settings.nightNativeHosts else { return }
        settings.nightNativeHosts = updated
        lastNight = nightSignature()
        refreshNightMode()
    }

    func handleMedia(tab: Tab, json: String) {
        guard !tab.isSuspended, tab.webView != nil else { return }
        let info = MediaInfo.parse(json)
        guard tab.media != info else { return }
        if journal.enabled, !tab.isPrivate, let now = info, let url = tab.webView?.url, JournalPolicy.allowsPage(url: url, isPrivate: false),
           tab.media == nil || tab.media?.paused != now.paused, let site = journal.site(of: url) {
            journal.emit("media", ["site": .string(site), "state": .string(now.paused ? "pause" : "play"), "pip": .bool(now.pictureInPicture)], tab: tab)
        }
        tab.media = info
        refreshNowPlaying()
    }

    /// The tab whose media the card shows: one that plays (the one already shown if it still does), else a paused one worth resuming.
    func mediaTab() -> Tab? {
        let candidates = tabs.filter { tab in
            guard !tab.isSuspended, tab.webView != nil, let info = tab.media else { return false }
            return MediaPolicy.isWorthShowing(info, playing: !info.paused)
        }
        let playing = candidates.filter { $0.media?.paused == false }
        if let current = playing.first(where: { $0.id == mediaTabID }) { return current }
        if let first = playing.first { return first }
        return candidates.first { $0.id == mediaTabID } ?? candidates.first
    }

    func refreshNowPlaying() {
        guard let tab = mediaTab(), var info = tab.media else {
            mediaTabID = nil
            if nowPlaying.isShown { nowPlaying.isShown = false; nowPlaying.setArtwork(nil); shownArtwork = nil; MediaKeys.shared.clear() }
            return
        }
        mediaTabID = tab.id
        let host = tab.badgeHost
        info.pictureInPicture = info.pictureInPicture || tab.pictureInPictureActive
        nowPlaying.update(info, host: host, deviceSymbol: audioRoute.output.symbol, deviceLine: audioRoute.line)
        nowPlaying.onTogglePlay = { [weak self, weak tab] in if let tab { self?.mediaCommand(tab, "toggle") } }
        nowPlaying.onSkip = { [weak self, weak tab] seconds in if let tab { self?.mediaCommand(tab, "skip", seconds) } }
        nowPlaying.onSeek = { [weak self, weak tab] fraction in
            if let tab, let duration = tab.media?.duration, duration > 0 { self?.mediaCommand(tab, "seek", fraction * duration) }
        }
        nowPlaying.onPictureInPicture = { [weak self, weak tab] in if let tab { self?.mediaCommand(tab, "pip") } }
        nowPlaying.onRate = { [weak self, weak tab] in
            if let tab, let rate = tab.media?.rate { self?.mediaCommand(tab, "rate", MediaPolicy.nextRate(after: rate)) }
        }
        nowPlaying.onShowTab = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
        nowPlaying.isShown = true
        MediaKeys.shared.update(info, host: host) { [weak self, weak tab] action in
            guard let self, let tab else { return }
            switch action {
            case .play: self.mediaCommand(tab, "play")
            case .pause: self.mediaCommand(tab, "pause")
            case .toggle: self.mediaCommand(tab, "toggle")
            case .skip(let seconds): self.mediaCommand(tab, "skip", seconds)
            case .seek(let position): self.mediaCommand(tab, "seek", position)
            }
        }
        loadArtwork(info.artwork, private: tab.isPrivate)
        audioRoute.watchBattery { [weak self] in self?.nowPlaying.isShown == true }
    }

    func mediaCommand(_ tab: Tab, _ name: String, _ value: Double = 0) {
        guard let web = tab.webView else { return }
        if name == "pip", tab.togglePictureInPicture() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshNowPlaying() }
            return
        }
        let call = MediaScript.commandCall(name, value: value)
        Task { @MainActor in _ = await web.safeCall(call.body, arguments: call.arguments, world: MediaScript.world) }
    }

    /// The cover given by the page, fetched once per address. Never for a private tab (the request would leave the private session).
    func loadArtwork(_ address: String?, private isPrivate: Bool) {
        let wanted = (isPrivate ? nil : address).flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil }
        guard wanted != shownArtwork else { return }                  // the card refreshes every second: touch the cover only when it changes
        shownArtwork = wanted
        guard let wanted, let url = URL(string: wanted) else { nowPlaying.setArtwork(nil); return }
        if let image = artworkCache[wanted] { nowPlaying.setArtwork(image); return }
        nowPlaying.setArtwork(nil)
        guard artworkRequested.insert(wanted).inserted else { return }
        Task { @MainActor [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), data.count < 3_000_000, let image = NSImage(data: data) else { return }
            self?.artworkCache[wanted] = image
            if self?.shownArtwork == wanted { self?.nowPlaying.setArtwork(image) }
        }
    }

    // MARK: Invisibility recorder (dev): samples what the user could notice, every 8 ms, until stopped


    /// Called by the navigation delegate while recording: a navigation after the swap is a real reload.
    func noteNavigation(_ kind: String, _ webView: WKWebView) {
        guard invisTimer != nil, let tab = tab(for: webView) else { return }
        invisSamples.append(["t": Int(Date().timeIntervalSince(invisStart) * 1000), "tab": tab.id.uuidString.prefix(4).description, "nav": kind])
    }

    /// Every ~100 ms: where the real page is scrolled, its readyState and a hash of what it shows, to see it move after the swap.
    func samplePage(of tab: Tab) {
        guard let web = tab.webView else { return }
        let tag = tab.id.uuidString.prefix(4).description
        let js = "(function(){var h=5381,s=JSON.stringify((function(){var o=[],a=document.body?document.body.querySelectorAll('p,h1,h2,h3,li,img'):[];for(var i=0;i<a.length&&o.length<80;i++){var r=a[i].getBoundingClientRect();if(r.bottom>0&&r.top<innerHeight)o.push([a[i].tagName,Math.round(r.top),Math.round(r.height)])}return o})());for(var i=0;i<s.length;i++)h=((h<<5)+h+s.charCodeAt(i))>>>0;return Math.round(scrollY)+'|'+document.readyState+'|'+h})()"
        Task { @MainActor in
            guard let out = await web.safeEvaluate(js, frame: nil, world: GhostScript.world) as? String, self.invisTimer != nil else { return }
            self.invisSamples.append(["t": Int(Date().timeIntervalSince(self.invisStart) * 1000), "tab": tag, "page": out])
        }
    }

    func startInvisibilityRecording() {
        invisTimer?.invalidate()
        invisSamples = []; invisStart = Date(); invisTicks = 0
        invisTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tab = self.activeTab else { return }
                self.invisTicks += 1
                if self.invisTicks % 12 == 0 { self.samplePage(of: tab) }
                if self.invisSamples.count > 60_000 { self.invisTimer?.invalidate(); self.invisTimer = nil; return }   // forgotten recorder: ~8 min
                self.invisSamples.append([
                    "t": Int(Date().timeIntervalSince(self.invisStart) * 1000), "tab": tab.id.uuidString.prefix(4).description,
                    "stack": tab.probeStack, "bar": Double(self.loadingBar.visibleOpacity), "spin": tab.tabButton.isLoading,
                    "stop": self.reloadButton.symbol == "xmark",
                ])
            }
        }
    }

    /// Writes the samples to /tmp/oree-invis.json and returns how many were taken.
    func stopInvisibilityRecording() -> String {
        invisTimer?.invalidate(); invisTimer = nil
        if let data = try? JSONSerialization.data(withJSONObject: invisSamples) { try? data.write(to: URL(fileURLWithPath: "/tmp/oree-invis.json")) }
        return "samples=\(invisSamples.count)"
    }

    /// Puts a tab to sleep by hand. The active tab first hands over to a neighbour in its space.
    func sleepTab(_ tab: Tab) {
        guard !tab.isSuspended, tab.webView != nil else { return }
        if splitContains(tab.id) { endSplit(keeping: nil) }
        if tab.id == activeTabID {
            guard let other = visibleTabs().first(where: { $0.id != tab.id }) else { return }
            selectTab(other)
        }
        journalTabSlept(tab, why: "user")
        Task { await tab.suspend() }
    }

    /// ⌥⌘E
    @objc func sleepActiveTab() { if let tab = activeTab { sleepTab(tab) } }

    /// ⌘⇧T
    @objc func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = Tab(configuration: makeConfiguration(isPrivate: false), isPrivate: false,
                      sleeping: (closed.url, closed.state, closed.title))
        tab.spaceIndex = closed.space
        attachTab(tab)
        selectTab(tab)   // wakes it
        saveSession()
    }

    /// ⌘1…⌘8 jump to that tab; ⌘9 always goes to the last one (browser convention).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(index) { selectTab(tabs[index]) }
    }

    @objc func moveActiveTabUp() { moveActiveTab(by: -1) }
    @objc func moveActiveTabDown() { moveActiveTab(by: 1) }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    /// The pointer rests on a sleeping tab: wake it in the background so the click finds it ready.
    /// Skipped when the Mac is already over the memory budget.
    func prewake(_ tab: Tab) {
        guard tab.isSuspended, !isOverBudget else { return }
        tab.lastActiveDate = Date()   // counts as touched: it must not be put straight back to sleep
        tab.journalWakeTrigger = "hover"
        ensureAwake(tab)
    }

    /// WebKit's private "first real content painted" signal (see `Tab.contentRenderedEvents`): the
    /// right moment to swap the snapshot for the live page. Ignored if this WebKit never calls it.
    @objc(_webView:renderingProgressDidChange:)
    func webViewRenderingProgress(_ webView: WKWebView, events: UInt) {
        guard events & Tab.contentRenderedEvents != 0, let tab = tab(for: webView) else { return }
        clearWakeRevealIfNeeded(for: tab)
    }

    /// The first time a freshly-woken tab's page reports anything (even a
    /// provisional navigation start), its stale snapshot can come down.
    func clearWakeRevealIfNeeded(for tab: Tab) {
        guard tab.isAwaitingWakeReveal else { return }
        tab.finishWakeReveal()
    }
}
