import Testing
import Foundation
@testable import DownloadKit

@Suite struct FormattingTests {
    @Test func sizes() {
        #expect(ByteFormat.size(0) == "0 o")
        #expect(ByteFormat.size(999) == "999 o")
        #expect(ByteFormat.size(48_000) == "48 Ko")
        #expect(ByteFormat.size(3_200_000) == "3,2 Mo")
        #expect(ByteFormat.size(124_000_000) == "124 Mo")
        #expect(ByteFormat.size(1_500_000_000) == "1,5 Go")
    }

    @Test func remainingTime() {
        #expect(ByteFormat.remaining(2) == "quelques secondes restantes")
        #expect(ByteFormat.remaining(30) == "30 s restantes")
        #expect(ByteFormat.remaining(61) == "2 min restantes")
        #expect(ByteFormat.remaining(60) == "1 min restante")
        #expect(ByteFormat.remaining(3_900) == "1 h 5 min restantes")
    }

    @Test func progressLine() {
        let snapshot = DownloadSnapshot(id: UUID(), name: "a", sourceURL: URL(string: "https://x.example/a")!, destination: URL(fileURLWithPath: "/tmp"),
                                        phase: .running, received: 124_000_000, total: 480_000_000, bytesPerSecond: 3_200_000, connections: 4, error: nil)
        #expect(ByteFormat.progressLine(snapshot) == "124 Mo sur 480 Mo · 3,2 Mo/s · 2 min restantes")
        var paused = snapshot; paused.phase = .paused
        #expect(ByteFormat.progressLine(paused) == "124 Mo sur 480 Mo")
    }
}

@Suite struct CookieHeaderTests {
    func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: path]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
    }

    @Test func onlyCookiesOfThisHostAreSent() {
        let jar = [cookie("a", domain: ".example.com"), cookie("b", domain: "www.example.com"), cookie("c", domain: "other.org"),
                   cookie("d", domain: "evil-example.com")]
        let header = CookieHeader.build(for: URL(string: "https://www.example.com/file.zip")!, cookies: jar)
        #expect(header?.contains("a=v-a") == true)
        #expect(header?.contains("b=v-b") == true)
        #expect(header?.contains("c=") != true)
        #expect(header?.contains("d=") != true)
    }

    @Test func pathSecureAndExpiryRules() {
        let jar = [cookie("p", domain: "example.com", path: "/private"), cookie("s", domain: "example.com", secure: true),
                   cookie("old", domain: "example.com", expires: Date(timeIntervalSinceNow: -10)), cookie("ok", domain: "example.com", path: "/files/")]
        let https = CookieHeader.build(for: URL(string: "https://example.com/files/a.zip")!, cookies: jar) ?? ""
        #expect(https.contains("s=v-s") && https.contains("ok=v-ok"))
        #expect(!https.contains("p=v-p") && !https.contains("old="))
        let http = CookieHeader.build(for: URL(string: "http://example.com/files/a.zip")!, cookies: jar) ?? ""
        #expect(!http.contains("s=v-s"), "Secure cookies must not go over http")
        #expect(CookieHeader.build(for: URL(string: "https://example.com/privateer")!, cookies: [cookie("p", domain: "example.com", path: "/private")]) == nil)
    }

    @Test func noCookiesMeansNoHeader() {
        #expect(CookieHeader.build(for: URL(string: "https://example.com/")!, cookies: []) == nil)
    }
}
