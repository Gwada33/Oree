import AppKit
import AVFoundation
import IOKit.pwr_mgt
import WebKit
import BrowserCore

/// management, idle, power, system.*, browsingData, search, tts, sessions, identity : le système, vu comme dans Chrome.
@MainActor
final class SystemStates: NSObject, AVSpeechSynthesizerDelegate {
    var keepAwake: [String: [IOPMAssertionID]] = [:]
    var idleInterval: [String: Int] = [:]
    var lastIdleState = "active"
    var idleTimer: Timer?
    var speech = AVSpeechSynthesizer()
    var speechIDs: [ObjectIdentifier: (context: String, id: String)] = [:]
    var emit: ((String, String, Any) -> Void)?
    var authFlows: [ObjectIdentifier: AuthFlow] = [:]

    struct AuthFlow { let base: String; let contextID: String; let finish: (Result<String, ExtensionBridge.Failure>) -> Void }

    override init() { super.init(); speech.delegate = self }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { tell(u, "start") }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { tell(u, "end") }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { tell(u, "interrupted") }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) { tell(u, "word", index: r.location) }
    nonisolated private func tell(_ u: AVSpeechUtterance, _ type: String, index: Int? = nil) {
        nonisolated(unsafe) let utterance = u
        Task { @MainActor in
            guard let who = self.speechIDs[ObjectIdentifier(utterance)] else { return }
            var event: [String: Any] = ["type": type]
            if let index { event["charIndex"] = index }
            self.emit?(who.context, "tts.event", [who.id, event])
            if type == "end" || type == "interrupted" { self.speechIDs[ObjectIdentifier(utterance)] = nil }
        }
    }
}

extension ExtensionBridge {
    private func hasPermission(_ name: String, _ context: WKWebExtensionContext) -> Bool { permissions(context).contains(name) }

