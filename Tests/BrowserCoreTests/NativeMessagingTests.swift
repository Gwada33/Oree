import Testing
import Foundation
@testable import BrowserCore

@Suite struct NativeMessagingTests {
    @Test func framesRoundTrip() {
        let a = Data("{\"a\":1}".utf8), b = Data("{\"bb\":[2,3]}".utf8)
        let stream = NativeMessaging.frame(a) + NativeMessaging.frame(b)
        let r = NativeMessaging.split(stream)
        #expect(r.messages == [a, b] && r.rest.isEmpty && !r.tooLarge)
    }
    @Test func incompleteMessageWaitsForTheRest() {
        let whole = NativeMessaging.frame(Data("{\"x\":true}".utf8))
        let first = NativeMessaging.split(whole.prefix(7))
        #expect(first.messages.isEmpty && first.rest.count == 7)
        let second = NativeMessaging.split(first.rest + whole.dropFirst(7))
        #expect(second.messages.count == 1 && second.rest.isEmpty)
    }
    @Test func oversizedMessageIsRefused() {
        var huge = UInt32(5_000_000); let data = Data(bytes: &huge, count: 4) + Data(repeating: 0, count: 10)
        #expect(NativeMessaging.split(data).tooLarge)
    }
    @Test func hostLookupChecksTheOrigin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "com.exemple.hote", "description": "x", "path": "/usr/bin/true", "type": "stdio", "allowed_origins": ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("com.exemple.hote.json"))
        #expect((try? NativeMessaging.locate("com.exemple.hote", extensionID: "abcdefghijklmnopabcdefghijklmnop", directories: [dir]).get())?.path == "/usr/bin/true")
        #expect(NativeMessaging.locate("com.exemple.hote", extensionID: "autreidentifiant", directories: [dir]) == .failure(.notAllowed(host: "com.exemple.hote")))
        #expect(NativeMessaging.locate("com.exemple.absent", extensionID: "x", directories: [dir]) == .failure(.notFound))
        #expect(NativeMessaging.locate("../evil", extensionID: "x", directories: [dir]) == .failure(.invalidName))
    }
}
