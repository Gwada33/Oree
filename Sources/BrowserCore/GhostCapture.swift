import Foundation

/// What the in-page capture script returns: the page's HTML plus the things it could not put in the markup itself —
/// canvases / videos / frames it left as numbered placeholders for the app to fill (`GhostAssembler`).
public struct GhostCapture: Codable, Equatable, Sendable {
    /// A canvas or video the page could not turn into an image by itself (WebGL, DRM, cross-origin): the app snapshots
    /// its rectangle from the web view. Coordinates are in points, relative to the frame the element lives in.
    public struct MediaSlot: Codable, Equatable, Sendable {
        public var n: Int
        public var x: Double, y: Double, w: Double, h: Double
        public init(n: Int, x: Double, y: Double, w: Double, h: Double) { self.n = n; self.x = x; self.y = y; self.w = w; self.h = h }
    }

    /// A cross-origin iframe: it cannot be read from outside, so the app asks the frame to capture itself.
    public struct FrameSlot: Codable, Equatable, Sendable {
        public var n: Int
        public var src: String
        public var name: String?
        /// Where the frame sits, relative to the top-level viewport (points).
        public var ox: Double, oy: Double
        public var w: Double, h: Double
        /// The frame's own HTML when it could be read (same origin); nil for a cross-origin frame.
        public var html: String?
        public init(n: Int, src: String, name: String? = nil, ox: Double = 0, oy: Double = 0, w: Double = 0, h: Double = 0, html: String? = nil) {
            self.n = n; self.src = src; self.name = name; self.ox = ox; self.oy = oy; self.w = w; self.h = h; self.html = html
        }
    }

    public var v: Int
    public var url: String
    public var title: String
    public var scrollX: Double
    public var scrollY: Double
    public var vw: Double
    public var vh: Double
    public var html: String
    public var media: [MediaSlot]?
    public var frames: [FrameSlot]?

    /// nil for an `{"error": …}` answer or malformed JSON.
    public static func parse(_ json: String) -> GhostCapture? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(GhostCapture.self, from: $0) }
    }

    public var record: GhostRecord {
        GhostRecord(url: url, title: title, scrollX: scrollX, scrollY: scrollY, vw: vw, vh: vh, html: html, capturedAt: Date().timeIntervalSince1970)
    }
}

/// Puts what the app fetched (images, frame documents) into the numbered placeholders the capture script left.
/// The script writes the marker as the FIRST attribute (`<img data-oree-media="3" …>`, `<iframe data-oree-frame="1" …>`),
/// so a plain text replacement is exact.
public enum GhostAssembler {
    public static func insertImage(into html: String, slot n: Int, dataURL: String) -> String {
        html.replacingOccurrences(of: "<img data-oree-media=\"\(n)\"", with: "<img src=\"\(dataURL)\" data-oree-media=\"\(n)\"")
    }

    /// Points the numbered iframe at its document, embedded as a `data:` URL. (A custom URL scheme would be blocked as mixed
    /// content inside an https page, and WebKit ignores `srcdoc` when scripting is off; `data:` frames load in both cases.)
    public static func insertFrame(into html: String, slot n: Int, document: String) -> String {
        let source = "data:text/html;charset=utf-8;base64," + Data(document.utf8).base64EncodedString()
        return html.replacingOccurrences(of: "<iframe data-oree-frame=\"\(n)\"", with: "<iframe src=\"\(source)\" data-oree-frame=\"\(n)\"")
    }
}