    /// L'état d'inactivité de l'utilisateur : « locked », « idle » (plus d'entrée depuis `interval` s) ou « active ».
    private func idleState(interval: Int) -> String {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], (session["CGSSessionScreenIsLocked"] as? Bool) == true { return "locked" }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return seconds >= Double(max(interval, 15)) ? "idle" : "active"
    }

    /// Une fois une extension connectée, on surveille l'inactivité (toutes les 10 s) et on prévient d'un changement d'état.
    func startIdleWatch() {
        guard system.idleTimer == nil else { return }
        system.idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            mainActorNow {
                guard let self else { return }
                let now = self.idleState(interval: 60)
                if now != self.system.lastIdleState { self.system.lastIdleState = now; self.broadcast("idle.onStateChanged", now) }
            }
        }
    }

    func systemMethods() -> [String: Method] {
        func info(_ id: String) throws -> [String: Any] {
            guard let value = manager?.managementInfo(id: id) else { throw Failure(message: "Failed to find extension with id \(id)") }
            return value
        }
        return [
            // MARK: management
            "management.getAll": Method(permission: "management") { [self] _, _ in manager?.allManagementInfo() ?? [Any]() },
            "management.get": Method(permission: "management") { a, _ in try info((a["id"] as? String) ?? "") },
            "management.getSelf": Method(permission: nil) { _, context in try info(context.uniqueIdentifier) },
            "management.setEnabled": Method(permission: "management") { [self] a, _ in
                let id = (a["id"] as? String) ?? ""; _ = try info(id)
                manager?.setEnabled((a["enabled"] as? Bool) ?? true, id: id); return NSNull()
            },
            "management.uninstall": Method(permission: "management") { [self] a, context in
                let id = (a["id"] as? String) ?? ""; let target = try info(id)
                if !(manager?.autoApprove ?? false), let w = window?.window {
                    let alert = NSAlert(); alert.messageText = "Supprimer « \(target["name"] ?? "cette extension") » ?"
                    alert.informativeText = "« \(context.webExtension.displayName ?? "Une extension") » demande de la supprimer."
                    alert.addButton(withTitle: "Supprimer"); alert.addButton(withTitle: "Annuler")
                    let agreed = await withCheckedContinuation { c in alert.beginSheetModal(for: w) { c.resume(returning: $0 == .alertFirstButtonReturn) } }
                    if !agreed { throw Failure(message: "User cancelled uninstall") }
                }
                manager?.remove(id: id); return NSNull()
            },
            "management.uninstallSelf": Method(permission: nil) { [self] _, context in manager?.remove(id: context.uniqueIdentifier); return NSNull() },
            // MARK: idle, power
            "idle.queryState": Method(permission: "idle") { [self] a, _ in idleState(interval: (a["interval"] as? Int) ?? 60) },
            "idle.setDetectionInterval": Method(permission: "idle") { [self] a, context in system.idleInterval[context.uniqueIdentifier] = (a["interval"] as? Int) ?? 60; startIdleWatch(); return NSNull() },
            "power.requestKeepAwake": Method(permission: "power") { [self] a, context in
                let type = (a["level"] as? String) == "system" ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
                var id = IOPMAssertionID(0)
                guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "\(context.webExtension.displayName ?? "Extension") dans Orée" as CFString, &id) == kIOReturnSuccess else { throw Failure(message: "Impossible d'empêcher la mise en veille.") }
                system.keepAwake[context.uniqueIdentifier, default: []].append(id); return NSNull()
            },
            "power.releaseKeepAwake": Method(permission: "power") { [self] _, context in
                for id in system.keepAwake.removeValue(forKey: context.uniqueIdentifier) ?? [] { IOPMAssertionRelease(id) }; return NSNull()
            },
            // MARK: system.*
            "system.cpu.getInfo": Method(permission: "system.cpu") { _, _ in
                var model = [CChar](repeating: 0, count: 256); var size = model.count
                sysctlbyname("machdep.cpu.brand_string", &model, &size, nil, 0)
                var count: natural_t = 0; var data: processor_info_array_t? = nil; var dataCount: mach_msg_type_number_t = 0
                var processors = [[String: Any]]()
                if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &data, &dataCount) == KERN_SUCCESS, let data {
                    for i in 0..<Int(count) {
                        let base = Int(CPU_STATE_MAX) * i
                        let user = Double(data[base + Int(CPU_STATE_USER)]), kernel = Double(data[base + Int(CPU_STATE_SYSTEM)]), idle = Double(data[base + Int(CPU_STATE_IDLE)]) + Double(data[base + Int(CPU_STATE_NICE)])
                        processors.append(["usage": ["user": user, "kernel": kernel, "idle": idle, "total": user + kernel + idle]])
                    }
                    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: data), vm_size_t(dataCount) * vm_size_t(MemoryLayout<integer_t>.size))
                }
                return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": "arm64", "modelName": String(cString: model), "features": [String](), "processors": processors, "temperatures": [Double]()]
            },
            "system.memory.getInfo": Method(permission: "system.memory") { _, _ in
                var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
                let ok = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
                let page = Double(sysconf(_SC_PAGESIZE))
                let free = ok == KERN_SUCCESS ? (Double(stats.free_count) + Double(stats.inactive_count)) * page : 0
                return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": free]
            },
            "system.storage.getInfo": Method(permission: "system.storage") { _, _ in
                let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeNameKey])
                return [["id": "volume:/", "name": values?.volumeName ?? "Macintosh HD", "type": "fixed", "capacity": Double(values?.volumeTotalCapacity ?? 0)] as [String: Any]]
            },
            "system.storage.getAvailableCapacity": Method(permission: "system.storage") { _, _ in
                let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return ["id": "volume:/", "availableCapacity": Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)]
            },
            "system.display.getInfo": Method(permission: "system.display") { _, _ in
                NSScreen.screens.enumerated().map { i, s -> [String: Any] in
                    let f = s.frame, v = s.visibleFrame, scale = s.backingScaleFactor
                    let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0)" } ?? "\(i)"
                    func rect(_ r: NSRect) -> [String: Any] { ["left": r.minX, "top": f.maxY - r.maxY, "width": r.width, "height": r.height] }
                    return ["id": id, "name": s.localizedName, "isPrimary": i == 0, "isInternal": s.localizedName.lowercased().contains("built") || s.localizedName.lowercased().contains("intégré"), "isEnabled": true, "dpiX": 72 * scale, "dpiY": 72 * scale,
                            "rotation": 0, "bounds": rect(f), "workArea": rect(v), "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0], "modes": [Any](), "mirroringSourceId": "", "hasTouchSupport": false, "hasAccelerometerSupport": false, "availableDisplayZoomFactors": [Double](), "displayZoomFactor": 1]
                }
            },
            // MARK: browsingData
            "browsingData.remove": Method(permission: "browsingData") { [self] a, _ in
                let options = (a["options"] as? [String: Any]) ?? [:], what = (a["dataToRemove"] as? [String: Any]) ?? [:]
                let since = (options["since"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
                var types = Set<String>()
                func has(_ k: String) -> Bool { (what[k] as? Bool) == true }
                if has("cache") || has("cacheStorage") { types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]) }
                if has("cookies") { types.insert(WKWebsiteDataTypeCookies) }
                if has("localStorage") { types.insert(WKWebsiteDataTypeLocalStorage); types.insert(WKWebsiteDataTypeSessionStorage) }
                if has("indexedDB") { types.insert(WKWebsiteDataTypeIndexedDBDatabases) }
                if has("webSQL") { types.insert(WKWebsiteDataTypeWebSQLDatabases) }
                if has("serviceWorkers") { types.insert(WKWebsiteDataTypeServiceWorkerRegistrations) }
                if has("fileSystems") { types.insert(WKWebsiteDataTypeFileSystem) }
                let store = ProfileContext.dataStore
                if !types.isEmpty {
                    if let origins = options["origins"] as? [String], !origins.isEmpty {
                        let hosts = Set(origins.compactMap { URL(string: $0)?.host })
                        let records = await store.dataRecords(ofTypes: types).filter { r in hosts.contains { r.displayName == $0 || $0.hasSuffix("." + r.displayName) || r.displayName.hasSuffix($0) } }
                        await store.removeData(ofTypes: types, for: records)
                    } else { await store.removeData(ofTypes: types, modifiedSince: since) }
                }
                if has("history"), let repo = window?.historyRepo { if since == .distantPast { try repo.clear() } else { try repo.remove(from: since, to: Date()) } }
                if has("downloads") { window?.downloads.clearFinished() }
                return NSNull()
            },
            // MARK: search
            "search.query": Method(permission: "search") { [self] a, _ in
                guard let text = a["text"] as? String, !text.isEmpty else { throw Failure(message: "text est requis") }
                window?.openFromPalette(text, inNewTab: (a["disposition"] as? String) != "CURRENT_TAB"); return NSNull()
            },
            // MARK: sessions
            "sessions.getRecentlyClosed": Method(permission: "sessions") { [self] a, _ in
                let limit = min((a["maxResults"] as? Int) ?? 25, 25)
                return Array((window?.closedTabs ?? []).reversed().prefix(limit)).enumerated().map { i, closed -> [String: Any] in
                    ["lastModified": Date().timeIntervalSince1970 - Double(i), "tab": ["sessionId": "oree-closed-\(i)", "index": 0, "windowId": -1, "url": closed.url.absoluteString, "title": closed.title ?? "", "active": false, "highlighted": false, "pinned": false, "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]]
                }
            },
            // MARK: tts
            "tts.speak": Method(permission: "tts") { [self] a, context in
                let text = (a["text"] as? String) ?? ""; guard !text.isEmpty else { throw Failure(message: "Text is required") }
                let options = (a["options"] as? [String: Any]) ?? [:]
                let utterance = AVSpeechUtterance(string: text)
                if let name = options["voiceName"] as? String, let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) { utterance.voice = voice }
                else if let lang = options["lang"] as? String { utterance.voice = AVSpeechSynthesisVoice(language: lang) }
                if let rate = options["rate"] as? Double { utterance.rate = Float(min(max(rate * 0.5, 0.0), 1.0)) }
                if let pitch = options["pitch"] as? Double { utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0)) }
                if let volume = options["volume"] as? Double { utterance.volume = Float(min(max(volume, 0), 1)) }
                if (options["enqueue"] as? Bool) != true { system.speech.stopSpeaking(at: .immediate) }
                system.speechIDs[ObjectIdentifier(utterance)] = (context.uniqueIdentifier, (a["id"] as? String) ?? "")
                if !(manager?.autoApprove ?? false) { system.speech.speak(utterance) } else { system.emit?(context.uniqueIdentifier, "tts.event", [(a["id"] as? String) ?? "", ["type": "end"]]) }
                return NSNull()
            },
            "tts.stop": Method(permission: "tts") { [self] _, _ in system.speech.stopSpeaking(at: .immediate); return NSNull() },
            "tts.pause": Method(permission: "tts") { [self] _, _ in system.speech.pauseSpeaking(at: .immediate); return NSNull() },
            "tts.resume": Method(permission: "tts") { [self] _, _ in system.speech.continueSpeaking(); return NSNull() },
            "tts.isSpeaking": Method(permission: "tts") { [self] _, _ in system.speech.isSpeaking },
            "tts.getVoices": Method(permission: "tts") { _, _ in
                AVSpeechSynthesisVoice.speechVoices().map { ["voiceName": $0.name, "lang": $0.language, "remote": false, "extensionId": "", "eventTypes": ["start", "end", "word", "interrupted"]] as [String: Any] }
            },
            // MARK: identity : la page de connexion s'ouvre dans un onglet ; la redirection vers https://<id>.chromiumapp.org/… la termine
            "identity.launchWebAuthFlow": Method(permission: "identity") { [self] a, context in
                guard let urlString = a["url"] as? String, let url = URL(string: urlString), ["https", "http"].contains(url.scheme ?? ""), let base = a["redirectBase"] as? String else { throw Failure(message: "Invalid value for argument 1. Property 'url': Value must be a valid URL.") }
                guard (a["interactive"] as? Bool) != false else { throw Failure(message: "User interaction required.") }
                guard let window else { throw Failure(message: "fenêtre indisponible") }
                let tab = window.newTab(urlString: urlString, isPrivate: false)
                let key = ObjectIdentifier(tab)
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                    system.authFlows[key] = SystemStates.AuthFlow(base: base, contextID: context.uniqueIdentifier) { result in
                        switch result {
                        case .success(let redirect): continuation.resume(returning: redirect)
                        case .failure(let failure): continuation.resume(throwing: failure)
                        }
                    }
                }
            },
        ]
    }

    /// Appelé à chaque navigation : une redirection de connexion vers l'adresse de l'extension termine le flux (et referme l'onglet).
    func interceptAuthRedirect(_ tab: Tab, url: URL?) -> Bool {
        let key = ObjectIdentifier(tab)
        // Le nom d'hôte d'une adresse est en minuscules, l'identifiant de l'extension peut avoir des majuscules : on compare sans casse, et on rend l'adresse avec la graphie de l'extension.
        guard let flow = system.authFlows[key], let url, url.absoluteString.lowercased().hasPrefix(flow.base.lowercased()) else { return false }
        system.authFlows[key] = nil
        flow.finish(.success(flow.base + url.absoluteString.dropFirst(flow.base.count)))
        window?.closeTab(tab, remember: false)
        return true
    }

    /// L'onglet de connexion est fermé par l'utilisateur.
    func authTabClosed(_ tab: Tab) {
        guard let flow = system.authFlows.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        flow.finish(.failure(Failure(message: "The user did not approve access.")))
    }
}
