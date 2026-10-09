import Testing
import Foundation
@testable import BrowserCore

struct HTTPSPolicyTests {
    let policy = HTTPSPolicy(isEnabled: true)

    @Test func upgradesPlainHTTP() {
        let decision = policy.decision(for: URL(string: "http://example.com/a/b?x=1#frag")!)
        #expect(decision == .upgrade(to: URL(string: "https://example.com/a/b?x=1#frag")!))
    }

    @Test func dropsTheExplicitPort80ButKeepsOtherPorts() {
        #expect(policy.decision(for: URL(string: "http://example.com:80/")!) == .upgrade(to: URL(string: "https://example.com/")!))
        #expect(policy.decision(for: URL(string: "http://example.com:8080/")!) == .upgrade(to: URL(string: "https://example.com:8080/")!))
    }

    @Test func leavesHTTPSAndOtherSchemesAlone() {
        #expect(policy.decision(for: URL(string: "https://example.com/")!) == .allow)
        #expect(policy.decision(for: URL(string: "file:///tmp/a.html")!) == .allow)
    }

    @Test func doesNothingWhenDisabled() {
        #expect(HTTPSPolicy(isEnabled: false).decision(for: URL(string: "http://example.com/")!) == .allow)
    }

    @Test(arguments: [
        "http://localhost:3000/", "http://app.localhost/", "http://127.0.0.1/", "http://192.168.1.20/",
        "http://10.0.0.5/", "http://172.20.1.1/", "http://169.254.1.1/", "http://printer.local/", "http://intranet/",
    ])
    func localAndPrivateHostsAreNeverUpgraded(url: String) {
        #expect(policy.decision(for: URL(string: url)!) == .allow)
    }

    @Test func publicIPsOutsidePrivateRangesAreStillUpgraded() {
        // 172.32.x.x is *outside* RFC 1918's 172.16.0.0/12.
        #expect(policy.decision(for: URL(string: "http://172.32.0.1/")!) == .upgrade(to: URL(string: "https://172.32.0.1/")!))
        #expect(policy.decision(for: URL(string: "http://8.8.8.8/")!) == .upgrade(to: URL(string: "https://8.8.8.8/")!))
    }

    @Test func hostsTheUserAlreadyAllowedOverHTTPAreExempt() {
        let url = URL(string: "http://legacy.example.com/")!
        #expect(policy.decision(for: url, exemptHosts: ["legacy.example.com"]) == .allow)
    }

    @Test func fallbackIsOfferedOnlyWhenTLSIsUnreachable() {
        func error(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }
        #expect(HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorSecureConnectionFailed)))
        #expect(HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorCannotConnectToHost)))
        #expect(HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorTimedOut)))
        // Certificate problems must stay warnings, never a silent downgrade.
        #expect(!HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorServerCertificateUntrusted)))
        #expect(!HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorServerCertificateHasBadDate)))
        // HTTP wouldn't fix a DNS failure or a user cancel.
        #expect(!HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorCannotFindHost)))
        #expect(!HTTPSPolicy.shouldOfferHTTPFallback(for: error(NSURLErrorCancelled)))
        #expect(!HTTPSPolicy.shouldOfferHTTPFallback(for: NSError(domain: "Other", code: NSURLErrorTimedOut)))
    }
}
