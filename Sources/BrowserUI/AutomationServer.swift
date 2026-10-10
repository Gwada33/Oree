import AppKit
import WebKit
import BrowserCore

/// Debug-only UI test channel, active only when the app is launched with
/// `--automation`. It watches a local directory for `command.json`, runs the
/// command against the real window (screenshot, view tree, typing, clicking,
/// menu actions, page JS) and writes `result.json`. No network, no sockets,
/// and nothing runs in a normal launch.
///
/// Command: {"id": "1", "cmd": "snapshot", ...}   Result: {"id": "1", "ok": true, "output": "..."}
@MainActor
final class AutomationServer {
    private let window: NSWindow
    private let directory: URL
    private let activeWebView: () -> WKWebView?
    private let perform: (Selector) -> Bool
    /// Views drawn above the web content (palette, find bar) — redrawn on top
    /// of the page snapshot, which would otherwise cover them.
    private let overlays: () -> [NSView]
    /// Ghost hibernation dev harness: (live snapshot path, ghost snapshot path) → JSON report.
    private let ghostCheck: (String, String) async -> String
    /// Dev only: ("select" | "sleep", index of the tab in the current space) → what happened.
    private let tabOperation: (String, Int) -> String
    private let installExtension: (URL) async throws -> Void
    private let extensionsReport: () -> String
    var extensionOperation: ((String) -> String)?
    private var timer: Timer?

