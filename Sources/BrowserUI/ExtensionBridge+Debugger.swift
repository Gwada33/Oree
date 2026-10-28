import AppKit
import WebKit
import BrowserCore

/// chrome.debugger : le protocole de débogage de Chrome (CDP), traduit en actions sur un onglet d'Orée.
/// Pris en charge : Runtime.evaluate, Page.captureScreenshot / navigate / reload / bringToFront / getFrameTree / getLayoutMetrics / addScriptToEvaluateOnNewDocument,
/// Input.dispatchMouseEvent / dispatchKeyEvent / insertText, les « enable » et Emulation.setFocusEmulationEnabled (sans effet nécessaire).
/// Événements : Page.frameNavigated / loadEventFired, Network.requestWillBeSent / responseReceived / loadingFailed (le document de la page, pas les sous-requêtes),
/// Runtime.consoleAPICalled / exceptionThrown. Tout le reste échoue avec un message clair.
@MainActor
final class DebuggerSessions {
    struct Attachment { let tabId: Int; let contextID: String; let name: String }
    var attachments: [ObjectIdentifier: Attachment] = [:]
    var scripts: [String: WKUserScript] = [:]
    var lastStatus: [ObjectIdentifier: Int] = [:]
    var requestCounter = 0
}

/// Reçoit console.* et les erreurs de la page.
final class DebuggerConsoleHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        nonisolated(unsafe) let payload = body
        mainActorNow { Tab.tabsByWebView.object(forKey: message.webView).flatMap { tab in tab.owner?.extensionManager.bridge.consoleEvent(tab, payload) } }
    }
}

extension ExtensionBridge {
    static let consoleHookName = "oreeDebugConsole"
    private static let consoleHook = """
    (() => { if (window.__oreeConsoleHook) return; window.__oreeConsoleHook = true;
      const post = (m) => { try { window.webkit.messageHandlers.oreeDebugConsole.postMessage(m); } catch (e) {} };
      const show = (a) => { try { return typeof a === 'string' ? a : (a instanceof Error ? (a.stack || String(a)) : JSON.stringify(a)); } catch (e) { return String(a); } };
      for (const type of ['log', 'info', 'warn', 'error', 'debug']) { const o = console[type]; console[type] = function (...args) { post({ k: 'console', type, args: args.map(show) }); return o.apply(this, args); }; }
      addEventListener('error', (e) => post({ k: 'exception', text: e.message, line: e.lineno || 0, column: e.colno || 0, url: e.filename || '', stack: e.error && e.error.stack || '' }));
      addEventListener('unhandledrejection', (e) => post({ k: 'exception', text: 'Uncaught (in promise) ' + show(e.reason), line: 0, column: 0, url: '', stack: '' }));
    })();
    """

    // MARK: Tabs

    /// L'onglet que l'extension désigne : l'extension envoie sa place dans la fenêtre (celle que nous lui avons donnée) et son adresse.
    func tab(from target: [String: Any]) -> Tab? {
        guard let window else { return nil }
        let tabs = window.extensionTabs
        let url = target["url"] as? String ?? ""
        if let index = target["index"] as? Int, tabs.indices.contains(index) {
            let candidate = tabs[index]
            if url.isEmpty || candidate.currentURL?.absoluteString == url || candidate.webView?.url?.absoluteString == url { return candidate }
        }
        return tabs.first { $0.currentURL?.absoluteString == url && !url.isEmpty } ?? ((target["index"] as? Int).flatMap { tabs.indices.contains($0) ? tabs[$0] : nil })
    }

