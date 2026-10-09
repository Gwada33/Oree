import Testing
import Foundation
@testable import BrowserCore

struct LoadFailureTests {
    private func error(_ code: Int, domain: String = NSURLErrorDomain) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "english text"])
    }

    @Test(arguments: [
        (NSURLErrorNotConnectedToInternet, LoadFailure.offline),
        (NSURLErrorTimedOut, LoadFailure.timeout),
        (NSURLErrorCannotFindHost, LoadFailure.hostNotFound),
        (NSURLErrorDNSLookupFailed, LoadFailure.hostNotFound),
        (NSURLErrorCannotConnectToHost, LoadFailure.cannotConnect),
        (NSURLErrorNetworkConnectionLost, LoadFailure.connectionLost),
    ])
    func networkErrorsAreClassified(code: Int, expected: LoadFailure) {
        #expect(LoadFailure.classify(error(code)) == expected)
    }

    @Test func certificateErrorsAreDistinguished() {
        #expect(LoadFailure.classify(error(NSURLErrorServerCertificateHasBadDate)) == .certificate(.expired))
        #expect(LoadFailure.classify(error(NSURLErrorServerCertificateUntrusted)) == .certificate(.untrusted))
        #expect(LoadFailure.classify(error(NSURLErrorServerCertificateHasUnknownRoot)) == .certificate(.unknownAuthority))
        #expect(LoadFailure.classify(error(NSURLErrorServerCertificateNotYetValid)) == .certificate(.notYetValid))
    }

    @Test func unknownErrorsKeepTheirOwnDescription() {
        #expect(LoadFailure.classify(error(-9999)) == .other("english text"))
        #expect(LoadFailure.classify(error(NSURLErrorTimedOut, domain: "SomethingElse")) == .other("english text"))
    }

    @Test func messagesAreFrench() {
        #expect(LoadFailure.offline.message.contains("Internet"))
        #expect(LoadFailure.certificate(.expired).message.contains("expiré"))
    }
}
