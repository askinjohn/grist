import Foundation
import Testing
@testable import quern

@MainActor
struct NotesAgentTests {
    @Test func emptyInitialSearchStillRunsAgentAndAbstainsWithoutEvidence() async throws {
        var turns = 0
        let result = try await NotesAgent.answer(
            question: "Find the launch decision", meetings: [], initialEvidence: [],
            priorQuestions: [], model: "test", role: .askEverything, progress: { _ in },
            agentTurn: { messages, _, _, _ in
                turns += 1
                if turns == 1 {
                    #expect(messages.last?.content.contains("Initial evidence (may be incomplete):\n[]") == true)
                    return .init(role: "assistant", content: "", toolCalls: [
                        .init(id: "call_1", type: "function", function: .init(name: "read_note", arguments: .object(["meeting_id": .string("outside"), "query": .string("launch")])))
                    ])
                }
                #expect(messages.last?.role == "tool")
                #expect(messages.last?.content.contains("No matching passages") == true)
                return .init(role: "assistant", content: "Invented decision")
            }
        )
        #expect(turns == 2)
        #expect(result.evidence.isEmpty)
        #expect(result.answer.contains("couldn’t find supporting evidence"))
    }

    @Test func readToolStaysInsideCurrentScope() async throws {
        let note = Meeting(id: "allowed", title: "Project", timestamp: 1, manualNotes: "The launch is planned for Friday.\n\nMarketing will prepare the announcement.", transcript: "", summary: "", template: "Note")
        let initial = AskEvidence(id: "S1", meetingID: note.id, title: note.title, timestamp: note.timestamp, section: "notes", quote: "The launch is planned for Friday.")
        var turns = 0
        let result = try await NotesAgent.answer(
            question: "What is next?", meetings: [note], initialEvidence: [initial],
            priorQuestions: [], model: "test", role: .chat, progress: { _ in },
            agentTurn: { messages, _, _, _ in
                turns += 1
                if turns == 1 {
                    return .init(role: "assistant", content: "", toolCalls: [
                        .init(id: "call_1", type: "function", function: .init(name: "read_note", arguments: .object(["meeting_id": .string("outside"), "query": .string("announcement")])))
                    ])
                }
                #expect(messages.last?.content.contains("No matching passages") == true)
                return .init(role: "assistant", content: "The launch is planned for Friday. [S1]")
            }
        )
        #expect(result.evidence.count == 1)
        #expect(result.evidence.first?.meetingID == "allowed")
    }

    @Test func ollamaToolRepliesUseToolName() throws {
        let reply = OllamaClient.OllamaChatMessage(role: "tool", content: "result", toolCallID: "call_1", name: "search_notes")
        let data = try JSONEncoder().encode(OllamaClient.OllamaAgentMessage(reply))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["tool_name"] as? String == "search_notes")
        #expect(value["name"] == nil)
        #expect(value["tool_call_id"] == nil)
    }

    @Test func unsupportedToolModelFallsBackToEvidenceOnlyChat() async throws {
        let source = AskEvidence(id: "S1", meetingID: "note", title: "Launch", timestamp: 1, section: "notes", quote: "The launch is Friday.")
        var usedPlainChat = false
        let result = try await NotesAgent.answer(
            question: "When is launch?", meetings: [], initialEvidence: [source],
            priorQuestions: [], model: "test", role: .chat, progress: { _ in },
            agentTurn: { _, _, _, _ in
                throw NSError(domain: "OllamaClient", code: 4)
            },
            plainTurn: { messages, _, _ in
                usedPlainChat = true
                #expect(messages.last?.content.contains("The launch is Friday.") == true)
                return .init(role: "assistant", content: "Friday. [S1]")
            }
        )
        #expect(usedPlainChat)
        #expect(result.answer == "Friday. [S1]")
    }
}
