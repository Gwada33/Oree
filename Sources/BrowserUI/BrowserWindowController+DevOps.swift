#if DEBUG
import AppKit
import WebKit
import BrowserCore
import BrowserStorage
import DownloadKit
import OreeObjC
import MediaPlayer
import SwiftUI

/// Operations for the development channel (`scripts/ui.sh tab <op> N`, see AutomationServer). Debug builds only: a shipped Orée has no such door.
extension BrowserWindowController {
    // MARK: Development operations (automation channel)

    func devOp(_ op: String, _ tab: Tab) -> String? {
        switch op {
        case "media":
            return "\(nowPlaying.summary) | tab=\(mediaTabID == tab.id ? "this" : "other") | out=\(audioRoute.output.name) bt=\(audioRoute.output.bluetooth)"
        case "mediatoggle": mediaCommand(tab, "toggle"); return "ok"
        case "qr":
            guard let url = tab.webView?.url, let image = PrivacyTools.qrImage(for: url.absoluteString) else { return "no qr" }
            return "qr decodes to: \(PrivacyTools.decodeQR(image) ?? "(unreadable)") | size=\(Int(image.size.width))"
        case "minfont":
            // Sets the minimum text size on this tab only (not in the saved settings) and reports the height of the page's #t element.
            let size = Int((try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            tab.webView?.configuration.preferences.minimumFontSize = CGFloat(size)
            return "minimumFontSize=\(tab.webView?.configuration.preferences.minimumFontSize ?? -1)"
        case "tasks":
            let (snapshot, app) = taskManagerSnapshot()
            let lines = snapshot.rows.map { "\($0.title.prefix(24))|\(TaskManagerRows.memory($0.bytes))|\($0.state.rawValue)|shared=\($0.processTabs)" }
            return "total=\(TaskManagerRows.memory(snapshot.totalBytes)) app=\(app.map(TaskManagerRows.memory) ?? "-") saved=\(snapshot.savedBytes.map(TaskManagerRows.memory) ?? "-") :: " + lines.joined(separator: " ; ")
        case "taskwindow":
            showTaskManager()
            guard let view = taskManager?.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no window" }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/oree-taskmanager.png"))
            return "window shown, picture written"
        case "speak":
            readPageAloud()
            return "asked"
        case "speaking": return "speaking=\(PageSpeech.shared.isSpeaking)"
        case "speakstop": PageSpeech.shared.stop(); return "stopped"
        case "share":
            guard let url = tab.webView?.url else { return "no page" }
            let services = NSSharingService.sharingServices(forItems: [url])
            return "services=\(services.count) first=\(services.first?.title ?? "-")"
        case "energy":
            let mode = SettingsStore.shared.energyMode
            let active = EnergyPolicy.isActive(mode: mode, systemLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            let timing = lifecycleTiming()
            return "mode=\(mode.rawValue) systemLowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) active=\(active) freezeAfter=\(timing.freezeAfter) sleepAfter=\(timing.sleepAfter)"
        case "tabpreview":
            // Builds the card for the first tab that is not the one in front and writes its picture (the card is not shown: no pointer in a test).
            guard let other = tabs.first(where: { $0.id != activeTabID }) else { return "no other tab" }
            Task { @MainActor in
                let image = await other.previewImage()
                let row = self.taskManagerSnapshot().snapshot.rows.first { $0.id == other.id }
                let card = TabPreviewCard(image: image, title: other.displayTitle, host: other.badgeHost, status: row.map { "\($0.state.rawValue) · \(TaskManagerRows.memory($0.bytes))" } ?? "")
                card.frame = NSRect(origin: .zero, size: card.fittingSize)
                card.layoutSubtreeIfNeeded()
                if let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
                    card.cacheDisplay(in: card.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/oree-tabpreview.png"))
                }
                try? "image=\(image != nil) size=\(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-")".write(toFile: "/tmp/oree-tabpreview.txt", atomically: true, encoding: .utf8)
            }
            return "asked"
        case "recent": return recentTabIDs.compactMap { id in tabs.firstIndex { $0.id == id } }.map(String.init).joined(separator: ",")
        case "recentgo": selectRecentTab(); return "active=\(tabs.firstIndex { $0.id == activeTabID } ?? -1)"
        case "calc":
            let text = (try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8)) ?? ""
            return Calculator.evaluate(text).map(Calculator.format) ?? "(not a calculation)"
        case "clearcheck":
            // Clears a throw-away store (never the real one) to prove that the function empties cookies and storage.
            Task { @MainActor in
                let store = WKWebsiteDataStore.nonPersistent()
                let cookie = HTTPCookie(properties: [.domain: "exemple.test", .path: "/", .name: "k", .value: "v", .expires: Date().addingTimeInterval(3600)])!
                await store.httpCookieStore.setCookie(cookie)
                let before = await store.httpCookieStore.allCookies().count
                await PrivacyTools.clearSiteData(in: store)
                let after = await store.httpCookieStore.allCookies().count
                try? "before=\(before) after=\(after)".write(toFile: "/tmp/oree-clearcheck.txt", atomically: true, encoding: .utf8)
            }
            return "started"
        case "mediakey":
            // Presses a media key's action (toggle by default), and reports what Control Center would show.
            MediaKeys.shared.perform(.toggle)
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            return "title=\(info?[MPMediaItemPropertyTitle] as? String ?? "-") rate=\(info?[MPNowPlayingInfoPropertyPlaybackRate] ?? "-") state=\(MPNowPlayingInfoCenter.default().playbackState.rawValue)"
        case "mediarate": mediaCommand(tab, "rate", MediaPolicy.nextRate(after: tab.media?.rate ?? 1)); return "ok"
        case "mediaskip": mediaCommand(tab, "skip", 10); return "ok"
        case "mediaseek": mediaCommand(tab, "seek", (tab.media?.duration ?? 0) / 2); return "ok"
        case "mediapip":
            mediaCommand(tab, "pip")
            let can = (tab.webView?.value(forKey: "_canTogglePictureInPicture") as? Bool).map(String.init) ?? "nil"
            return "pip native can=\(can) active=\(tab.pictureInPictureActive)"
        case "spellprobe":
            // A correction panel for a view that is not in any window: the kind of request that made AppKit raise.
            NSSpellChecker.shared.showCorrectionIndicator(of: .default, primaryString: "bonjour", alternativeStrings: ["bonsoir"],
                                                         forStringIn: NSRect(x: 10, y: 10, width: 40, height: 14), view: NSView(), completionHandler: nil)
            return "probe survived"
        case "pdf":
            guard let web = tab.webView else { return "no web view" }
            let target = URL(fileURLWithPath: "/tmp/oree-page.pdf")
            Task { @MainActor in
                if let data = await self.makePDF(of: web) { try? data.write(to: target) }
            }
            return "pdf requested"
        case "addr":
            // Types the text of /tmp/oree-address.txt in the address bar, as if the user pressed return on it.
            guard let text = try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8) else { return "no file" }
            load(urlString: text, in: tab)
            return "loaded"
        case "bookmarkall": bookmarkAllTabs(); return "done"
        case "exportbm":
            let items = ((try? bookmarkRepo.all()) ?? []).map { BookmarkExport.Item(title: $0.title, url: $0.url, folder: $0.spaceIndex.flatMap { spaces.indices.contains($0) ? spaces[$0].name : nil } ?? "Tous les espaces", added: $0.createdAt) }
            try? BookmarkExport.html(items).write(toFile: "/tmp/oree-bookmarks.html", atomically: true, encoding: .utf8)
            return "exported \(items.count)"
        case "complete":
            guard let text = try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8) else { return "no file" }
            return inlineCompletion(for: text) ?? "(nothing)"
        case "dialog":
            guard let alert = activeWebDialog else { return "(none)" }
            return "\(alert.messageText) | \(alert.informativeText.replacingOccurrences(of: "\n", with: " / ")) | buttons=\(alert.buttons.map(\.title)) | field=\(alert.accessoryView is NSTextField) fields=\((alert.accessoryView as? NSStackView)?.arrangedSubviews.count ?? 0)"
        case "dialogok", "dialogcancel":
            // Answers the open dialog like a click would: first button = OK, second = Annuler. A prompt gets /tmp/oree-address.txt as its text.
            guard let alert = activeWebDialog else { return "(none)" }
            let supplied = (try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8)) ?? ""
            if let field = alert.accessoryView as? NSTextField { field.stringValue = supplied }
            if let stack = alert.accessoryView as? NSStackView {           // a username and password request: "user" then "password", one per line
                let parts = supplied.components(separatedBy: "\n")
                for (view, text) in zip(stack.arrangedSubviews, parts) { (view as? NSTextField)?.stringValue = text }
            }
            let index = op == "dialogok" ? 0 : 1
            guard alert.buttons.indices.contains(index) else { return "no such button" }
            alert.buttons[index].performClick(nil)
            return "pressed \(alert.buttons[index].title)"
        case "downloads": return downloads.items.map { "\($0.name)|\($0.phase)|\($0.error ?? "-")" }.joined(separator: " ; ")
        case "quit": DispatchQueue.main.async { NSApp.terminate(nil) }; return "quitting"
        case "closeextra":
            // Closes the last extra window the way the user does (its red button).
            guard let other = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).last(where: { $0.isSecondary }) else { return "no extra window" }
            other.window?.close()
            return "closed"
        case "newwindow": _ = Self.newWindowHandler?(true); return "requested"
        case "detach": detachToNewWindow(tab); return "detached"
        case "setsize":
            guard var frame = window?.frame else { return "no window" }
            frame.size = NSSize(width: 420, height: 640); window?.setFrame(frame, display: true)
            return "set"
        case "constraints":
            var out = ""
            func walk(_ v: NSView) { for c in v.constraints where c.isActive && c.priority.rawValue >= 750 && (c.constant == 808 || c.constant == 800 || c.constant == 480) { out += "owner=\(type(of: v)) first=\(String(describing: c.firstItem).prefix(40)) attr=\(c.firstAttribute.rawValue) second=\(String(describing: c.secondItem).prefix(40)) k=\(c.constant) rel=\(c.relation.rawValue) p=\(c.priority.rawValue) id=\(c.identifier ?? "-")\n" }; v.subviews.forEach(walk) }
            if let content = window?.contentView { walk(content) }
            return out
        case "size": return "\(window?.frame.size ?? .zero) isMini=\(isMini)"
        case "taborder": return tabs.map { $0.currentURL?.query ?? "-" }.joined(separator: ",") + " frames=" + tabs.map { "\(Int($0.tabButton.frame.minY))" }.joined(separator: ",") + " transforms=" + tabs.map { ($0.tabButton.layer?.transform.m42 ?? 0) == 0 ? "0" : "x" }.joined()
        case "fewtabs":
            for i in 1..<5 { newTab(urlString: "https://example.com/?n=\(i)", isPrivate: false) }
            return "tabs=\(tabs.count)"
        case "closeat": closeTab(tab); return "closed"
        case "archive":
            // Archives every tab but the active one as if it had been idle for 40 days, then reports the archive (needs the setting on: HB_ARCHIVE_DAYS).
            for t in tabs where t.id != activeTabID { t.lastActiveDate = Date().addingTimeInterval(-40 * 86_400) }
            archiveStaleTabs()
            return "tabs=\(tabs.count) archive=\(Self.archiveStore.load().count)"
        case "notes":
            // Opens the pad, types a first line, appends a selection, saves, and reports what the database holds.
            openNotes(append: nil)
            notesView?.append("Première ligne de test")
            notesView?.append("Texte copié")
            notesView?.saveNow()
            if let v = notesView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/oree-notes.png")) }
            return "notes=\((try? noteRepo.all().count) ?? -1) title=\(notesView?.note.title ?? "-") body=\(notesView?.note.body.replacingOccurrences(of: "\n", with: "|") ?? "-")"
        case "webpanel":
            // Adds a panel for HB_PANEL_URL, shows it, reports what the list holds.
            guard let url = WebPanels.normalize(ProcessInfo.processInfo.environment["HB_PANEL_URL"] ?? "example.com") else { return "bad url" }
            let entry = WebPanelEntry(name: WebPanels.defaultName(for: url), url: url.absoluteString)
            SettingsStore.shared.webPanels = WebPanels.adding(entry, to: SettingsStore.shared.webPanels)
            webPanel.show(entry)
            return "panels=\(SettingsStore.shared.webPanels.count) shown=\(webPanel.isShown) actions=\(webPanelActions().map(\.0).joined(separator: " | "))"
        case "webpanelreport": return "shown=\(webPanel.isShown) current=\(webPanel.current?.name ?? "-") frame=\(webPanel.frame)"
        case "webpanelremove":
            if let entry = SettingsStore.shared.webPanels.first { removeWebPanel(entry) }
            return "panels=\(SettingsStore.shared.webPanels.count)"
        case "manytabs":
            for i in 0..<30 { newTab(urlString: "https://example.com/?n=\(i)", isPrivate: false) }
            return "tabs=\(tabs.count)"
        case "stripreport":
            tabStrip.layoutSubtreeIfNeeded()
            let buttons = tabStrip.tabsStack.arrangedSubviews.compactMap { $0 as? TabButtonView }
            let shown = buttons.filter { !$0.isHidden }
            return "tabs=\(buttons.count) shown=\(shown.count) overflow=\(!tabStrip.overflowButton.isHidden) activeShown=\(activeTab.map { !$0.tabButton.isHidden } ?? false) stripW=\(Int(tabStrip.tabsStack.frame.width)) hostW=\(Int(tabStrip.frame.width)) plusX=\(Int(tabStrip.newTabButton.frame.maxX))"
        case "overflowmenu": showAllTabsMenu(); return "menu"
        case "railreport":
            return "rail=\(spaceRail.frame) compactMode=\(SettingsStore.shared.sidebarMode)"
        case "peek":
            guard let url = URL(string: ProcessInfo.processInfo.environment["HB_PEEK_URL"] ?? "https://example.com") else { return "bad url" }
            peek(url, from: tab); return "peek"
        case "peekreport": return "shown=\(peekPanel.isShown) url=\(peekPanel.currentURL?.absoluteString ?? "-")"
        case "peekshot": Task { @MainActor in await self.peekPanel.snapshot(to: "/tmp/oree-peek.png") }; return "asked"
        case "peekclose": peekPanel.close(); return "closed"
        case "peektab": if let url = peekPanel.currentURL { newTab(urlString: url.absoluteString, isPrivate: false); peekPanel.close() }; return "tabs=\(tabs.count)"
        case "mini":
            guard let url = tab.currentURL else { return "no url" }
            openMiniWindow(url: url); return "mini"
        case "minireport":
            let minis = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.isMini && $0.window?.isVisible == true }
            return "n=\(minis.count) " + minis.map { "level=\($0.window?.level.rawValue ?? -1) size=\(Int($0.window?.frame.width ?? 0))x\(Int($0.window?.frame.height ?? 0)) sidebarHidden=\($0.tabColumn?.isHidden ?? false) url=\($0.activeTab?.currentURL?.absoluteString ?? "-")" }.joined(separator: " ; ")
        case "minitomain":
            guard let mini = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).last(where: \.isMini) else { return "no mini" }
            mini.moveMiniToMainWindow(); return "moved"
        case "windows":
            let all = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            return all.map { "\($0.isSecondary ? "secondary" : "primary") tabs=\($0.tabs.count) active=\($0.activeTab?.currentURL?.absoluteString ?? "-")" }.joined(separator: " ; ")
        case "wload":
            // Loads the address of /tmp/oree-address.txt in the active tab of the last secondary window.
            guard let other = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).last(where: { $0.isSecondary }),
                  let tab = other.activeTab, let text = try? String(contentsOfFile: "/tmp/oree-address.txt", encoding: .utf8) else { return "no secondary window" }
            other.load(urlString: text, in: tab)
            return "loaded"
        case "wmarker":
            guard let other = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).last(where: { $0.isSecondary }), let web = other.activeTab?.webView else { return "no secondary window" }
            Task { @MainActor in
                let value = await web.safeEvaluate("String(window.__marker) + ' / ' + document.title", world: .page)
                try? "\(String(describing: value))".write(toFile: "/tmp/oree-marker.txt", atomically: true, encoding: .utf8)
            }
            return "asked"
        case "wchain":
            // The ⌘T of a window in front must open its own tab: follow the responder chain from inside the last secondary window.
            guard let other = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).last(where: { $0.isSecondary }),
                  let responder = other.window?.firstResponder else { return "no secondary window" }
            return "handled=\(responder.tryToPerform(#selector(BrowserWindowController.newTabAction), with: nil))"
        case "zoomin": zoomInAction(); return "zoom=\(tab.webView?.pageZoom ?? 0)"
        case "zoomout": zoomOutAction(); return "zoom=\(tab.webView?.pageZoom ?? 0)"
        case "zoomreset": zoomResetAction(); return "zoom=\(tab.webView?.pageZoom ?? 0)"
        case "zoomget": return "zoom=\(tab.webView?.pageZoom ?? 0) magnification=\(tab.webView?.allowsMagnification ?? false) memory=\(SettingsStore.shared.siteZoom)"
        case "reader": toggleReaderMode(); return "toggled"
        case "siteinfo": showSiteInfo(); return "shown"
        case "siteinfotext":
            func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
            guard let root = siteInfoPopover?.contentViewController?.view else { return "no popover" }
            return texts(root).filter { !$0.isEmpty }.joined(separator: " | ")
        case "source": viewPageSource(); return "source requested"
        case "printop":
            // The print operation exists and lays the page out (it is not shown: no panel in an automated run).
            guard let web = tab.webView else { return "no web view" }
            let operation = web.printOperation(with: NSPrintInfo.shared)
            operation.view?.frame = web.bounds
            return "print operation view=\(operation.view != nil) frame=\(operation.view?.frame.size ?? .zero)"
        case "invisstart": startInvisibilityRecording(); return "recording"
        case "invisstop": return stopInvisibilityRecording()
        default: return nil
        }
    }
}
#endif
