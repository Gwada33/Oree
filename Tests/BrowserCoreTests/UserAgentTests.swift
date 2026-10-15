import Testing
@testable import BrowserCore

@Suite struct UserAgentTests {
    @Test func suffixLooksLikeSafari() {
        #expect(UserAgent.applicationName(safariVersion: "27.0") == "Version/27.0 Safari/605.1.15")
    }

    @Test func versionIsSanitized() {
        #expect(UserAgent.sanitizedVersion("18.6.1") == "18.6.1")
        #expect(UserAgent.sanitizedVersion(nil) == "18.0")
        #expect(UserAgent.sanitizedVersion("") == "18.0")
        #expect(UserAgent.sanitizedVersion("evil) Chrome/1") == "18.0")
        #expect(UserAgent.sanitizedVersion(".5") == "18.0")
    }

    @Test func installedVersionIsUsable() {
        let v = UserAgent.installedSafariVersion()
        #expect(!v.isEmpty && v.first?.isNumber == true)
    }
}

@Suite struct UserAgentOverrideTests {
    @Test func safariModeKeepsWebKitsOwnExceptOnListedSites() {
        #expect(UserAgent.override(mode: .safari, custom: "", host: "example.com", chromeHosts: []) == nil)
        #expect(UserAgent.override(mode: .safari, custom: "", host: "www.exemple.fr", chromeHosts: ["exemple.fr"]) == UserAgent.chromeString)
        #expect(UserAgent.override(mode: .safari, custom: "", host: "sub.exemple.fr", chromeHosts: ["exemple.fr"]) == UserAgent.chromeString)
        #expect(UserAgent.override(mode: .safari, custom: "", host: "notexemple.fr", chromeHosts: ["exemple.fr"]) == nil)   // not a subdomain
    }

    @Test func otherModesApplyEverywhere() {
        #expect(UserAgent.override(mode: .chrome, custom: "", host: nil, chromeHosts: []) == UserAgent.chromeString)
        #expect(UserAgent.override(mode: .firefox, custom: "", host: "a.b", chromeHosts: []) == UserAgent.firefoxString)
        #expect(UserAgent.chromeString.contains("Chrome/") && !UserAgent.firefoxString.contains("Chrome"))
    }

    @Test func customTextMustLookLikeAUserAgent() {
        #expect(UserAgent.override(mode: .custom, custom: "  MonNavigateur/1.0  ", host: "a.b", chromeHosts: []) == "MonNavigateur/1.0")
        #expect(UserAgent.override(mode: .custom, custom: "", host: "a.b", chromeHosts: []) == nil)
        #expect(!UserAgent.isAcceptableCustom("ligne\nsuivante"))                 // a header cannot hold a line break
        #expect(!UserAgent.isAcceptableCustom("accentué é"))
        #expect(!UserAgent.isAcceptableCustom(String(repeating: "x", count: 301)))
    }
}

@Suite struct MobileSiteTests {
    @Test func aMobileSiteSeesAnIPhone() {
        let agent = UserAgent.override(mode: .safari, custom: "", host: "m.exemple.fr", chromeHosts: [], mobileHosts: ["exemple.fr"])
        #expect(agent == UserAgent.iphoneString && agent?.contains("iPhone") == true && agent?.contains("Mobile/") == true)
    }

    @Test func mobileWinsOverChromeAndOtherSitesAreUntouched() {
        #expect(UserAgent.override(mode: .safari, custom: "", host: "exemple.fr", chromeHosts: ["exemple.fr"], mobileHosts: ["exemple.fr"]) == UserAgent.iphoneString)
        #expect(UserAgent.override(mode: .safari, custom: "", host: "autre.fr", chromeHosts: [], mobileHosts: ["exemple.fr"]) == nil)
        #expect(UserAgent.override(mode: .chrome, custom: "", host: "autre.fr", chromeHosts: [], mobileHosts: []) == UserAgent.chromeString)
    }
}
