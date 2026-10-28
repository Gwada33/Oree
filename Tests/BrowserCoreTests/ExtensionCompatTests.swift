import Testing
import Foundation
@testable import BrowserCore

@Suite struct ExtensionCompatTests {
    private func makeExtension(_ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compat-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        for (name, text) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    private func manifest(_ root: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    }
    private let shim = Data("/* shim */".utf8)

    @Test func moduleServiceWorkerLoadsTheShimFirst() throws {
        let root = try makeExtension(["manifest_version": 3, "name": "x", "version": "1", "background": ["service_worker": "sw/main.js", "type": "module"]])
        try ExtensionCompat.apply(to: root, shim: shim)
        let m = try manifest(root), bg = m["background"] as! [String: Any]
        #expect(bg["service_worker"] as? String == "__oree/sw.js")
        let wrapper = try String(contentsOf: root.appendingPathComponent("__oree/sw.js"), encoding: .utf8)
        #expect(wrapper.hasPrefix("import \"/__oree/compat.js\";"))
        #expect(wrapper.contains("import \"/sw/main.js\";"))
        #expect((m["permissions"] as! [String]).contains("nativeMessaging"))
    }

    @Test func classicServiceWorkerUsesImportScripts() throws {
        let root = try makeExtension(["manifest_version": 3, "name": "x", "version": "1", "permissions": ["storage"], "background": ["service_worker": "/bg.js"]])
        try ExtensionCompat.apply(to: root, shim: shim)
        let wrapper = try String(contentsOf: root.appendingPathComponent("__oree/sw.js"), encoding: .utf8)
        #expect(wrapper == "importScripts(\"/__oree/compat.js\", \"/bg.js\");\n")
        #expect((try manifest(root)["permissions"] as! [String]) == ["storage", "nativeMessaging"])
    }

    @Test func backgroundScriptsGetTheShimInFront() throws {
        let root = try makeExtension(["manifest_version": 2, "name": "x", "version": "1", "background": ["scripts": ["a.js", "b.js"]]])
        try ExtensionCompat.apply(to: root, shim: shim)
        try ExtensionCompat.apply(to: root, shim: shim)      // idempotent
        let bg = try manifest(root)["background"] as! [String: Any]
        #expect(bg["scripts"] as! [String] == ["__oree/compat.js", "a.js", "b.js"])
    }

    @Test func htmlPagesGetTheTagOnce() throws {
        let root = try makeExtension(["manifest_version": 3, "name": "x", "version": "1"], files: [
            "popup.html": "<!doctype html><html><head><title>t</title></head><body></body></html>",
            "ui/panel.html": "<html><body>x</body></html>",
            "bare.html": "<p>x</p>",
        ])
        try ExtensionCompat.apply(to: root, shim: shim)
        try ExtensionCompat.apply(to: root, shim: Data("/* v2 */".utf8))
        for name in ["popup.html", "ui/panel.html", "bare.html"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(text.components(separatedBy: "/__oree/compat.js").count == 2, "\(name) : une seule balise")
        }
        let popup = try String(contentsOf: root.appendingPathComponent("popup.html"), encoding: .utf8)
        #expect(popup.contains("<head>" + ExtensionCompat.tag))
        #expect(try String(contentsOf: root.appendingPathComponent("__oree/compat.js"), encoding: .utf8) == "/* v2 */")
    }

    @Test func originalManifestIsKeptAndReused() throws {
        let root = try makeExtension(["manifest_version": 2, "name": "x", "version": "1", "background": ["scripts": ["a.js"]]])
        try ExtensionCompat.apply(to: root, shim: shim)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("__oree/manifest.orig.json"))) as! [String: Any]
        #expect((original["background"] as! [String: Any])["scripts"] as! [String] == ["a.js"])
        #expect(original["permissions"] == nil)
    }
}

@Suite struct ExtensionIDTests {
    /// La clé publique de « Claude dans Chrome » et son identifiant réel dans le Chrome Web Store.
    private let key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjU1XnLPoasGVmZU42K3h6S+sQhkogfcoLPbIcrWH5Oo8QoInBIugkew/7cWaEFySyQrkaEBe1fjeS/rlAqd3r778dKcTvDZcXmj0VVX0Fi1i8tnkarurceGKGdVxfkL7e30nwfgwoPxj3H8OQbsbxFcBWGVtcFekmdpiyaxwz6o4yXIWColfAxh9K2yToOZkoAS5GvgGvTexiCh1gYy++eFdk6C61mcFsyDdoGQtduhGEaX0zZ9uAW1jX4JTPmHV3kEFrZu/WVBl7Obw+Jk/osoHMdmghVNy6SCB8/6mcgmxkP9buPrNUZgYP6n0x5dqEJ2Ecww/lb1Zd4nQf4XGOwIDAQAB"
    @Test func idFollowsChromesRule() { #expect(ExtensionCompat.chromeID(forKey: key) == "fcoeoabgfenejglbffodgkkbkcdhcgfn") }
    @Test func garbageGivesNoID() { #expect(ExtensionCompat.chromeID(forKey: "pas du base64 !!") == nil); #expect(ExtensionCompat.chromeID(forKey: "") == nil) }
}

@Suite struct ExtensionCompatAssemblyTests {
    @Test func sectionsReplaceTheMarkerInOrder() {
        let out = ExtensionCompat.assemble(core: "A\n  //@@SECTIONS@@ (note)\nB", sections: ["one", "two"])
        #expect(out.hasPrefix("A\n  one\ntwo (note)"))
    }
}

@Suite struct ExtensionCompatPageTests {
    @Test func serviceWorkerBecomesAPersistentBackgroundPage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compat-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "x", "version": "1", "background": ["service_worker": "sw/main.js", "type": "module"]]).write(to: root.appendingPathComponent("manifest.json"))
        try ExtensionCompat.apply(to: root, shim: Data("/* shim */".utf8), backgroundAsPage: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        let background = manifest["background"] as! [String: Any]
        #expect(background["page"] as? String == "__oree/background.html" && background["persistent"] as? Bool == true && background["service_worker"] == nil)
        let html = try String(contentsOf: root.appendingPathComponent("__oree/background.html"), encoding: .utf8)
        #expect(html.range(of: "compat.js")!.lowerBound < html.range(of: "sw/main.js")!.lowerBound)
        #expect(html.contains("type=\"module\""))
    }
}
