import Testing
import SwiftUI
import AppKit
@testable import quern

struct ChatPresentationTests {
    @Test func savedAnswerUsesQuestionAsNoteTitle() {
        #expect(SavedAnswerNaming.title(question: "  What themes recur in my library?  ", answer: "Three themes [S1]") == "What themes recur in my library?")
        #expect(SavedAnswerNaming.title(question: nil, answer: "## Supply chain risks [S1]\n\nMore detail") == "Supply chain risks")
        #expect(SavedAnswerNaming.title(question: "Give me a gist of this chapter", answer: "The chapter covers several key topics in digital marketing:\n- A/B testing") == "Digital Marketing — Give me a gist of this chapter")
    }
    @Test func preservesParagraphsListsAndFences() {
        let blocks = ChatAnswerFormatting.blocks("Intro.\n\n## Themes\n- **Brand:** First. [S1]\n- Second.\n\n```swift\nlet x = 1\n\nprint(x)\n```\n\nLast paragraph.")
        #expect(blocks.count == 6)
        #expect(blocks[2] == "- **Brand:** First. [S1]")
        #expect(blocks[4].contains("\n\nprint(x)"))
        #expect(blocks[5] == "Last paragraph.")
    }

    @Test func onlyKnownCitationsBecomeSourceLinks() {
        let source = AskEvidence(id: "S1", title: "Example", timestamp: 0, section: "notes", quote: "Original passage")
        let value = ChatAnswerFormatting.attributed("First [S1], again [S1], unknown [S9].\nNext line.", evidence: [source])
        #expect(value.runs.filter { $0.link?.scheme == "quern-source" }.count == 2)
        #expect(String(value.characters).contains("\nNext line."))
    }

    @Test @MainActor func renderAnswerPreview() throws {
        let evidence = [AskEvidence(id: "S1", title: "Brand workshop", timestamp: 0, section: "notes", quote: "Use a consistent tone across channels.")]
        let answer = "## Themes in the retrieved notes\n\nThese passages suggest two recurring themes. They are examples, rather than an exhaustive library review.\n\n- **Brand consistency:** Use a consistent tone across channels. [S1]\n- **Next steps:** Review the original passage before planning changes. [S1]\n\n### What is uncertain\n\nI did not find evidence about pricing in these retrieved passages."
        let view = ChatAnswerView(text: answer, evidence: evidence, openSource: { _ in })
            .padding(24).frame(width: 700).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/quern-chat-answer.png"))
    }
}