    func debuggerMethods() -> [String: Method] {
        [
            "debugger.attach": Method(permission: "debugger") { [self] a, context in
                guard let target = a["target"] as? [String: Any], let tab = tab(from: target), let tabId = target["tabId"] as? Int else { throw Failure(message: "Onglet introuvable.") }
                if tab.isPrivate { throw Failure(message: "Les onglets privés ne peuvent pas être déboguées.") }
                let key = ObjectIdentifier(tab)
                if let existing = debug.attachments[key], existing.contextID != context.uniqueIdentifier { throw Failure(message: "Another debugger is already attached to the tab with id: \(tabId).") }
                if debug.attachments[key] != nil { throw Failure(message: "Another debugger is already attached to the tab with id: \(tabId).") }
                let name = context.webExtension.displayName ?? "Une extension"
                debug.attachments[key] = .init(tabId: tabId, contextID: context.uniqueIdentifier, name: name)
                installConsoleHook(on: tab)
                window?.noticePill.show(message: "« \(name) » contrôle cet onglet.", button: "Arrêter", seconds: 8) { [weak self, weak tab] in if let tab { self?.detach(tab, reason: "canceled_by_user") } }
                return NSNull()
            },
            "debugger.detach": Method(permission: "debugger") { [self] a, _ in
                guard let target = a["target"] as? [String: Any], let tab = tab(from: target), debug.attachments[ObjectIdentifier(tab)] != nil else { throw Failure(message: "Debugger is not attached to the tab.") }
                debug.attachments[ObjectIdentifier(tab)] = nil; return NSNull()
            },
            "debugger.sendCommand": Method(permission: "debugger") { [self] a, context in
                guard let target = a["target"] as? [String: Any], let tab = tab(from: target), let at = debug.attachments[ObjectIdentifier(tab)], at.contextID == context.uniqueIdentifier,
                      let method = a["method"] as? String else { throw Failure(message: "Debugger is not attached to the tab.") }
                return try await cdp(tab, method, (a["params"] as? [String: Any]) ?? [:])
            },
            "debugger.getTargets": Method(permission: "debugger") { _, _ in [Any]() },
        ]
    }

    /// Un onglet attaché qui se ferme, ou que l'utilisateur détache.
    func detach(_ tab: Tab, reason: String) {
        let key = ObjectIdentifier(tab)
        guard let at = debug.attachments.removeValue(forKey: key) else { return }
        send(toContext: at.contextID, event: "debugger.detached", [["tabId": at.tabId], reason])
    }

