import Testing
import Foundation
import DownloadKit
@testable import DownloadProtocol

/// The XPC layer end to end, in one process: an anonymous listener + the real client and service objects.
@Suite(.serialized) struct XPCRoundTripTests {
    final class Host: @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let delegate: DownloadListenerDelegate
        let manager: DownloadManager
        init(manager: DownloadManager) {
            self.manager = manager
            delegate = DownloadListenerDelegate(manager: manager)
            listener.delegate = delegate
            listener.resume()
        }
    }

    @Test func clientAndServiceTalkOverXPC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oree-xpc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(directory: root.appendingPathComponent("state"))
        let host = Host(manager: DownloadManager(store: store))
        let engine = XPCEngine(endpoint: host.listener.endpoint)

        #expect(await engine.isReachable())
        #expect(await engine.list().isEmpty)

        // An unreachable address is refused by the probe → handed back as "unsupported", over XPC.
        let spec = DownloadRequestSpec(url: URL(string: "http://127.0.0.1:1/nothing")!, destinationDirectory: root.appendingPathComponent("out"))
        guard case .unsupported = await engine.start(spec) else { Issue.record("expected unsupported"); return }

        // Bad ids and unknown downloads are harmless.
        await engine.pause(UUID()); await engine.cancel(UUID()); await engine.setBrowsingActive(true)
        #expect(host.delegate.connectionCount >= 1)
    }

    @Test func snapshotsAreCodableAndPushedToSubscribers() async throws {
        let snapshot = DownloadSnapshot(id: UUID(), name: "a.bin", sourceURL: URL(string: "https://x.example/a.bin")!,
                                        destination: URL(fileURLWithPath: "/tmp"), phase: .running, received: 10, total: 100,
                                        bytesPerSecond: 5, connections: 3, error: nil)
        let data = try JSONEncoder().encode([snapshot])
        #expect(try JSONDecoder().decode([DownloadSnapshot].self, from: data) == [snapshot])
        #expect(snapshot.fraction == 0.1)
        #expect(snapshot.secondsRemaining == 18)

        let hub = ObserverHub()
        var iterator = hub.stream().makeAsyncIterator()
        hub.updated(data)
        #expect(await iterator.next() == [snapshot])
    }

    @Test func agentPlistPointsAtTheHelperAndDeclaresTheMachService() throws {
        let plist = AgentInstaller.plist(executable: URL(fileURLWithPath: "/Applications/Orée.app/Contents/MacOS/OreeDownloader"),
                                         bundleIdentifier: "com.nolhan.hyperbrowser", logPath: "/tmp/x.log")
        #expect(plist["Label"] as? String == DownloaderService.machName)
        #expect((plist["ProgramArguments"] as? [String]) == ["/Applications/Orée.app/Contents/MacOS/OreeDownloader", "--agent"])
        #expect((plist["MachServices"] as? [String: Bool])?[DownloaderService.machName] == true)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["RunAtLoad"] as? Bool == false)
        // It serializes as a valid property list.
        _ = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