    init(window: NSWindow, activeWebView: @escaping () -> WKWebView?, overlays: @escaping () -> [NSView],
         tabOperation: @escaping (String, Int) -> String,
         ghostCheck: @escaping (String, String) async -> String,
         installExtension: @escaping (URL) async throws -> Void, extensionsReport: @escaping () -> String,
         perform: @escaping (Selector) -> Bool) {
        self.installExtension = installExtension
        self.ghostCheck = ghostCheck
        self.tabOperation = tabOperation
        self.extensionsReport = extensionsReport
        self.window = window
        self.activeWebView = activeWebView
        self.overlays = overlays
        self.perform = perform
        let base = ProcessInfo.processInfo.environment["HB_AUTOMATION_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HyperBrowser/Automation", isDirectory: true)
        directory = base
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Log.tabs.notice("Automation channel enabled at \(base.path, privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var commandURL: URL { directory.appendingPathComponent("command.json") }
    private var resultURL: URL { directory.appendingPathComponent("result.json") }
    private var busy = false

    private func poll() {
        guard !busy, let data = try? Data(contentsOf: commandURL) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        guard let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        busy = true
        Task {
            let (ok, output) = await run(command)
            let result: [String: Any] = ["id": command["id"] ?? "", "ok": ok, "output": output]
            if let json = try? JSONSerialization.data(withJSONObject: result) { try? json.write(to: resultURL, options: .atomic) }
            busy = false
        }
    }

    private func run(_ c: [String: Any]) async -> (Bool, String) {
        switch c["cmd"] as? String ?? "" {
        case "snapshot":
            let path = c["path"] as? String ?? directory.appendingPathComponent("snapshot.png").path
            if let title = c["window"] as? String {   // e.g. "Réglages": any other app window
                guard let other = NSApp.windows.first(where: { $0.title == title && $0.isVisible }), let frame = other.contentView?.superview,
                      let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return (false, "no visible window titled \(title)") }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return (false, "encode failed") }
                do { try png.write(to: URL(fileURLWithPath: path)); return (true, "\(path) \(Int(frame.bounds.width))x\(Int(frame.bounds.height)) (pt)") }
                catch { return (false, "\(error)") }
            }
            return await snapshot(to: path)
        case "tree":
            return (true, describe(window.contentView?.superview ?? window.contentView!, depth: 0))
        case "type":
            for ch in (c["text"] as? String ?? "") { post(key: String(ch), keyCode: 0, flags: []) ; await pause() }
            return (true, "typed")
        case "key":
            return pressKey(c["key"] as? String ?? "")
        case "click":
            guard let x = c["x"] as? Double, let y = c["y"] as? Double else { return (false, "need x,y") }
            click(x: x, y: y, count: c["count"] as? Int ?? 1)
            return (true, "clicked")
        case "drag":
            guard let x = c["x"] as? Double, let y = c["y"] as? Double, let x2 = c["toX"] as? Double, let y2 = c["toY"] as? Double else { return (false, "need x,y,toX,toY") }
            await drag(from: (x, y), to: (x2, y2))
            return (true, "dragged")
        case "action":
            let name = c["name"] as? String ?? ""
            return perform(Selector(name)) ? (true, "performed \(name)") : (false, "controller does not respond to \(name)")
        case "eval":
            guard let web = activeWebView() else { return (false, "no active web view") }
            do {
                let value = try await web.evaluateJavaScript(c["js"] as? String ?? "")
                return (true, value.map { "\($0)" } ?? "null")
            } catch { return (false, "\(error)") }
        case "load":
            guard let web = activeWebView(), let raw = c["url"] as? String else { return (false, "no active web view / url") }
            if raw.hasPrefix("/") {
                let url = URL(fileURLWithPath: raw)
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else if let url = URL(string: raw) { web.load(URLRequest(url: url)) }
            return (true, "loading \(raw)")
        case "sheet":
            // Describe (and optionally press a button of) the sheet attached to the window.
            guard let sheet = window.attachedSheet, let root = sheet.contentView else { return (false, "no sheet") }
            var texts: [String] = [], buttons: [NSButton] = []
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
                if let button = view as? NSButton, !button.title.isEmpty { buttons.append(button) }
                view.subviews.forEach(walk)
            }
            walk(root)
            if let title = c["press"] as? String {
                guard let button = buttons.first(where: { $0.title == title }) else { return (false, "no button \(title); have \(buttons.map(\.title))") }
                button.performClick(nil)
                return (true, "pressed \(title)")
            }
            return (true, "texts=\(texts) buttons=\(buttons.map(\.title))")
        case "front":
            // Scripted launches start behind whatever the user is doing; pages in an
            // occluded window report visibilityState "hidden" and get throttled.
            // Above other windows (so the page counts as visible) but without activating
            // the app: keyboard focus stays wherever the user is working.
            window.orderFrontRegardless()
            return (true, "occlusion visible: \(window.occlusionState.contains(.visible))")
        case "install":
            guard let path = c["path"] as? String else { return (false, "need path") }
            do { try await installExtension(URL(fileURLWithPath: path)); return (true, "installed") }
            catch { return (false, "\(error)") }
        case "extop":
            return (true, extensionOperation?(c["op"] as? String ?? "") ?? "unavailable")
        case "extensions":
            return (true, extensionsReport())
        case "tab":
            return (true, tabOperation(c["op"] as? String ?? "", c["index"] as? Int ?? 0))
        case "ghost":
            let output = await ghostCheck(c["live"] as? String ?? "/tmp/ghost-live.png", c["ghost"] as? String ?? "/tmp/ghost-ghost.png")
            return (output.hasPrefix("{"), output)
        case "gc":
            // Forces a JavaScript garbage collection in every web process (private WebKit call used by its own tests).
            guard let web = activeWebView() else { return (false, "no active web view") }
            let pool = web.configuration.processPool
            let selector = NSSelectorFromString("_garbageCollectJavaScriptObjectsForTesting")
            guard pool.responds(to: selector) else { return (false, "selector unavailable") }
            _ = pool.perform(selector)
            return (true, "gc requested")
        case "webkit":
            guard let web = activeWebView() else { return (false, "no active web view") }
            return (true, WebKitTuning.processReport(for: web.configuration.processPool))
        case "state":
            let web = activeWebView()
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return (true, "liveTabs=\(Tab.liveCount) url=\(web?.url?.absoluteString ?? "nil") title=\(web?.title ?? "nil") loading=\(web?.isLoading ?? false) firstResponder=\(responder) window=\(window.frame) visible=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow)")
        default:
            return (false, "unknown cmd; use snapshot|tree|type|key|click|action|eval|state")
        }
    }

    // MARK: Snapshot

