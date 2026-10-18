import Testing
import Foundation
@testable import BrowserStorage

@Suite struct CloudKeychainTests {
    /// Un service qui n'existe que le temps du test : jamais la vraie clé de la personne.
    @Test func hasKeyReflectsSaveAndDeleteWithoutReadingTheValue() {
        let keychain = CloudKeychain(service: "com.nolhan.hyperbrowser.test.\(UUID().uuidString)")
        defer { keychain.delete() }
        #expect(!keychain.hasKey)
        #expect(keychain.save("clé-d'essai"))
        #expect(keychain.hasKey && keychain.load() == "clé-d'essai")
        keychain.delete()
        #expect(!keychain.hasKey)
    }
}
