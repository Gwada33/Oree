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
