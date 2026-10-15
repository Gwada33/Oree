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

    // MARK: - Boosts (change a site with one sentence) and calm mode

    func boostConfig() -> BoostScript.Config {
        BoostScript.config(boosts: (try? boostRepo.all()) ?? [], calmAll: SettingsStore.shared.calmModeEverywhere)
    }

    func boostSignature() -> String {
        let boosts = (try? boostRepo.all()) ?? []
        return "\(SettingsStore.shared.calmModeEverywhere)|" + boosts.map { "\($0.host):\($0.enabled):\($0.calm):\($0.rules.count):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
    }

    /// Hands the boosts to every tab: future pages through their scripts, the page on screen at once.
    func refreshBoosts() {
        let config = boostConfig()
        lastBoostSignature = boostSignature()
        for tab in tabs {
            tab.setUserScripts(userScripts(for: tab.currentURL))
            if let web = tab.webView { Task { _ = await web.safeEvaluate(BoostScript.source(config), world: BoostScript.world) } }
        }
    }

    /// ⌘K › « Personnaliser ce site… »: asks what to change, has the local model write the rules, checks them against the page, applies them.
    @objc func customizeSiteAction() {
        guard let tab = activeTab, let web = tab.webView, let host = web.url?.host, TranslationPolicy.canTranslate(url: web.url) else { return }
        if let reason = LocalModel.unavailableReason {
            showSimpleAlert("Personnaliser ce site a besoin du modèle local d'Apple Intelligence.", reason)
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "par exemple : cache les recommandations et agrandis le texte"
        let alert = NSAlert()
        alert.messageText = "Personnaliser \(host)"
        alert.informativeText = "Décrivez en une phrase ce que vous voulez changer sur ce site. Seul le style est modifié, et seulement ici."
        alert.accessoryView = field
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !request.isEmpty else { return }
            self?.createBoost(request: request, for: tab)
        }
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    func createBoost(request: String, for tab: Tab) {
        guard let web = tab.webView, let host = web.url?.host else { return }
        boostTask?.cancel()
        noticePill.show(message: "Création du boost…", button: "Annuler", seconds: 150) { [weak self] in self?.boostTask?.cancel(); self?.noticePill.dismiss() }
        boostTask = Task { [weak self] in
            guard let self else { return }
            guard let reply = await web.callJSON(BoostScript.survey, world: BoostScript.world, seconds: 15) as? [String: Any],
                  let raw = reply["candidates"] as? [[String: Any]], !raw.isEmpty else {
                if !Task.isCancelled { self.noticePill.dismiss(); self.showSimpleAlert("Personnalisation impossible", "Je n'ai pas pu lire la structure de cette page.") }
                return
            }
            let candidates = raw.compactMap { item -> BoostPrompt.Candidate? in
                guard let selector = item["s"] as? String, let count = (item["n"] as? NSNumber)?.intValue else { return nil }
                return .init(selector: selector, count: count, text: (item["t"] as? String) ?? "")
            }
            do {
                let answer = try await LocalModel.respond(instructions: BoostPrompt.instructions,
                                                          prompt: BoostPrompt.prompt(request: request, host: host, candidates: candidates), seconds: 150)
                guard !Task.isCancelled else { return }
                let proposed = BoostPolicy.rules(fromModel: answer)
                // Dry run on the page: a rule must match something, and not nearly everything.
                let call = BoostScript.countCall(selectors: proposed.rules.map(\.selector))
                let counted = await web.callJSON(call.body, arguments: call.arguments, world: BoostScript.world, seconds: 15) as? [String: Any]
                let counts = (counted?["counts"] as? [NSNumber])?.map(\.intValue) ?? []
                let texts = (counted?["texts"] as? [NSNumber])?.map(\.intValue) ?? []
                let elements = (counted?["elements"] as? NSNumber)?.intValue ?? 1000
                let pageText = (counted?["pageText"] as? NSNumber)?.intValue ?? 0
                let rules = proposed.rules.enumerated().filter { index, rule in
                    index < counts.count && index < texts.count
                        && BoostPolicy.isAcceptable(rule, matches: counts[index], pageElements: elements, matchedText: texts[index], pageText: pageText)
                }.map(\.element)
                guard !rules.isEmpty || proposed.calm else {
                    self.noticePill.dismiss()
                    self.showSimpleAlert("Rien à changer", "Je n'ai trouvé sur cette page aucun élément qui corresponde à « \(request) ». Essayez avec d'autres mots.")
                    return
                }
                let previous = try? self.boostRepo.boost(for: host)
                try? self.boostRepo.save(Boost(host: host, prompt: request, rules: rules, calm: proposed.calm || (previous?.calm ?? false)))
                self.refreshBoosts()
                let what = rules.isEmpty ? "mode calme" : "\(rules.count) règle\(rules.count > 1 ? "s" : "")"
                self.noticePill.show(message: "Boost appliqué à \(host) (\(what))", button: "Annuler", seconds: 15) { [weak self] in
                    guard let self else { return }
                    if let previous { try? self.boostRepo.save(previous) } else { try? self.boostRepo.remove(host: host) }
                    self.refreshBoosts()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.noticePill.dismiss()
                self.showSimpleAlert("Personnalisation impossible", error as? LocalModel.Failure == .timedOut ? "Le modèle a mis trop de temps à répondre." : "Le modèle n'a pas pu écrire de règles.")
            }
        }
    }

    @objc func removeBoostAction() {
        guard let host = activeTab?.webView?.url?.host else { return }
        try? boostRepo.remove(host: host)
        refreshBoosts()
    }

    /// Calm mode on the current site: on if it was off, off if it was on (the boost's own rules stay).
    @objc func toggleCalmForSiteAction() {
        guard let host = activeTab?.webView?.url?.host, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) else { return }
        var boost = (try? boostRepo.boost(for: host)) ?? Boost(host: host)
        boost.calm.toggle()
        if !boost.calm && boost.rules.isEmpty { try? boostRepo.remove(host: host) } else { try? boostRepo.save(boost) }
        refreshBoosts()
    }

    func showSimpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        guard let window else { alert.runModal(); return }
        alert.beginSheetModal(for: window)
    }

    // MARK: - L'essentiel

    func updateDigestButton(for tab: Tab) {
        setRelevant(.essentiel, tab.digestCandidate != nil)
        digestButton.isActive = digestPanel.state != "closed"
        setRelevant(.calendar, tab.eventCandidate != nil)
    }

    /// What a page says about itself in its JSON-LD: a recipe or how-to, an event or booking.
    struct StructuredData { var digest: PageDigest?; var event: CalendarEvent? }

    /// Reads the page's JSON-LD. A busy page can answer late (ads, trackers), so it asks again a couple of times; a reply — even one with
    /// nothing in it — is final. nil only when the page never answered.
    func readStructuredData(in web: WKWebView, attempts: Int) async -> StructuredData? {
        for attempt in 0..<attempts {
            if let reply = await web.callJSON(DigestScript.probe, world: DigestScript.world, seconds: 12) as? [String: Any],
               let blocks = reply["jsonld"] as? [String] {
                let data = StructuredData(digest: DigestParser.fromStructuredData(blocks, pageTitle: (reply["title"] as? String) ?? ""),
                                          event: EventParser.fromStructuredData(blocks))
                Log.tabs.notice("Page data: \(blocks.count) block(s), recipe/how-to \(data.digest == nil ? "none" : "found"), event \(data.event == nil ? "none" : "found") (attempt \(attempt + 1))")
                return data
            }
            Log.tabs.notice("Page data: the page did not answer (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    /// After a page has loaded: does it carry its own recipe / how-to or event data? If so the buttons appear; a recipe opens its essentials
    /// at once (default; no model, instant), the rest gets a one-line offer.
    func probeDigest(for tab: Tab) {
        guard TranslationPolicy.canTranslate(url: tab.webView?.url), let web = tab.webView else { return }
        let key = ResumePolicy.key(for: web.url)
        Task {
            let data = await readStructuredData(in: web, attempts: 3)
            guard ResumePolicy.key(for: web.url) == key else { return }       // the tab moved on meanwhile
            tab.digestCandidate = data?.digest
            tab.eventCandidate = data?.event
            if tab.id == activeTabID { updateDigestButton(for: tab) }
            guard tab.id == activeTabID, digestPanel.state == "closed", let key else { return }
            if let candidate = data?.digest, !digestDismissed.contains(key) {
                if SettingsStore.shared.digestAutoRecipes, candidate.kind == .recipe {
                    noticePill.dismiss()                                          // a "resume reading" offer makes no sense over the essentials
                    openDigest(for: tab)                                          // also after a reload or back/forward: the page is the same recipe
                } else if noticePill.visibleMessage == nil, tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other {
                    noticePill.show(message: candidate.kind == .recipe ? "Recette détectée" : "Tutoriel détecté", button: "Aller à l'essentiel", seconds: 10) { [weak self, weak tab] in
                        if let tab { self?.openDigest(for: tab); self?.updateDigestButton(for: tab) }
                    }
                }
            } else if let event = data?.event, noticePill.visibleMessage == nil, tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other {
                noticePill.show(message: "Événement détecté", button: "Ajouter au Calendrier", seconds: 12) { [weak self] in self?.confirmAndAdd(event, page: tab.webView?.url) }
            }
        }
    }

    /// Button, palette and menu: show the essentials of the page, or close them.
    @objc func digestAction() {
        guard let tab = activeTab else { return }
        if digestPanel.state != "closed" { digestPanel.close(byUser: true) } else { openDigest(for: tab) }
        updateDigestButton(for: tab)
    }

    /// The page's own data when it has some (instant); else the local model reads the page's text (about half a minute).
    func openDigest(for tab: Tab) {
        guard let web = tab.webView, let key = ResumePolicy.key(for: web.url) else { return }
        digestTask?.cancel()
        digestKey = key
        digestDismissed.remove(key)                       // asked for again: the user wants it
        if let cached = digestCache[key] { digestPanel.show(cached, notice: cached.source == .structured ? nil : "Écrit par le modèle local.") ; return }
        if let page = tab.digestCandidate {
            digestCache[key] = page
            digestPanel.show(page, notice: nil)
            return
        }
        // No data seen at load (the page may have been slow to answer): look again now, before spending half a minute on the model.
        digestPanel.showBusy("Lecture de la page…") { [weak self] in self?.digestTask?.cancel() }
        digestTask = Task { [weak self, weak tab] in
            guard let self, let tab, let web = tab.webView else { return }
            if let page = await self.readStructuredData(in: web, attempts: 2)?.digest, !Task.isCancelled {
                tab.digestCandidate = page
                self.digestCache[key] = page
                self.digestPanel.show(page, notice: nil)
                self.updateDigestButton(for: tab)
                return
            }
            guard !Task.isCancelled else { return }
            self.digestWithModel(tab: tab, key: key)
        }
    }

    /// The local model reads the page's text.
    func digestWithModel(tab: Tab, key: String) {
        if let reason = LocalModel.unavailableReason {
            digestPanel.showMessage("L'essentiel a besoin du modèle local d'Apple Intelligence. " + reason)
            return
        }
        digestPanel.showBusy("Lecture de la page par le modèle local… (environ 30 secondes)") { [weak self] in self?.digestTask?.cancel() }
        digestTask = Task { [weak self, weak tab] in
            guard let self, let web = tab?.webView else { return }
            guard let page = await web.callJSON(DigestScript.text, world: DigestScript.world, seconds: 15) as? [String: Any],
                  let text = page["text"] as? String, text.count > 200 else {
                if !Task.isCancelled { self.digestPanel.showMessage("Cette page ne contient pas assez de texte à résumer.") }
                return
            }
            let title = (page["title"] as? String) ?? ""
            do {
                let answer = try await LocalModel.respond(instructions: DigestPrompt.instructions, prompt: DigestPrompt.prompt(title: title, text: text), seconds: 150)
                guard !Task.isCancelled else { return }
                guard let raw = DigestParser.fromModel(answer, pageTitle: title) else {
                    self.digestPanel.showMessage("Je n'ai trouvé ni recette, ni étapes, ni verdict dans cette page.")
                    return
                }
                let (checked, dropped) = DigestValidator.checked(raw, against: text)
                guard checked.hasContent else { self.digestPanel.showMessage("Le modèle n'a rien produit qui se retrouve dans la page : rien n'est affiché."); return }
                self.digestCache[key] = checked
                if self.digestCache.count > 30 { self.digestCache.removeValue(forKey: self.digestCache.keys.first ?? key) }
                self.digestPanel.show(checked, notice: dropped > 0 ? "\(dropped) élément\(dropped > 1 ? "s" : "") du résumé, introuvable\(dropped > 1 ? "s" : "") dans la page, \(dropped > 1 ? "ont" : "a") été écarté\(dropped > 1 ? "s" : "")." : nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.digestPanel.showMessage(error as? LocalModel.Failure == .timedOut ? "Le modèle a mis trop de temps à répondre." : "Le résumé a échoué.")
            }
        }
    }

    // MARK: - IA locale

    /// Le panneau IA écarte le bord droit de la page de `pushed` points (0 : il la recouvre ou il est fermé).
    /// Dev : la carte de page (ce que lirait l'IA) de l'onglet, avec son poids estimé.
    func pageMapOp(_ op: String, _ tab: Tab) -> String {
        if op == "pagemapget" || op == "actget" { return pageMapResult }
        #if DEBUG
        if op == "groqkey" || op == "cloudkey" {
            // Dev (debug seulement) : range dans le Trousseau la clé écrite dans /tmp/oree-cloud-key.txt (ligne 1 : mistral ou groq ; ligne 2 : la clé), puis efface le fichier.
            let path = "/tmp/oree-cloud-key.txt"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            guard lines.count == 2, let provider = AIProvider(rawValue: lines[0]), provider.isCloud else { return "no key file" }
            let keychain = CloudKeychain(provider)
            return keychain.save(lines[1]) ? "saved \(provider.rawValue) (hasKey=\(keychain.hasKey))" : "keychain refused"
        }
        #endif
        pageMapResult = "pending"
        if op == "act" {
            Task { @MainActor in pageMapResult = await actOp(tab) }
            return "started (lire avec actget)"
        }
        Task { @MainActor in pageMapResult = await pageMapReport(tab) }
        return "started (lire avec pagemapget)"
    }

    /// Dev : exécute l'appel d'outil écrit dans /tmp/oree-ai-action.json, `{"name","arguments","profile","approve"}`. Sans `approve`, toute confirmation est refusée.
    func actOp(_ tab: Tab) async -> String {
        guard let web = tab.webView, let data = FileManager.default.contents(atPath: "/tmp/oree-ai-action.json"),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = spec["name"] as? String else { return "no action file" }
        let argsData = (try? JSONSerialization.data(withJSONObject: spec["arguments"] ?? [:])) ?? Data()
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        let action: AIAction
        do { action = try AIAction.parse(name: name, argumentsJSON: argsJSON) } catch { return "parse error: \(error)" }
        let approve = spec["approve"] as? Bool ?? false
        var asked = ""
        let result = await ActionExecutor.execute(action, in: web, profile: spec["profile"] as? [String: String] ?? [:]) { request in
            asked = request.title + " · " + request.rows.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + " · " + request.warning
            return approve
        }
        return "ok=\(result.ok) asked=\(result.askedConfirmation) msg=\(result.message)" + (asked.isEmpty ? "" : " question=\(asked)")
    }

    func pageMapReport(_ tab: Tab) async -> String {
        guard let web = tab.webView else { return "no web view" }
        let started = Date()
        guard let map = await PageMapScript.capture(web) else { return "pagemap failed" }
        let text = map.render()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return "tokens≈\(PageMap.estimatedTokens(text)) ms=\(ms)\n" + text
    }

    // MARK: - Add to Calendar

    /// ⌘K › « Ajouter au Calendrier » (or the calendar button): the page's own event data when it has some, else the local model looks for a
    /// date in the text. Always asks before anything leaves the app.
    @objc func addToCalendarAction() {
        guard let tab = activeTab, let web = tab.webView, TranslationPolicy.canTranslate(url: web.url) else { return }
        if let event = tab.eventCandidate { confirmAndAdd(event, page: web.url); return }
        if let reason = LocalModel.unavailableReason {
            showSimpleAlert("Ajouter au Calendrier a besoin du modèle local d'Apple Intelligence.", reason + " Sur les pages qui annoncent leur événement dans leurs données, il fonctionne sans.")
            return
        }
        eventTask?.cancel()
        noticePill.show(message: "Recherche d'une date dans la page…", button: "Annuler", seconds: 150) { [weak self] in self?.eventTask?.cancel(); self?.noticePill.dismiss() }
        eventTask = Task { [weak self] in
            guard let self else { return }
            let event = try? await self.findEventWithModel(in: web)
            guard !Task.isCancelled else { return }
            self.noticePill.dismiss()
            if let event { self.confirmAndAdd(event, page: web.url) }
            else { self.showSimpleAlert("Aucun événement trouvé", "Je n'ai pas trouvé de rendez-vous ou d'événement avec une date claire dans cette page.") }
        }
    }

    /// The local model reads the page's text and names its main event; the date is kept only if the page really mentions that day and month.
    func findEventWithModel(in web: WKWebView) async throws -> CalendarEvent? {
        guard let page = await web.callJSON(DigestScript.text, world: DigestScript.world, seconds: 15) as? [String: Any],
              let text = page["text"] as? String, text.count > 40 else { return nil }
        let now = Date()
        let answer = try await LocalModel.respond(instructions: EventPrompt.instructions(now: now), prompt: "Titre de la page : \((page["title"] as? String) ?? "")\n\nTexte de la page :\n\(DigestValidator.budget(text))", seconds: 150)
        guard var event = EventParser.fromModel(answer), EventValidator.isPlausible(event, pageText: text, now: now) else { return nil }
        if event.url == nil { event.url = web.url?.absoluteString }
        return event
    }

    /// Shows what will be added (title, when, where) and, on "Ajouter", opens Calendar with it.
    func confirmAndAdd(_ event: CalendarEvent, page: URL?) {
        var event = event
        if event.url == nil { event.url = page?.absoluteString }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        formatter.timeStyle = event.allDay ? .none : .short
        var lines = [formatter.string(from: event.start)]
        if let end = event.end, !event.allDay, Calendar.current.isDate(end, inSameDayAs: event.start) {
            let time = DateFormatter(); time.locale = formatter.locale; time.timeStyle = .short; time.dateStyle = .none
            lines[0] += " – " + time.string(from: end)
        }
        if let location = event.location { lines.append(location) }
        let alert = NSAlert()
        alert.messageText = event.title
        alert.informativeText = lines.joined(separator: "\n") + "\n\nCalendrier s'ouvre avec cet événement : vous choisissez le calendrier et confirmez."
        alert.addButton(withTitle: "Ajouter au Calendrier")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openInCalendar(event) }
        }
    }

    /// Writes the event as a .ics file and opens it with Calendar (which shows its own "add" window; the app never touches the calendars).
    func openInCalendar(_ event: CalendarEvent) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Oree-Events", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Événement-\(UUID().uuidString.prefix(8)).ics")
        guard (try? ICSBuilder.build(event).write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
        Task { try? await Task.sleep(for: .seconds(180)); try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Resume where you left off

    /// A report from the page: a video position and/or a reading position. Stored per page (never in a private tab).
    func handleResume(tab: Tab, json: String) {
        guard SettingsStore.shared.resumeEnabled, !tab.isPrivate,
              let data = json.data(using: .utf8), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = ResumePolicy.key(for: (report["u"] as? String).flatMap { URL(string: $0) }) else { return }
        let title = (report["ti"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
        let isCurrentPage = ResumePolicy.key(for: tab.webView?.url) == key      // a late report about a page already left
        if let video = report["video"] as? [String: Any] {
            if video["done"] as? Bool == true { try? resumeRepo.clearVideo(key: key) }
            else if let t = (video["t"] as? NSNumber)?.doubleValue, let d = (video["d"] as? NSNumber)?.doubleValue,
                    ResumePolicy.isWorthKeeping(videoSeconds: t, duration: d) {
                try? resumeRepo.update(key: key, title: title, video: (t, d))
            }
        }
        if let reading = report["reading"] as? [String: Any],
           let f = (reading["f"] as? NSNumber)?.doubleValue, let screens = (reading["screens"] as? NSNumber)?.doubleValue {
            if isCurrentPage { tab.readFraction = screens >= ResumePolicy.minimumScreens ? f : nil }
            if f > ResumePolicy.readRange.upperBound { try? resumeRepo.clearReading(key: key) }          // read to the end: done
            else if ResumePolicy.isWorthKeeping(readFraction: f, screens: screens) {
                try? resumeRepo.update(key: key, title: title, reading: (f, (reading["a"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
            if isCurrentPage, tab.id == activeTabID { updateReadingBar(for: tab) }
        }
    }

    /// Dev tooling (automation channel): what is stored for the page and what is on offer.
    func resumeReport(for tab: Tab) -> String {
        guard let key = ResumePolicy.key(for: tab.webView?.url) else { return "no key" }
        var parts = ["key=\(key)"]
        if let point = try? resumeRepo.point(for: key) {
            parts.append("video=\(point.videoSeconds.map { String($0) } ?? "-")")
            parts.append("read=\(point.readFraction.map { String($0) } ?? "-")")
            parts.append("anchor=\(point.anchor ?? "-")")
        } else {
            parts.append("point=none")
        }
        parts.append("notice=\(noticePill.visibleMessage ?? "(none)")")
        parts.append("bar=\(tab.readFraction.map { String($0) } ?? "-")")
        return parts.joined(separator: " ")
    }

    /// The thin line at the bottom of the page: how far down the user is in a long article.
    func updateReadingBar(for tab: Tab?) {
        guard let tab, let fraction = tab.readFraction, SettingsStore.shared.resumeEnabled else { readingBar.isHidden = true; return }
        readingBar.isHidden = false
        readingBar.fill = Theme.accent
        readingBarWidth?.constant = contentContainer.bounds.width * CGFloat(min(max(fraction, 0), 1))
    }

    /// On a fresh visit to a page the user had left half-way, offers to go back to the video position or to the paragraph.
    func offerResume(for tab: Tab) {
        guard SettingsStore.shared.resumeEnabled, !tab.isPrivate, !tab.isAwaitingWakeReveal,
              tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other,
              let key = ResumePolicy.key(for: tab.webView?.url), let point = try? resumeRepo.point(for: key),
              let offer = ResumePolicy.offer(for: point) else { return }
        let message: String, call: (body: String, arguments: [String: Any])
        switch offer {
        case .video(let seconds):
            message = "Reprendre la vidéo à \(ResumePolicy.clock(seconds)) ?"
            call = ResumeScript.goCall(seconds: seconds, fraction: nil, anchor: nil)
        case .reading(let percent):
            message = "Reprendre la lecture (\(percent) %) ?"
            call = ResumeScript.goCall(seconds: nil, fraction: point.readFraction, anchor: point.anchor)
        }
        noticePill.show(message: message, button: "Reprendre", seconds: 12) { [weak tab] in
            guard let web = tab?.webView else { return }
            Task { _ = await web.safeCall(call.body, arguments: call.arguments, world: ResumeScript.world) }
        }
    }

    // MARK: - Night mode

    var appearanceIsDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func nightConfig() -> NightScript.Config {
        let settings = SettingsStore.shared
        return .init(enabled: NightPolicy.isActive(mode: settings.nightMode, appearanceIsDark: appearanceIsDark),
                     excluded: settings.nightExcludedHosts, native: settings.nightNativeHosts)
    }

    /// Everything that should make the pages re-read the night settings.
    func nightSignature() -> [String] {
        let settings = SettingsStore.shared
        return [settings.nightMode.rawValue, appearanceIsDark ? "dark" : "light"] + settings.nightExcludedHosts + ["|"] + settings.nightNativeHosts
    }

    /// Hands the current night settings to every tab: future pages through their scripts, the page on screen at once.
    func refreshNightMode() {
        let config = nightConfig()
        for tab in tabs {
            tab.setUserScripts(userScripts(for: tab.currentURL))
            if let web = tab.webView {
                Task { _ = await web.safeEvaluate(NightScript.source(config), world: NightScript.world) }
            }
        }
        if let tab = activeTab { updateNightButton(for: tab) }
    }

    /// The moon next to the address: visible while night mode is on; pressed = this site is being darkened.
    func updateNightButton(for tab: Tab) {
        let settings = SettingsStore.shared
        let host = tab.webView?.url?.host ?? tab.currentURL?.host
        setRelevant(.night, settings.nightMode != .off && TranslationPolicy.canTranslate(url: tab.webView?.url ?? tab.currentURL))
        let active = NightPolicy.isActive(mode: settings.nightMode, appearanceIsDark: appearanceIsDark)
        let excluded = NightPolicy.contains(host, in: settings.nightExcludedHosts)
        nightButton.isActive = active && !excluded
        let label = !active ? "Mode nuit en attente (le Mac est en mode clair)" : excluded ? "Assombrir ce site" : "Laisser ce site clair"
        nightButton.setAccessibilityLabel(label)
        nightButton.toolTip = label
    }

    /// One click: leave this site light, or darken it again.
    @objc func toggleNightForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host ?? tab.currentURL?.host else { return }
        let settings = SettingsStore.shared
        settings.nightExcludedHosts = NightPolicy.contains(host, in: settings.nightExcludedHosts)
            ? NightPolicy.removing(host, from: settings.nightExcludedHosts)
            : NightPolicy.adding(host, to: settings.nightExcludedHosts)
        lastNight = nightSignature()
        refreshNightMode()
    }

    func setNightMode(_ mode: NightMode) {
        SettingsStore.shared.nightMode = mode
        lastNight = nightSignature()
        refreshNightMode()
    }

    // MARK: - Page translation

    /// Keeps the translate button in step with the active tab's translator, and starts recognizing the page language.
    func bindTranslator(of tab: Tab) {
        updateNightButton(for: tab)
        updateReadingBar(for: tab)
        updateDigestButton(for: tab)
        tab.onAddressCopied = { [weak self] address in
            self?.noticePill.show(message: "Adresse copiée", button: "Ouvrir dans Plans") {
                if let url = CopyPolicy.mapsURL(for: address) { NSWorkspace.shared.open(url) }
            }
        }
        guard PageTranslator.isAvailable else { return }
        tab.translator.onChange = { [weak self, weak tab] in
            guard let self, let tab, tab.id == self.activeTabID else { return }
            self.updateTranslateButton(for: tab)
        }
        tab.translator.onFailure = { [weak self] failure in self?.showTranslationFailure(failure) }
        tab.translator.detectIfNeeded()
        updateTranslateButton(for: tab)
    }

    func updateTranslateButton(for tab: Tab) {
        let translator = tab.translator
        setRelevant(.translate, translator.shouldOffer && TranslationPolicy.canTranslate(url: tab.webView?.url))
        translateButton.isActive = translator.state != .idle
        translateButton.ringIndeterminate = translator.isWorking
        let label = translator.state == .idle ? "Traduire la page" : "Afficher la page d'origine"
        translateButton.setAccessibilityLabel(label)
        translateButton.toolTip = label
    }

    /// Translates the active page, or puts the original back when it is already translated.
    @objc func translatePageAction() {
        guard PageTranslator.isAvailable, let tab = activeTab else { return }
        bindTranslator(of: tab)
        tab.translator.toggle()
    }

    /// Asks the system to install the fast translation model for the current page's language (its own download sheet appears).
    @objc func downloadFastTranslationAction() { downloadFastTranslationAction(thenTranslate: false) }

    func downloadFastTranslationAction(thenTranslate: Bool) {
        guard PageTranslator.isAvailable, let window, let tab = activeTab else { return }
        guard let source = tab.translator.pageLanguage, source != "und" else {
            showTranslationFailure(.unknownLanguage)
            return
        }
        TranslationDownload.requestFastModel(source: source, in: window) { [weak tab] error in
            if error == nil, thenTranslate { tab?.translator.translate() }
        }
    }

    func showTranslationFailure(_ failure: PageTranslator.Failure) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch failure {
        case .sameLanguage(let name):
            alert.messageText = "Cette page est déjà en \(name)."
        case .unknownLanguage:
            alert.messageText = "Langue de la page non reconnue."
            alert.informativeText = "Il n'y a pas assez de texte pour savoir dans quelle langue elle est écrite."
        case .unsupported(let source, let target):
            alert.messageText = "Traduction impossible"
            alert.informativeText = "Le système ne sait pas traduire de « \(source) » vers « \(target) »."
        case .notInstalled(let source, let target):
            alert.messageText = "Langues à télécharger"
            alert.informativeText = "Pour traduire de « \(source) » vers « \(target) », le système doit d'abord télécharger ces langues."
            alert.addButton(withTitle: "Télécharger")
            alert.addButton(withTitle: "Annuler")
        case .failed(let message):
            alert.messageText = "La traduction a échoué"
            alert.informativeText = message
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if case .notInstalled = failure, response == .alertFirstButtonReturn { self.downloadFastTranslationAction(thenTranslate: true) }
        }
    }

    func recentHistoryForMenu(limit: Int = 15) -> [HistoryEntry] {
        (try? historyRepo.recent(limit: limit)) ?? []
    }

    func allBookmarksForMenu() -> [Bookmark] {
        (try? bookmarkRepo.all()) ?? []
    }

    // MARK: Learned site profiles

    func siteProfile(forHost host: String?) -> SiteProfile? {
        guard SettingsStore.shared.learnSiteMemory, let host else { return nil }
        if let cached = siteProfileCache[host] { return cached }
        let profile = try? siteMemoryRepo.profile(host: host)
        siteProfileCache[host] = .some(profile)
        return profile
    }

    /// Every pass, remember how much each open (non-private, settled) site is using.
    func recordSiteSamples(_ reading: MemoryReading) {
        guard SettingsStore.shared.learnSiteMemory else { return }
        let tabsPerProcess = Dictionary(grouping: reading.processOfTab.values, by: { $0 }).mapValues(\.count)
        for tab in tabs where !tab.isPrivate && tab.webView?.isLoading == false {
            guard let host = SiteMemoryPolicy.normalizedHost(tab.currentURL),
                  let pid = reading.processOfTab[tab.id], let bytes = reading.bytesByProcess[pid] else { continue }
            let megabytes = Double(bytes) / 1_048_576 / Double(max(tabsPerProcess[pid] ?? 1, 1))
            try? siteMemoryRepo.record(host: host, megabytes: megabytes)
            siteProfileCache[host] = nil
            if SiteMemoryPolicy.isHeavy(siteProfile(forHost: host)), let profile = siteProfile(forHost: host) {
                tab.tabButton.toolTip = "Site gourmand : ~\(Int(profile.averageMB)) Mo en moyenne"
            }
        }
    }

    /// Opening a site known to be heavy: free up room *before* it loads, so the Mac doesn't start swapping.
    func makeRoom(forNavigationTo url: URL, in tab: Tab) async {
        guard SettingsStore.shared.learnSiteMemory, SettingsStore.shared.memoryBudgetMB >= 0,
              let host = SiteMemoryPolicy.normalizedHost(url),
              case let predicted = SiteMemoryPolicy.predictedBytes(for: siteProfile(forHost: host)), predicted > 0 else { return }
        let setting = SettingsStore.shared.memoryBudgetMB
        let budget = setting == 0 ? MemoryBudget.automaticBudgetBytes() : UInt64(setting) * 1_048_576
        let reading = measureTabMemory()
        // The page being replaced stops counting once the new one loads.
        let currentOfThisTab = tab.webProcessID.flatMap { reading.bytesByProcess[$0] } ?? 0
        let projected = reading.total - min(reading.total, currentOfThisTab) + predicted
        guard projected > budget else { return }
        let slept = await sleepTabs(toReach: budget > predicted ? budget - predicted + currentOfThisTab : currentOfThisTab, reading: reading, minimumIdle: 5)
        if slept > 0 {
            Log.tabs.notice("Making room for \(host, privacy: .public) (~\(predicted / 1_048_576) MB expected): put \(slept) tab(s) to sleep")
        }
    }

    struct MemoryReading {
        var total: UInt64
        var bytesByProcess: [Int32: UInt64]
        var processOfTab: [UUID: Int32]
    }

    func measureTabMemory() -> MemoryReading {
        var bytesByProcess: [Int32: UInt64] = [:]
        var processOfTab: [UUID: Int32] = [:]
        for tab in tabs where tab.webView != nil {
            guard let pid = tab.webProcessID, let bytes = MemoryBudget.footprint(ofProcess: pid) else { continue }
            bytesByProcess[pid] = bytes
            processOfTab[tab.id] = pid
        }
        return MemoryReading(total: bytesByProcess.values.reduce(0, +), bytesByProcess: bytesByProcess, processOfTab: processOfTab)
    }

    /// What the task manager shows now: every tab of every window with what its page costs.
    func taskManagerSnapshot() -> (snapshot: TaskManagerRows.Snapshot, appBytes: UInt64?) {
        let reading = measureTabMemory()
        let infos = tabs.map { tab in
            TaskManagerRows.TabInfo(id: tab.id, title: tab.displayTitle, host: tab.badgeHost, processID: tab.webView == nil ? nil : reading.processOfTab[tab.id],
                                    isSleeping: tab.isSuspended, isFrozen: tab.isFrozen, playsAudio: tab.audioState == .playing, isActive: tab.id == activeTabID)
        }
        return (TaskManagerRows.snapshot(tabs: infos, bytesByProcess: reading.bytesByProcess), MemoryBudget.footprint(ofProcess: getpid()))
    }

    /// ⌥⌘T — the task manager window.
    @objc func showTaskManager() {
        if taskManager == nil {
            let manager = TaskManagerWindowController()
            manager.provider = { [weak self] in self?.taskManagerSnapshot() ?? (TaskManagerRows.snapshot(tabs: [], bytesByProcess: [:]), nil) }
            manager.onSelect = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.selectTab(tab) } }
            manager.onSleep = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.sleepTab(tab) } }
            manager.onClose = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.closeTab(tab) } }
            taskManager = manager
        }
        taskManager?.show()
    }

    /// JavaScript garbage collection plus WebKit's in-memory caches. At most once a minute:
    /// the collection runs in every web process, so it must not become a constant background cost.
    @discardableResult
    func releaseJavaScriptMemory(reason: String) -> Bool {
        guard Date().timeIntervalSince(lastGarbageCollection) > 60,
              let pool = tabs.compactMap({ $0.webView?.configuration.processPool }).first,
              WebKitTuning.collectJavaScriptGarbage(in: pool) else { return false }
        lastGarbageCollection = Date()
        WebKitTuning.purgeMemoryCaches()
        Log.tabs.notice("Memory cleanup (\(reason, privacy: .public))")
        return true
    }

    /// A tab that has been out of sight for a minute gets its JavaScript memory cleaned, once per absence.
    func cleanHiddenTabsIfDue() async {
        guard SettingsStore.shared.backgroundCleanup else { return }
        let now = Date()
        let due = tabs.filter { tab in
            guard tab.webView != nil, !isOnScreen(tab), now.timeIntervalSince(tab.lastActiveDate) >= 60 else { return false }
            return tab.lastCleanup.map { $0 < tab.lastActiveDate } ?? true
        }
        guard !due.isEmpty, releaseJavaScriptMemory(reason: "\(due.count) hidden tab(s)") else { return }
        for tab in due { tab.lastCleanup = now }
    }
}
