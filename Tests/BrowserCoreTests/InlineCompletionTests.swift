import Testing
import Foundation
@testable import BrowserCore

@Suite struct InlineCompletionTests {
    private let history = ["https://www.github.com/torvalds/linux", "https://fr.wikipedia.org/wiki/Lisbonne", "https://github.io/oree/website", "https://example.com/"]

    @Test func aTypedSiteNameIsFinishedWithTheSiteAlone() {
        #expect(InlineCompletion.completion(for: "gith", candidates: history) == "github.com")
        #expect(InlineCompletion.completion(for: "fr.wiki", candidates: history) == "fr.wikipedia.org")
        #expect(InlineCompletion.completion(for: "exa", candidates: history) == "example.com")
    }

    @Test func theBestCandidateWins() {
        #expect(InlineCompletion.completion(for: "git", candidates: history) == "github.com")                       // first in the list
        #expect(InlineCompletion.completion(for: "git", candidates: Array(history.reversed())) == "github.io")
    }

    @Test func aTypedPathIsFinishedWithThePath() {
        #expect(InlineCompletion.completion(for: "github.com/tor", candidates: history) == "github.com/torvalds/linux")
    }

    @Test func whatTheUserTypedIsKeptAsTyped() {
        #expect(InlineCompletion.completion(for: "GitH", candidates: history) == "GitHub.com")
    }

    @Test func nothingIsAddedWhenNothingFitsOrWhenItWouldBeTheSame() {
        #expect(InlineCompletion.completion(for: "zzz", candidates: history) == nil)
        #expect(InlineCompletion.completion(for: "example.com", candidates: history) == nil)     // already complete
        #expect(InlineCompletion.completion(for: "g", candidates: history) == nil)               // too short to guess
        #expect(InlineCompletion.completion(for: "recette de", candidates: history) == nil)      // a search, not a site
        #expect(InlineCompletion.completion(for: "https://git", candidates: history) == nil)
    }
}
