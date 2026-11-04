import Testing
import Foundation
@testable import quern

struct AIOutputAndNotionTests {
    @Test func taskExtractionKeepsVerbatimEvidence() {
        let items = OllamaClient.parseTaskExtractOutput("""
        TASK: Send the revised proposal
        NOTE: Maya owns it before Friday
        EVIDENCE: I’ll send the revised proposal before Friday.
        """)
        #expect(items.count == 1)
        #expect(items[0].title == "Send the revised proposal")
        #expect(items[0].notes == "Maya owns it before Friday")
        #expect(items[0].evidence == "I’ll send the revised proposal before Friday.")
    }

    @Test func notionBlocksPreserveHeadingsBulletsAndLongText() {
        let longNote = String(repeating: "a", count: 2_100)
        let meeting = Meeting(
            id: "note-1", title: "Planning", timestamp: 1,
            manualNotes: longNote, transcript: "", summary: "- Send proposal", template: "Note"
        )
        let blocks = NotionExporter.blocks(for: meeting, options: .full)
        #expect(blocks.contains(where: { $0.type == "heading_1" }))
        #expect(blocks.contains(where: { $0.type == "heading_2" }))
        #expect(blocks.contains(where: { $0.type == "bulleted_list_item" }))
        #expect(blocks.filter { $0.type == "paragraph" }.count >= 2)
    }

    @Test func legacyDestinationFallsBackAndTypeRoutesSurviveReload() throws {
        let legacy = Data(#"{"enabled":true,"parentPageID":"default","destinationKind":"page","autoExportAfterEnhance":false,"includeSummary":true,"includeNotes":true,"includeTranscript":false}"#.utf8)
        var config = try JSONDecoder().decode(NotionIntegrationConfig.self, from: legacy)
        let note = Meeting(id: "n", title: "N", timestamp: 1, manualNotes: "", transcript: "", summary: "", template: "Note")
        let meeting = Meeting(id: "m", title: "M", timestamp: 1, manualNotes: "", transcript: "", summary: "", template: "Meeting")
        #expect(config.destination(for: note).id == "default")
        #expect(config.destination(for: meeting).id == "default")
        config.notePageID = "notes"
        config.meetingPageID = "meetings"
        config.taskPageID = "tasks"
        let restored = try JSONDecoder().decode(NotionIntegrationConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.destination(for: note).id == "notes")
        #expect(restored.destination(for: meeting).id == "meetings")
        #expect(restored.taskPageID == "tasks")
    }

    @Test func notionTaskBlockCarriesCompletionState() throws {
        let block = try #require(NotionBlock.todo(text: "Follow up", checked: true).first)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
        let todo = try #require(json["to_do"] as? [String: Any])
        #expect(todo["checked"] as? Bool == true)
    }
}