    private func installConsoleHook(on tab: Tab) {
        guard let web = tab.webView else { return }
        let controller = web.configuration.userContentController
        if !debuggerControllers.contains(controller) {
            debuggerControllers.add(controller)
            controller.add(DebuggerConsoleHandler(), contentWorld: .page, name: Self.consoleHookName)
            controller.addUserScript(WKUserScript(source: Self.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        web.evaluateJavaScript(Self.consoleHook, completionHandler: nil)
    }

    // MARK: Événements

    private func emit(_ tab: Tab, _ method: String, _ params: [String: Any]) {
        guard let at = debug.attachments[ObjectIdentifier(tab)] else { return }
        send(toContext: at.contextID, event: "debugger.onEvent", [["tabId": at.tabId], method, params])
    }

    func consoleEvent(_ tab: Tab, _ body: [String: Any]) {
        if body["k"] as? String == "exception" {
            let text = (body["text"] as? String) ?? "Error"
            emit(tab, "Runtime.exceptionThrown", ["timestamp": Date().timeIntervalSince1970 * 1000, "exceptionDetails": ["exceptionId": 1, "text": text, "lineNumber": body["line"] ?? 0, "columnNumber": body["column"] ?? 0, "url": body["url"] ?? "", "exception": ["type": "object", "subtype": "error", "description": (body["stack"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text]]])
        } else {
            let args = ((body["args"] as? [String]) ?? []).map { ["type": "string", "value": $0] as [String: Any] }
            emit(tab, "Runtime.consoleAPICalled", ["type": body["type"] ?? "log", "args": args, "executionContextId": 1, "timestamp": Date().timeIntervalSince1970 * 1000])
        }
    }

    enum Navigation { case start(URL?), commit(URL?), finish(URL?), fail(URL?, String) }
    /// Le document de la page (les sous-requêtes ne sont pas vues par l'app).
    func navigationEvent(_ tab: Tab, _ nav: Navigation) {
        guard debug.attachments[ObjectIdentifier(tab)] != nil else { return }
        let id = ObjectIdentifier(tab)
        switch nav {
        case .start(let url):
            debug.requestCounter += 1
            emit(tab, "Network.requestWillBeSent", ["requestId": "oree-\(debug.requestCounter)", "loaderId": "oree-\(debug.requestCounter)", "documentURL": url?.absoluteString ?? "", "type": "Document", "frameId": "main",
                                                    "timestamp": Date().timeIntervalSince1970, "request": ["url": url?.absoluteString ?? "", "method": "GET", "headers": [String: String]()]])
        case .commit(let url):
            emit(tab, "Network.responseReceived", ["requestId": "oree-\(debug.requestCounter)", "loaderId": "oree-\(debug.requestCounter)", "type": "Document", "frameId": "main", "timestamp": Date().timeIntervalSince1970,
                                                   "response": ["url": url?.absoluteString ?? "", "status": debug.lastStatus[id] ?? 200, "statusText": "", "headers": [String: String](), "mimeType": "text/html"]])
            emit(tab, "Page.frameNavigated", ["frame": ["id": "main", "loaderId": "oree-\(debug.requestCounter)", "url": url?.absoluteString ?? "", "securityOrigin": url.map { ($0.scheme ?? "") + "://" + ($0.host ?? "") } ?? "", "mimeType": "text/html"]])
        case .finish:
            emit(tab, "Page.domContentEventFired", ["timestamp": Date().timeIntervalSince1970])
            emit(tab, "Page.loadEventFired", ["timestamp": Date().timeIntervalSince1970])
        case .fail(_, let error):
            emit(tab, "Network.loadingFailed", ["requestId": "oree-\(debug.requestCounter)", "timestamp": Date().timeIntervalSince1970, "type": "Document", "errorText": error, "canceled": false])
        }
    }

    func noteStatus(_ tab: Tab, _ status: Int) { debug.lastStatus[ObjectIdentifier(tab)] = status }

    // MARK: CDP

    private func cdp(_ tab: Tab, _ method: String, _ p: [String: Any]) async throws -> Any {
        guard let web = tab.webView else { throw Failure(message: "Onglet fermé.") }
        switch method {
        case "Runtime.enable", "Runtime.disable", "Page.enable", "Page.disable", "Network.enable", "Network.disable", "DOM.enable", "DOM.disable", "Log.enable", "Log.disable", "Inspector.enable",
             "Performance.enable", "Performance.disable", "Emulation.setFocusEmulationEnabled", "Page.setLifecycleEventsEnabled", "Target.setAutoAttach", "Network.setCacheDisabled", "Page.stopLoading":
            if method == "Page.stopLoading" { web.stopLoading() }
            return [String: Any]()
        case "Runtime.evaluate": return try await evaluate(web, p)
        case "Page.captureScreenshot": return try await screenshot(web, p)
        case "Page.navigate":
            guard let urlString = p["url"] as? String, let url = URL(string: urlString) else { throw Failure(message: "Cannot navigate to invalid URL") }
            let direct = ["http", "https", "data", "about", "blob"].contains(url.scheme?.lowercased() ?? "")
            guard let target = direct ? url : AddressResolver.resolve(urlString, defaultEngine: SettingsStore.shared.searchEngine, custom: SettingsStore.shared.customSearchShortcuts)?.url else { throw Failure(message: "Cannot navigate to invalid URL") }
            tab.lastRequestedURL = target; web.load(URLRequest(url: target))
            return ["frameId": "main", "loaderId": "oree-\(debug.requestCounter + 1)"]
        case "Page.reload": web.reload(); return [String: Any]()
        case "Page.bringToFront": window?.selectTab(tab); return [String: Any]()
        case "Page.getFrameTree":
            let url = web.url
            return ["frameTree": ["frame": ["id": "main", "loaderId": "oree-\(debug.requestCounter)", "url": url?.absoluteString ?? "", "securityOrigin": url.map { ($0.scheme ?? "") + "://" + ($0.host ?? "") } ?? "", "mimeType": "text/html"]]]
        case "Page.getLayoutMetrics": return try await layoutMetrics(web)
        case "Page.addScriptToEvaluateOnNewDocument":
            guard let source = p["source"] as? String else { throw Failure(message: "source manquant") }
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            web.configuration.userContentController.addUserScript(script)
            let id = "oree-script-\(debug.scripts.count + 1)"; debug.scripts[id] = script
            return ["identifier": id]
        case "Page.removeScriptToEvaluateOnNewDocument":
            // WebKit ne retire qu'un script à la fois par rechargement de la liste : on retire tout et on remet les autres.
            let id = p["identifier"] as? String ?? ""; debug.scripts[id] = nil
            let controller = web.configuration.userContentController; controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: Self.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            for script in debug.scripts.values { controller.addUserScript(script) }
            return [String: Any]()
        case "Input.dispatchMouseEvent": try await mouse(web, p); return [String: Any]()
        case "Input.dispatchKeyEvent": try await key(web, p); return [String: Any]()
        case "Input.insertText": try await insertText(web, (p["text"] as? String) ?? ""); return [String: Any]()
        default: throw Failure(message: "Commande de débogage non prise en charge dans Orée : \(method)")
        }
    }

    private func evaluate(_ web: WKWebView, _ p: [String: Any]) async throws -> Any {
        guard let expression = p["expression"] as? String else { throw Failure(message: "expression manquante") }
        let body = """
        try {
          let v = (0, eval)(expr);
          if (wait) v = await v;
          const t = v === null ? 'null' : typeof v;
          let json; try { json = JSON.stringify(v, (k, x) => typeof x === 'bigint' ? String(x) : (typeof Node !== 'undefined' && x instanceof Node ? '[' + x.nodeName + ']' : x)); } catch (e) { json = JSON.stringify(String(v)); }
          return JSON.stringify({ ok: true, t, json: json === undefined ? null : json, desc: String(v).slice(0, 300) });
        } catch (e) { return JSON.stringify({ ok: false, name: String(e && e.name), message: String(e && e.message || e), stack: String(e && e.stack || '') }); }
        """
        let raw = try await web.callAsyncJavaScript(body, arguments: ["expr": expression, "wait": (p["awaitPromise"] as? Bool) ?? false], in: nil, contentWorld: .page)
        guard let text = raw as? String, let data = text.data(using: .utf8), let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure(message: "résultat illisible") }
        if r["ok"] as? Bool == false {
            let message = (r["message"] as? String) ?? "Error"
            return ["result": ["type": "object", "subtype": "error", "className": r["name"] ?? "Error", "description": (r["stack"] as? String).flatMap { $0.isEmpty ? nil : "\(r["name"] ?? "Error"): \(message)\n\($0)" } ?? message],
                    "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0, "exception": ["type": "object", "subtype": "error", "className": r["name"] ?? "Error", "description": "\(r["name"] ?? "Error"): \(message)"]]]
        }
        let type = (r["t"] as? String) ?? "undefined"
        var result: [String: Any] = ["type": type == "null" ? "object" : type, "description": (r["desc"] as? String) ?? ""]
        if type == "null" { result["subtype"] = "null"; result["value"] = NSNull() }
        else if type == "undefined" { result.removeValue(forKey: "description") }
        else if let json = r["json"] as? String, let jd = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: jd, options: [.fragmentsAllowed]) { result["value"] = value }
        return ["result": result]
    }

    private func screenshot(_ web: WKWebView, _ p: [String: Any]) async throws -> Any {
        let config = WKSnapshotConfiguration()
        if let clip = p["clip"] as? [String: Any], let w = clip["width"] as? Double, let h = clip["height"] as? Double, w > 0, h > 0 {
            let x = (clip["x"] as? Double) ?? 0, y = (clip["y"] as? Double) ?? 0
            config.rect = NSRect(x: x, y: web.isFlipped ? y : web.bounds.height - y - h, width: w, height: h)
            config.snapshotWidth = NSNumber(value: w * ((clip["scale"] as? Double) ?? 1))
        }
        let image = try await web.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { throw Failure(message: "capture impossible") }
        let isJPEG = (p["format"] as? String) == "jpeg"
        let data = isJPEG ? rep.representation(using: .jpeg, properties: [.compressionFactor: Double((p["quality"] as? Int) ?? 80) / 100]) : rep.representation(using: .png, properties: [:])
        guard let data else { throw Failure(message: "encodage impossible") }
        return ["data": data.base64EncodedString()]
    }

    private func layoutMetrics(_ web: WKWebView) async throws -> Any {
        let raw = try await web.callAsyncJavaScript("return JSON.stringify({ w: innerWidth, h: innerHeight, x: scrollX, y: scrollY, sw: document.documentElement.scrollWidth, sh: document.documentElement.scrollHeight, dpr: devicePixelRatio });", arguments: [:], in: nil, contentWorld: .page)
        guard let text = raw as? String, let d = text.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Double] else { throw Failure(message: "mesures illisibles") }
        let w = m["w"] ?? 0, h = m["h"] ?? 0, x = m["x"] ?? 0, y = m["y"] ?? 0, sw = m["sw"] ?? w, sh = m["sh"] ?? h
        let viewport: [String: Any] = ["pageX": x, "pageY": y, "clientWidth": w, "clientHeight": h]
        let visual: [String: Any] = ["offsetX": 0, "offsetY": 0, "pageX": x, "pageY": y, "clientWidth": w, "clientHeight": h, "scale": 1, "zoom": 1]
        let content: [String: Any] = ["x": 0, "y": 0, "width": sw, "height": sh]
        return ["layoutViewport": viewport, "visualViewport": visual, "contentSize": content, "cssLayoutViewport": viewport, "cssVisualViewport": visual, "cssContentSize": content]
    }

    // MARK: Entrées (souris et clavier)

    private static func flags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { f.insert(.option) }
        if modifiers & 2 != 0 { f.insert(.control) }
        if modifiers & 4 != 0 { f.insert(.command) }
        if modifiers & 8 != 0 { f.insert(.shift) }
        return f
    }

    private func mouse(_ web: WKWebView, _ p: [String: Any]) async throws {
        let type = (p["type"] as? String) ?? "mouseMoved"
        let x = (p["x"] as? Double) ?? Double((p["x"] as? Int) ?? 0), y = (p["y"] as? Double) ?? Double((p["y"] as? Int) ?? 0)
        if type == "mouseWheel" {
            let dx = (p["deltaX"] as? Double) ?? 0, dy = (p["deltaY"] as? Double) ?? 0
            _ = try? await web.callAsyncJavaScript("window.scrollBy({ left: dx, top: dy, behavior: 'instant' });", arguments: ["dx": dx, "dy": dy], in: nil, contentWorld: .page); return
        }
        guard let window = web.window else { throw Failure(message: "L'onglet n'est pas dans une fenêtre.") }
        let button = (p["button"] as? String) ?? "none"
        let point = web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
        let clicks = (p["clickCount"] as? Int) ?? 1, mods = Self.flags((p["modifiers"] as? Int) ?? 0)
        let kind: NSEvent.EventType
        switch (type, button) {
        case ("mousePressed", "right"): kind = .rightMouseDown
        case ("mouseReleased", "right"): kind = .rightMouseUp
        case ("mousePressed", "middle"): kind = .otherMouseDown
        case ("mouseReleased", "middle"): kind = .otherMouseUp
        case ("mousePressed", _): kind = .leftMouseDown
        case ("mouseReleased", _): kind = .leftMouseUp
        default: kind = ((p["buttons"] as? Int) ?? 0) & 1 != 0 ? .leftMouseDragged : .mouseMoved
        }
        guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: max(clicks, 1), pressure: (kind == .leftMouseDown || kind == .leftMouseDragged) ? 1 : 0) else { throw Failure(message: "événement souris impossible") }
        if kind == .leftMouseDown || kind == .rightMouseDown { window.makeFirstResponder(web) }
        switch kind {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        case .rightMouseDown: web.rightMouseDown(with: event)
        case .rightMouseUp: web.rightMouseUp(with: event)
        case .otherMouseDown: web.otherMouseDown(with: event)
        case .otherMouseUp: web.otherMouseUp(with: event)
        default: web.mouseMoved(with: event)
        }
    }

    private static let keyCodes: [String: UInt16] = [
        "Enter": 36, "Return": 36, "Tab": 48, "Escape": 53, "Backspace": 51, "Delete": 117, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, " ": 49, "Space": 49,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]

    private func key(_ web: WKWebView, _ p: [String: Any]) async throws {
        let type = (p["type"] as? String) ?? "keyDown"
        let name = (p["key"] as? String) ?? "", text = (p["text"] as? String) ?? ""
        let modifiers = (p["modifiers"] as? Int) ?? 0
        let special = Self.keyCodes[name].map { code in name.count > 1 || name == " " ? code : nil } ?? nil
        // Un caractère simple, sans Ctrl / Cmd / Alt : on l'insère (le résultat est celui de la frappe).
        if !text.isEmpty, special == nil || name == " ", modifiers & 7 == 0 {
            if type == "keyDown" || type == "char" { try await insertText(web, text) }
            return
        }
        if type == "char" { return }
        guard let window = web.window else { throw Failure(message: "L'onglet n'est pas dans une fenêtre.") }
        guard let code = special ?? Self.keyCodes[name.lowercased()] else { throw Failure(message: "Touche non prise en charge : \(name)") }
        let chars = name == "Enter" ? "\r" : (name == "Tab" ? "\t" : (name == "Escape" ? "\u{1b}" : (name == "Backspace" ? "\u{7f}" : (name.count == 1 ? name : ""))))
        guard let event = NSEvent.keyEvent(with: type == "keyUp" ? .keyUp : .keyDown, location: .zero, modifierFlags: Self.flags(modifiers), timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code) else { throw Failure(message: "événement clavier impossible") }
        window.makeFirstResponder(web)
        if type == "keyUp" { web.keyUp(with: event) } else { web.keyDown(with: event) }
    }

    private func insertText(_ web: WKWebView, _ text: String) async throws {
        let ok = try await web.callAsyncJavaScript("""
          const el = document.activeElement;
          if (document.execCommand && document.execCommand('insertText', false, text)) return true;
          if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) { const s = el.selectionStart ?? el.value.length, e = el.selectionEnd ?? s; el.setRangeText(text, s, e, 'end'); el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' })); return true; }
          return false;
          """, arguments: ["text": text], in: nil, contentWorld: .page)
        if (ok as? Bool) != true { throw Failure(message: "Aucun champ de saisie n'a le focus.") }
    }
}
