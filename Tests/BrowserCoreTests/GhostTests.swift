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

@Suite struct GhostMatcherTests {
    /// A paragraph block at x = 10.
    private func item(_ h: UInt32, _ y: Double) -> GhostItem { GhostItem(t: "P", h: h, x: 10, y: y) }
    private func item(_ t: String, _ h: UInt32, _ x: Double, _ y: Double) -> GhostItem { GhostItem(t: t, h: h, x: x, y: y) }

    @Test func parsesTheScriptAnswer() {
        let items = GhostMatcher.parse(#"[{"t":"P","h":123,"x":10,"y":40.5},{"t":"H1","h":9,"x":0,"y":0}]"#)
        #expect(items == [item(123, 40.5), item("H1", 9, 0, 0)])
        #expect(GhostMatcher.parse("nope").isEmpty)
    }

    @Test func identicalPagesMatchFully() {
        let page = [item(1, 10), item(2, 80), item("H2", 3, 10, 150)]
        #expect(GhostMatcher.similarity(ghost: page, real: page) == .init(textMatch: 1, positionMatch: 1))
    }

    @Test func movedBlocksKeepTheirTextMatchButLosePositionMatch() {
        let ghost = [item(1, 10), item(2, 80)], real = [item(1, 10), item(2, 140)]
        let s = GhostMatcher.similarity(ghost: ghost, real: real)
        #expect(s.textMatch == 1 && s.positionMatch == 0.5)
    }

    @Test func missingTextLowersBothScores() {
        let s = GhostMatcher.similarity(ghost: [item(1, 10), item(2, 80)], real: [item(1, 10)])
        #expect(s.textMatch == 0.5 && s.positionMatch == 0.5)
        #expect(GhostMatcher.similarity(ghost: [], real: [item(1, 10)]) == .init(textMatch: 1, positionMatch: 1))
    }

    @Test func contentAddedAboveShiftsTheScrollByTheSameAmount() {
        // The ghost shows "Intro" at y=24 at the top; in the real page a 60 pt banner was added above it.
        let ghost = [item(7, 24), item(8, 90)], real = [item(99, 10), item(7, 84), item(8, 150)]
        #expect(GhostMatcher.scrollDelta(ghost: ghost, real: real) == 60)
    }

    @Test func noMoveWhenAlreadyAligned() {
        let page = [item(1, 30), item(2, 100)]
        #expect(GhostMatcher.scrollDelta(ghost: page, real: page) == 0)
    }

    @Test func noAnchorOrAbsurdMoveMeansLeaveTheScrollAlone() {
        #expect(GhostMatcher.scrollDelta(ghost: [item(1, 30)], real: [item(2, 30)]) == nil)
        #expect(GhostMatcher.scrollDelta(ghost: [item(1, 30)], real: [item(1, 9000)]) == nil)
        #expect(GhostMatcher.scrollDelta(ghost: [], real: [item(1, 30)]) == nil)
    }

    @Test func theNearestRepeatedBlockIsTheAnchor() {
        // Same text twice (a repeated "Lire la suite"): pick the occurrence closest to where the ghost had it.
        let ghost = [item(5, 100)], real = [item(5, 40), item(5, 310)]
        #expect(GhostMatcher.scrollDelta(ghost: ghost, real: real) == -60)
    }
}

@Suite struct GhostAssemblerTests {
    @Test func parsesTheCaptureWithItsSlots() throws {
        let json = #"{"v":2,"url":"https://e.com/","title":"T","scrollX":0,"scrollY":10,"vw":800,"vh":600,"html":"<p>x</p>","media":[{"n":0,"x":1,"y":2,"w":30,"h":40}],"frames":[{"n":1,"src":"https://f.com/","ox":5,"oy":6,"w":100,"h":50}]}"#
        let capture = try #require(GhostCapture.parse(json))
        #expect(capture.media == [.init(n: 0, x: 1, y: 2, w: 30, h: 40)])
        #expect(capture.frames?.first?.src == "https://f.com/")
        #expect(capture.record.scrollY == 10)
        #expect(GhostCapture.parse(#"{"error":"boom"}"#) == nil)
    }

    @Test func fillsAnImagePlaceholder() {
        let html = #"<p>a</p><img data-oree-media="0" width="10"><img data-oree-media="1" width="20">"#
        let out = GhostAssembler.insertImage(into: html, slot: 1, dataURL: "data:image/jpeg;base64,AAAA")
        #expect(out.contains(#"<img src="data:image/jpeg;base64,AAAA" data-oree-media="1" width="20">"#))
        #expect(out.contains(#"<img data-oree-media="0" width="10">"#))   // slot 0 untouched
    }

    @Test func embedsAnIframeDocumentAsADataURL() throws {
        let html = #"<iframe data-oree-frame="0" class="ad"></iframe><iframe data-oree-frame="1"></iframe>"#
        let out = GhostAssembler.insertFrame(into: html, slot: 1, document: "<p>Fish & Chips é</p>")
        let encoded = Data("<p>Fish & Chips é</p>".utf8).base64EncodedString()
        #expect(out == #"<iframe data-oree-frame="0" class="ad"></iframe><iframe src="data:text/html;charset=utf-8;base64,\#(encoded)" data-oree-frame="1"></iframe>"#)
    }
}
