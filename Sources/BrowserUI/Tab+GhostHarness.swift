import AppKit
import WebKit
import BrowserCore

/// Developer tooling for the ghost hibernation (`scripts/ui.sh ghost`, `scripts/bench/ghost_check.py`).
/// Only reachable through the `--automation` channel; nothing here runs in a normal launch.
extension Tab {
    /// Dev harness (`ui.sh ghost`): snapshots the live page, freezes it, shows the ghost over it, snapshots that too.
    /// Returns a JSON line with sizes and timings, or an error message.
    func ghostSelfTest(livePath: String, ghostPath: String) async -> String {
        guard let webView, let store = GhostStorage.store else { return "no live page" }
        func png(_ image: NSImage, to path: String) {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let live = try? await webView.takeSnapshot(configuration: nil) { png(live, to: livePath) }
        let started = Date()
        guard let json = await evaluateWithTimeout(GhostScript.capture, world: GhostScript.world, seconds: 5),
              let record = GhostRecord.parse(scriptResult: json) else { return "capture failed" }
        let captureMs = Int(Date().timeIntervalSince(started) * 1000)
        // A second live snapshot right after the capture: pages keep changing (banners, carousels), so the check
        // compares the ghost with whichever of the two live images it is closer to.
        if let after = try? await webView.takeSnapshot(configuration: nil) { png(after, to: livePath.replacingOccurrences(of: ".png", with: "-after.png")) }
        // Dev only: HB_GHOST_DUMP=/path writes the captured HTML there, to find out why a page does not reproduce.
        if let dump = ProcessInfo.processInfo.environment["HB_GHOST_DUMP"] { try? record.html.write(toFile: dump, atomically: true, encoding: .utf8) }
        guard GhostPolicy.accepts(record), let packed = try? GhostCodec.encode(record) else { return "rejected (size \(record.html.utf8.count))" }
        try? store.put(key: id.uuidString + "-test", data: packed)
        let ghost = GhostView(record: record, dataStore: configuration.websiteDataStore, ruleLists: ghostRuleLists?() ?? [])
        let view = ghost.webView
        contentSlot.addSubview(view, positioned: .below, relativeTo: interstitial)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentSlot.topAnchor), view.leadingAnchor.constraint(equalTo: contentSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentSlot.trailingAnchor), view.bottomAnchor.constraint(equalTo: contentSlot.bottomAnchor),
        ])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            ghost.onReady = { if !done { done = true; continuation.resume() } }
            ghost.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if !done { done = true; continuation.resume() } }
        }
        let settle = ProcessInfo.processInfo.environment["HB_GHOST_SETTLE"].flatMap(Double.init) ?? 1.2   // dev: wait longer to see whether the ghost still changes
        try? await Task.sleep(for: .seconds(settle))          // images and the scroll restore settle
        if let image = try? await view.takeSnapshot(configuration: nil) { png(image, to: ghostPath) }
        // Dev only: HB_GHOST_PROBE=<js> runs in the ghost (isolated world) and its answer joins the report.
        var probe = ""
        if let script = ProcessInfo.processInfo.environment["HB_GHOST_PROBE"] {
            probe = (try? await view.evaluateJavaScript(script, in: nil, contentWorld: GhostScript.world)).map { "\($0)" } ?? "probe error"
        }
        func mb(_ pid: Int32?) -> Double { pid.flatMap { MemoryBudget.footprint(ofProcess: $0) }.map { Double($0) / 1_048_576 } ?? 0 }
        let ghostPID = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        let report: [String: Any] = [
            "url": record.url, "rawKB": record.html.utf8.count / 1024, "packedKB": packed.count / 1024, "captureMs": captureMs,
            "ghostLoadMs": Int((ghost.loadTime ?? 0) * 1000), "scrollY": record.scrollY,
            "realMB": Int(mb(webProcessID)), "probe": probe, "ghostMB": Int(mb(ghostPID)), "ghostPid": Int(ghostPID ?? 0), "realPid": Int(webProcessID ?? 0),
        ]
        ghost.tearDown()
        try? store.remove(key: id.uuidString + "-test")
        return (try? JSONSerialization.data(withJSONObject: report)).flatMap { String(data: $0, encoding: .utf8) } ?? "report failed"
    }
}
