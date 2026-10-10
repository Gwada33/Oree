import Testing
import Foundation
@testable import BrowserCore

@Suite struct GhostTests {
    private func sample(html: String = "<p>Bonjour é 🌍</p>") -> GhostRecord {
        GhostRecord(url: "https://example.com/a", title: "Titre", scrollX: 0, scrollY: 420, vw: 1280, vh: 760, html: html)
    }

    @Test func codecRoundTripsAndShrinksRepetitiveHTML() throws {
        let record = sample(html: String(repeating: "<div class=\"row\"><span>Texte</span></div>", count: 3000))
        let packed = try GhostCodec.encode(record)
        #expect(packed.count * 10 < record.html.utf8.count)
        #expect(try GhostCodec.decode(packed) == record)
    }

    @Test func codecKeepsUnicode() throws {
        let record = sample()
        #expect(try GhostCodec.decode(GhostCodec.encode(record)).html == record.html)
    }

    @Test func decodingGarbageThrows() {
        #expect(throws: (any Error).self) { try GhostCodec.decode(Data("pas du zstd".utf8)) }
    }

    @Test func parsesTheCaptureScriptAnswer() throws {
        let json = #"{"v":1,"url":"https://e.com/","title":"T","scrollX":0,"scrollY":12.5,"vw":800,"vh":600,"html":"<p>x</p>"}"#
        let record = try #require(GhostRecord.parse(scriptResult: json))
        #expect(record.scrollY == 12.5 && record.html == "<p>x</p>" && record.capturedAt != nil)
        #expect(GhostRecord.parse(scriptResult: #"{"error":"boom"}"#) == nil)
        #expect(GhostRecord.parse(scriptResult: "pas du json") == nil)
    }

    @Test func neverGhostsPrivateOrNonWebPages() {
        #expect(GhostPolicy.canCapture(url: URL(string: "https://example.com"), isPrivate: false))
        #expect(GhostPolicy.canCapture(url: URL(string: "http://example.com"), isPrivate: false))
        #expect(!GhostPolicy.canCapture(url: URL(string: "https://example.com"), isPrivate: true))
        #expect(!GhostPolicy.canCapture(url: URL(string: "oree://home/"), isPrivate: false))
        #expect(!GhostPolicy.canCapture(url: URL(string: "file:///tmp/a.html"), isPrivate: false))
        #expect(!GhostPolicy.canCapture(url: nil, isPrivate: false))
    }

    @Test func acceptsOnlyCurrentFormatAndReasonableSize() {
        #expect(GhostPolicy.accepts(sample()))
        #expect(!GhostPolicy.accepts(GhostRecord(v: 99, url: "https://e.com", html: "<p>x</p>")))
        #expect(!GhostPolicy.accepts(GhostRecord(url: "https://e.com", html: "")))
        #expect(!GhostPolicy.accepts(sample(html: String(repeating: "a", count: GhostPolicy.maxHTMLBytes + 1))))
    }

    @Test func flagComesFromTheSettingOrTheEnvironment() {
        #expect(!GhostPolicy.isEnabled(stored: false, environment: [:]))
        #expect(GhostPolicy.isEnabled(stored: true, environment: [:]))
        #expect(GhostPolicy.isEnabled(stored: false, environment: ["HB_GHOST": "1"]))
        #expect(!GhostPolicy.isEnabled(stored: false, environment: ["HB_GHOST": "0"]))
    }
}
