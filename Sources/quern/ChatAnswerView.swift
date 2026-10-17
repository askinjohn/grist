import SwiftUI

/// Render blocks separately: Text(AttributedString(markdown:)) drops block spacing.
enum ChatAnswerFormatting {
    static func blocks(_ text: String) -> [String] {
        var result: [String] = [], paragraph: [String] = []
        var fenced = false
        func flush() { if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if fenced { paragraph.append(line); flush(); fenced = false }
                else { flush(); fenced = true; paragraph.append(line) }
            } else if fenced { paragraph.append(line) }
            else if trimmed.isEmpty { flush() }
            else if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                flush(); paragraph.append(line); flush()
            } else { paragraph.append(line) }
        }
        flush()
        return result
    }

    static func attributed(_ text: String, evidence: [AskEvidence]) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for source in evidence {
            var start = value.startIndex
            while start < value.endIndex, let range = value[start...].range(of: "[\(source.id)]") {
                value[range].link = URL(string: "quern-source://\(source.id)")
                start = range.upperBound
            }
        }
        return value
    }
}

struct ChatAnswerView: View {
    let text: String
    let evidence: [AskEvidence]
    let openSource: (AskEvidence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ChatAnswerFormatting.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    ScrollView(.horizontal) {
                        Text(block.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced)).padding(12)
                    }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    Text(ChatAnswerFormatting.attributed(heading > 0 ? String(block.dropFirst(heading)).trimmingCharacters(in: .whitespaces) : block, evidence: evidence))
                        .font(heading > 0 ? .headline : .system(size: 15))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "quern-source" else { return .systemAction }
            if let source = evidence.first(where: { $0.id.caseInsensitiveCompare(url.host ?? "") == .orderedSame }) { openSource(source) }
            return .handled
        })
    }
}

struct ChatSourcePanel: View {
    let source: AskEvidence
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Source [\(source.id)]").font(.headline); Spacer(); Button("Close", action: close) }
                Text(source.title).font(.title3.weight(.semibold))
                Text("\(source.section.capitalized) · \(Date(timeIntervalSince1970: source.timestamp).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                Text(source.quote).font(.body).lineSpacing(5).textSelection(.enabled)
                if source.meetingID != nil {
                    Button("Open original passage") { NotificationCenter.default.post(name: .revealAskEvidence, object: source) }
                }
            }.padding(20)
        }.inspectorColumnWidth(min: 280, ideal: 340, max: 440)
    }
}
