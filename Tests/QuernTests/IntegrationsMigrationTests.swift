import Foundation
import Testing
@testable import quern

struct IntegrationsMigrationTests {
    @Test func existingNotionConfigGainsDisabledCompanionWithoutLosingNotion() throws {
        let data = Data(#"{"version":2,"obsidian":{},"notion":{"enabled":true,"parentPageID":"page-123"}}"#.utf8)
        let config = try JSONDecoder().decode(IntegrationsFile.self, from: data)
        #expect(config.notion.parentPageID == "page-123")
        #expect(config.notion.enabled)
        #expect(!config.companion.enabled)
        #expect(config.companion.baseURL.isEmpty)
    }

    @Test func companionAndNotionSettingsSurviveSameRoundTrip() throws {
        var config = IntegrationsFile.default
        config.companion.enabled = true
        config.companion.baseURL = "https://sync.example.com"
        config.notion.parentPageID = "page-123"
        let restored = try JSONDecoder().decode(IntegrationsFile.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
    }
}
