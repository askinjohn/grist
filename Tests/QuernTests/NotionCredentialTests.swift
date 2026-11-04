import Foundation
import Security
import Testing
@testable import quern

@Suite(.serialized)
struct NotionCredentialTests {
    enum TestFailure: Error { case denied }

    @Test func deniedReadCanRecoverAndSuccessfulReadIsCached() throws {
        let cache = NotionTokenCache()
        #expect(throws: TestFailure.self) {
            try cache.getOrLoad { throw TestFailure.denied }
        }
        #expect(cache.getOrLoad { "test-credential" } == "test-credential")
        #expect(cache.getOrLoad { Issue.record("A cached credential should not trigger another Keychain read"); return nil } == "test-credential")
        cache.set(nil)
        #expect(cache.getOrLoad { "replacement" } == "replacement")
    }

    @Test func backgroundKeychainAccessRestoresInteractionAfterFailure() throws {
        var before = DarwinBoolean(true)
        try #require(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
        #expect(throws: TestFailure.self) {
            try NotionSecretStore.withKeychainAccess(allowInteraction: false) {
                var during = DarwinBoolean(true)
                #expect(SecKeychainGetUserInteractionAllowed(&during) == errSecSuccess)
                #expect(!during.boolValue)
                throw TestFailure.denied
            }
        }
        var after = DarwinBoolean(true)
        #expect(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
        #expect(after.boolValue == before.boolValue)
    }
}