    private func snapshot(to path: String) async -> (Bool, String) {
        guard let frame = window.contentView?.superview else { return (false, "no window") }
        frame.layoutSubtreeIfNeeded()
        let bounds = frame.bounds
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return (false, "no bitmap") }
        frame.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        // WKWebView content is composited out-of-process and isn't reliably
        // included by cacheDisplay, so draw its own snapshot on top.
        var composed = image
        if let web = activeWebView(), !web.isHidden, web.alphaValue > 0.05, web.superview != nil,
           let page = try? await web.takeSnapshot(configuration: nil) {
            let rect = frame.convert(web.bounds, from: web)
            composed = NSImage(size: bounds.size, flipped: false) { _ in
                image.draw(in: bounds)
                page.draw(in: rect)
                return true
            }
        }
        for overlay in overlays() where !overlay.isHidden && overlay.alphaValue > 0.01 {
            guard let overlayRep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: overlayRep)
            let overlayImage = NSImage(size: overlay.bounds.size)
            overlayImage.addRepresentation(overlayRep)
            let base = composed
            let rect = frame.convert(overlay.bounds, from: overlay)
            composed = NSImage(size: bounds.size, flipped: false) { _ in
                base.draw(in: bounds)
                overlayImage.draw(in: rect)
                return true
            }
        }
        guard let tiff = composed.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
              let png = out.representation(using: .png, properties: [:]) else { return (false, "encode failed") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return (true, "\(path) \(Int(bounds.width))x\(Int(bounds.height)) (pt)")
        } catch { return (false, "\(error)") }
    }

    // MARK: Tree

    private func describe(_ view: NSView, depth: Int) -> String {
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
        let f = view.convert(view.bounds, to: window.contentView?.superview)
        let top = (window.contentView?.superview?.bounds.height ?? 0) - f.maxY
        line += String(format: " [x=%.0f y=%.0f w=%.0f h=%.0f]", f.minX, top, f.width, f.height)
        if view.isHidden { line += " hidden" }
        if window.firstResponder === view { line += " FOCUS" }
        if let editor = window.firstResponder as? NSTextView, editor.delegate === view { line += " FOCUS(editing)" }
        if let field = view as? NSTextField { line += " text=\"\(field.stringValue.prefix(60))\"" }
        if let button = view as? NSButton, !button.title.isEmpty { line += " title=\"\(button.title)\"" }
        if let label = view.accessibilityLabel(), !label.isEmpty { line += " ax=\"\(label)\"" }
        return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
    }

    // MARK: Input

    private func pause() async { try? await Task.sleep(for: .milliseconds(25)) }

    private func post(key chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: keyCode
            ) { NSApp.postEvent(event, atStart: false) }
        }
    }

    private func pressKey(_ spec: String) -> (Bool, String) {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last else { return (false, "empty key") }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: return (false, "unknown modifier \(modifier)")
            }
        }
        let special: [String: (String, UInt16)] = [
            "return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53), "delete": ("\u{7f}", 51), "space": (" ", 49),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
        ]
        let (chars, code) = special[name] ?? (name, 0)
        post(key: chars, keyCode: code, flags: flags)
        return (true, "pressed \(spec)")
    }

    private func drag(from: (Double, Double), to: (Double, Double)) async {
        guard let frame = window.contentView?.superview else { return }
        func point(_ p: (Double, Double)) -> NSPoint { frame.convert(NSPoint(x: p.0, y: frame.bounds.height - p.1), to: nil) }
        func post(_ type: NSEvent.EventType, _ location: NSPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        post(.leftMouseDown, point(from)); try? await Task.sleep(for: .milliseconds(80))
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, point((from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t)))
            try? await Task.sleep(for: .milliseconds(30))
        }
        post(.leftMouseUp, point(to)); try? await Task.sleep(for: .milliseconds(400))
    }

    /// `x`,`y` are in points from the top-left of the window frame — the same
    /// coordinates the snapshot and tree report.
    private func click(x: Double, y: Double, count: Int) {
        guard let frame = window.contentView?.superview else { return }
        let point = frame.convert(NSPoint(x: x, y: frame.bounds.height - y), to: nil)
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            _ = index
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0
            ) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
