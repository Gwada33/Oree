import Testing
import Foundation
@testable import BrowserCore

@Suite struct HTTPAuthPolicyTests {
    @Test func onlyPasswordMethodsAreAsked() {
        #expect(HTTPAuthPolicy.asksForCredentials(method: NSURLAuthenticationMethodHTTPBasic))
        #expect(HTTPAuthPolicy.asksForCredentials(method: NSURLAuthenticationMethodHTTPDigest))
        #expect(HTTPAuthPolicy.asksForCredentials(method: NSURLAuthenticationMethodNTLM))
        #expect(!HTTPAuthPolicy.asksForCredentials(method: NSURLAuthenticationMethodServerTrust))
        #expect(!HTTPAuthPolicy.asksForCredentials(method: NSURLAuthenticationMethodClientCertificate))
    }

    @Test func theTitleNamesTheSite() {
        #expect(HTTPAuthPolicy.title(host: "routeur.local", isProxy: false) == "« routeur.local » demande une connexion")
        #expect(HTTPAuthPolicy.title(host: "proxy.corp", isProxy: true).contains("serveur mandataire"))
    }

    @Test func theMessageWarnsAboutRefusalAndPlainConnections() {
        let first = HTTPAuthPolicy.message(realm: "Administration", secure: true, failed: false)
        #expect(first == "Zone protégée : « Administration ».")
        let retry = HTTPAuthPolicy.message(realm: nil, secure: false, failed: true)
        #expect(retry.contains("refusé") && retry.contains("pas chiffrée"))
        #expect(HTTPAuthPolicy.message(realm: "", secure: true, failed: false).isEmpty)
    }
}
