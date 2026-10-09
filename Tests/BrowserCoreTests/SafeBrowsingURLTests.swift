import Testing
import Foundation
@testable import BrowserCore

/// Vectors from Google's Safe Browsing v4 "URLs and Hashing" documentation.
struct SafeBrowsingURLTests {
    private func canonical(_ raw: String) -> String? {
        SafeBrowsingURL.canonicalize(raw)?.urlString
    }

    @Test(arguments: [
        ("http://host/%25%32%35", "http://host/%25"),
        ("http://host/%25%32%35%25%32%35", "http://host/%25%25"),
        ("http://host/%2525252525252525", "http://host/%25"),
        ("http://host/asdf%25%32%35asd", "http://host/asdf%25asd"),
        ("http://host/%%%25%32%35asd%%", "http://host/%25%25%25asd%25%25"),
        ("http://www.google.com/", "http://www.google.com/"),
        ("http://%31%36%38%2e%31%38%38%2e%39%39%2e%32%36/%2E%73%65%63%75%72%65/%77%77%77%2E%65%62%61%79%2E%63%6F%6D/",
         "http://168.188.99.26/.secure/www.ebay.com/"),
        ("http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBaysecure=updateuserdataxplimnbqmn-xplmvalidateinfoswqpcmlx=hgplmcx/",
         "http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBaysecure=updateuserdataxplimnbqmn-xplmvalidateinfoswqpcmlx=hgplmcx/"),
        ("http://host%23.com/%257Ea%2521b%2540c%2523d%2524e%25f%255E00%252611%252A22%252833%252944_55%252B",
         "http://host%23.com/~a!b@c%23d$e%25f^00&11*22(33)44_55+"),
        ("http://3279880203/blah", "http://195.127.0.11/blah"),
        ("http://www.google.com/blah/..", "http://www.google.com/"),
        ("www.google.com/", "http://www.google.com/"),
        ("www.google.com", "http://www.google.com/"),
        ("http://www.evil.com/blah#frag", "http://www.evil.com/blah"),
        ("http://www.GOOgle.com/", "http://www.google.com/"),
        ("http://www.google.com.../", "http://www.google.com/"),
        ("http://www.google.com/foo\tbar\rbaz\n2", "http://www.google.com/foobarbaz2"),
        ("http://www.google.com/q?", "http://www.google.com/q?"),
        ("http://www.google.com/q?r?", "http://www.google.com/q?r?"),
        ("http://www.google.com/q?r?s", "http://www.google.com/q?r?s"),
        ("http://evil.com/foo#bar#baz", "http://evil.com/foo"),
        ("http://evil.com/foo;", "http://evil.com/foo;"),
        ("http://evil.com/foo?bar;", "http://evil.com/foo?bar;"),
        ("http://notrailingslash.com", "http://notrailingslash.com/"),
        ("http://www.gotaport.com:1234/", "http://www.gotaport.com/"),
        ("  http://www.google.com/  ", "http://www.google.com/"),
        ("http:// leadingspace.com/", "http://%20leadingspace.com/"),
        ("http://%20leadingspace.com/", "http://%20leadingspace.com/"),
        ("%20leadingspace.com/", "http://%20leadingspace.com/"),
        ("https://www.securesite.com/", "http://www.securesite.com/"),
        ("http://host.com/ab%23cd", "http://host.com/ab%23cd"),
        ("http://host.com//twoslashes?more//slashes", "http://host.com/twoslashes?more//slashes"),
    ])
    func matchesTheSpecificationVectors(raw: String, expected: String) {
        #expect(canonical(raw) == expected)
    }

    @Test func nonUTF8BytesAreEscapedByteForByte() {
        // "http://\x01\x80.com/" — raw bytes, not representable as a Swift String.
        let bytes: [UInt8] = Array("http://".utf8) + [0x01, 0x80] + Array(".com/".utf8)
        #expect(SafeBrowsingURL.canonicalize(bytes: bytes)?.urlString == "http://%01%80.com/")
    }

    @Test func ipv4FormsNormalizeToDottedDecimal() {
        #expect(SafeBrowsingURL.normalizedIPv4("3279880203") == "195.127.0.11")
        #expect(SafeBrowsingURL.normalizedIPv4("0x7f.1") == "127.0.0.1")
        #expect(SafeBrowsingURL.normalizedIPv4("0177.0.0.01") == "127.0.0.1")
        #expect(SafeBrowsingURL.normalizedIPv4("example.com") == nil)
        #expect(SafeBrowsingURL.normalizedIPv4("1.2.3.256") == nil)
    }

    // MARK: - Lookup expressions (examples from the same document)

    private func expressions(_ raw: String) -> [String] {
        SafeBrowsingURL.expressions(for: SafeBrowsingURL.canonicalize(raw)!)
    }

    @Test func expressionsForAQueryURL() {
        #expect(expressions("http://a.b.c/1/2.html?param=1") == [
            "a.b.c/1/2.html?param=1", "a.b.c/1/2.html", "a.b.c/", "a.b.c/1/",
            "b.c/1/2.html?param=1", "b.c/1/2.html", "b.c/", "b.c/1/",
        ])
    }

    @Test func expressionsUseAtMostFiveHostSuffixes() {
        #expect(expressions("http://a.b.c.d.e.f.g/1.html") == [
            "a.b.c.d.e.f.g/1.html", "a.b.c.d.e.f.g/",
            "c.d.e.f.g/1.html", "c.d.e.f.g/",
            "d.e.f.g/1.html", "d.e.f.g/",
            "e.f.g/1.html", "e.f.g/",
            "f.g/1.html", "f.g/",
        ])
    }

    @Test func ipAddressesAreNotSuffixExpanded() {
        #expect(expressions("http://1.2.3.4/1/") == ["1.2.3.4/1/", "1.2.3.4/"])
    }

    @Test func hashedExpressionsAreSHA256OfEachExpression() {
        let hashed = SafeBrowsingURL.hashedExpressions(for: URL(string: "https://www.example.com/a")!)
        #expect(hashed.map(\.expression) == ["www.example.com/a", "www.example.com/", "example.com/a", "example.com/"])
        // Cross-checked against the system's own `shasum`, not our own code.
        for item in hashed {
            let hex = item.hash.map { String(format: "%02x", $0) }.joined()
            #expect(hex == independentSHA256(item.expression), "hash of \(item.expression)")
        }
    }

    @Test func nonWebURLsProduceNoLookups() {
        #expect(SafeBrowsingURL.hashedExpressions(for: URL(string: "file:///etc/hosts")!).isEmpty)
    }

    private func independentSHA256(_ string: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        task.arguments = ["-a", "256"]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        try? task.run()
        input.fileHandleForWriting.write(Data(string.utf8))
        try? input.fileHandleForWriting.close()
        task.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(text.prefix(64))
    }
}
