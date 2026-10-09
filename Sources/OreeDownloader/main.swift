import Foundation
import DownloadKit
import DownloadProtocol

// OreeDownloader — the process that owns the downloads. launchd starts it on demand (first XPC message);
// it keeps running while a download is in progress (even if the browser quit) and exits by itself when idle.

// Self-test for the access check: another program (this one, with a different code identity) must be refused.
if CommandLine.arguments.contains("--client-ping") {
    let reachable = await XPCEngine().isReachable(timeout: 4)
    print(reachable ? "ACCEPTÉ (inattendu)" : "REFUSÉ (attendu)")
    exit(reachable ? 1 : 0)
}

// Benchmark mode: runs the engine in this process on one URL and prints speed, connections and memory.
//   OreeDownloader --bench <url> [--max N] [--fixed] [--no-mirrors]
if let at = CommandLine.arguments.firstIndex(of: "--bench"), CommandLine.arguments.indices.contains(at + 1),
   let url = URL(string: CommandLine.arguments[at + 1]) {
    func option(_ name: String) -> String? {
        CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oree-bench-\(UUID().uuidString)")
    let bench = DownloadManager(store: StateStore(directory: root.appendingPathComponent("state")))
    let spec = DownloadRequestSpec(url: url, destinationDirectory: root.appendingPathComponent("out"),
                                   maxConnections: Int(option("--max") ?? "") ?? 8, adaptive: !CommandLine.arguments.contains("--fixed"),
                                   useMirrors: !CommandLine.arguments.contains("--no-mirrors"))
    func footprintMB() -> Double {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) } }
        return ok == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }
    let started = Date()
    guard await bench.start(spec) == .accepted else { print("refusé : le serveur ne gère pas Range"); exit(2) }
    var peakConnections = 0, peakMB = 0.0, sources = 1
    while true {
        try? await Task.sleep(for: .milliseconds(200))
        guard let snapshot = await bench.list().first else { break }
        peakConnections = max(peakConnections, snapshot.connections); sources = max(sources, snapshot.sources)
        peakMB = max(peakMB, footprintMB())
        if snapshot.phase.isTerminal {
            let seconds = Date().timeIntervalSince(started)
            let size = Double(snapshot.total ?? snapshot.received)
            print(String(format: "%@ en %.1f s → %.1f Mo/s · connexions max %d · serveurs %d · mémoire pic %.0f Mo", snapshot.phase.rawValue, seconds, size / 1e6 / seconds, peakConnections, sources, peakMB))
            try? FileManager.default.removeItem(at: root)
            exit(snapshot.phase == .finished ? 0 : 1)
        }
    }
    exit(1)
}

guard CommandLine.arguments.contains("--agent") else {
    FileHandle.standardError.write(Data("OreeDownloader est lancé par launchd (--agent).\n".utf8))
    exit(64)
}

let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
let manager = DownloadManager(store: .standard, allowedDirectories: [downloads])
let delegate = DownloadListenerDelegate(manager: manager)
let listener = NSXPCListener(machServiceName: DownloaderService.machName)
listener.delegate = delegate

// Only the browser may talk to us (best effort: an ad-hoc signature can only pin the identifier).
if ProcessInfo.processInfo.environment["OREE_DL_NO_CHECK"] == nil {
    listener.setConnectionCodeSigningRequirement("identifier \"com.nolhan.hyperbrowser\"")
}
listener.resume()

// Never be napped or killed for being "idle" while downloads run.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
                                                     reason: "Téléchargements Orée")
_ = activity

Task {
    await manager.loadPersisted(autoResume: true)
    var idleTicks = 0
    while true {
        try? await Task.sleep(for: .seconds(5))
        let busy = await manager.hasActiveWork || delegate.connectionCount > 0
        idleTicks = busy ? 0 : idleTicks + 1
        if idleTicks >= 12 { exit(0) }          // a minute with no client and nothing to do
    }
}
dispatchMain()
