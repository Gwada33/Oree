import Testing
import Foundation
@testable import BrowserCore

struct URLCleanerTests {
    let cleaner = URLCleaner.bundled

    private func clean(_ string: String) -> String {
        cleaner.clean(URL(string: string)!).absoluteString
    }

    @Test func removesUTMParametersAndKeepsOthers() {
        #expect(clean("https://example.com/page?utm_source=news&utm_medium=email&id=42") == "https://example.com/page?id=42")
    }

    @Test func leavesNoDanglingQuestionMarkWhenEverythingIsTracking() {
        #expect(clean("https://example.com/page?utm_source=a&fbclid=b") == "https://example.com/page")
    }

    @Test func removesClickIDs() {
        #expect(clean("https://example.com/?gclid=abc&q=swift") == "https://example.com/?q=swift")
        #expect(clean("https://example.com/?fbclid=abc") == "https://example.com/")
    }

    @Test func preservesTheFragment() {
        #expect(clean("https://example.com/page?utm_source=a#section-2") == "https://example.com/page#section-2")
    }

    @Test func aQuestionMarkInsideTheFragmentIsNotAQueryString() {
        let url = "https://example.com/app#/route?utm_source=a"
        #expect(clean(url) == url)
    }

    @Test func aURLWithNothingToCleanComesBackIdentical() {
        let url = "https://example.com/a/b?x=1&y=two%20words&z="
        #expect(clean(url) == url)
    }

    @Test func nonWebSchemesAreNeverTouched() {
        let url = "mailto:me@example.com?utm_source=x"
        #expect(cleaner.clean(URL(string: url)!).absoluteString == url)
    }

    @Test func providerRawRulesStripAmazonRefSegments() {
        // `psc` is not in ClearURLs' Amazon list and must survive. (`keywords`
        // *is* in that list — ClearURLs removes it on purpose — so it can't
        // stand in for "a parameter that should be kept".)
        let cleaned = clean("https://www.amazon.com/dp/B000TEST/ref=sr_1_1?qid=1700000000&psc=1")
        #expect(cleaned == "https://www.amazon.com/dp/B000TEST?psc=1")
    }

    @Test func providerExceptionsSkipTheProvider() {
        // Amazon's redirector must keep its parameters or the redirect breaks.
        let url = "https://www.amazon.com/gp/redirector.html?qid=1&ie=UTF8"
        #expect(clean(url) == url)
    }

    @Test func wrapperRedirectsAreUnwrappedToTheirTarget() {
        let wrapped = "https://www.google.com/url?q=https%3A%2F%2Fexample.org%2Fa%3Fb%3D1&sa=U"
        #expect(clean(wrapped) == "https://example.org/a?b=1")
    }

    @Test func referralMarketingIsOptIn() throws {
        let rules = Data(#"{"providers":{"t":{"urlPattern":".*","rules":[],"referralMarketing":["ref"]}}}"#.utf8)
        let url = URL(string: "https://example.com/?ref=friend&id=1")!
        #expect(try URLCleaner(jsonData: rules).clean(url).absoluteString == "https://example.com/?ref=friend&id=1")
        #expect(try URLCleaner(jsonData: rules, includeReferralMarketing: true).clean(url).absoluteString == "https://example.com/?id=1")
    }

    @Test func aBadRegexDoesNotDiscardTheRestOfTheRuleSet() throws {
        let rules = Data(#"{"providers":{"t":{"urlPattern":".*","rules":["(unclosed","tracker"]}}}"#.utf8)
        let cleaned = try URLCleaner(jsonData: rules).clean(URL(string: "https://example.com/?tracker=1&a=2")!)
        #expect(cleaned.absoluteString == "https://example.com/?a=2")
    }
}
