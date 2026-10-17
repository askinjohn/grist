import SwiftUI
import AppKit

enum SavedAnswerNaming {
    static func title(question: String?, answer: String) -> String {
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            let generic = ["this ", "these ", " it ", "gist", "summarize"].contains { question.localizedCaseInsensitiveContains($0) }
            if generic,
               let line = answer.components(separatedBy: .newlines).first,
               let range = line.range(of: " in ", options: .caseInsensitive) {
                let topic = String(line[range.upperBound...])
                    .components(separatedBy: CharacterSet(charactersIn: ":.!?"))
                    .first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !topic.isEmpty, topic.count <= 45 {
                    return String("\(topic.capitalized) — \(question)".prefix(90))
                }
            }
            return String(question.prefix(90))
        }
        let plain = answer
            .replacingOccurrences(of: #"\[S\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Saved answer"
        return String(firstLine.prefix(90))
    }
}

extension ChatView {
    @ViewBuilder var askScopeControls: some View {
        if case .global = scope {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Scope", selection: $scopeFolder) {
                        Text("All notes and meetings").tag("")
                        ForEach(Database.shared.fetchFolders(), id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 280)
                    Picker("Created", selection: $recentDays) {
                        Text("All time").tag(0)
                        Text("Last 7 days").tag(7)
                        Text("Last 30 days").tag(30)
                    }
                    .frame(maxWidth: 180)
                    Spacer(minLength: 0)
                    Menu {
                        Text(indexCount == 0 ? "Keyword search available" : "Semantic index: \(indexCount) passages")
                        Button(rebuilding ? "Rebuilding…" : "Rebuild index") {
                            rebuilding = true
                            Task {
                                let result = await RAGEngine.shared.reindexAll(meetings: Database.shared.fetchActiveMeetings())
                                indexCount = result.chunks
                                indexStatus = result.error ?? "Index rebuilt"
                                rebuilding = false
                            }
                        }.disabled(rebuilding)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Search options")
                }.disabled(isThinking)
                if !indexStatus.isEmpty { Text(indexStatus).font(.caption).textSelection(.enabled) }
                if !retrievalStatus.isEmpty { Text(retrievalStatus).font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: 1000).frame(maxWidth: .infinity).background(.bar)
        } else if case .item(let item) = scope {
            Text("Scope: \(item.title)").font(.caption).padding(8)
        }
    }
}

struct AnswerActions: View {
    let message: ChatMessage
    let suggestedTitle: String
    let sourceQuestion: String?
    @State private var status = ""
    @State private var taskTitle = ""
    @State private var showTask = false
    @State private var noteTitle = ""
    @State private var showSaveNote = false
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string); status = "Copied" }
                Menu("More") {
                Button("Create task") { taskTitle = ""; showTask = true }
                Button("Save as note") {
                    noteTitle = suggestedTitle
                    showSaveNote = true
                }
                Button(sending ? "Sending…" : "Send to Notion") {
                    sending = true
                    Task {
                        do { try await NotionExporter.exportMeeting(answerNote(title: suggestedTitle)); status = "Sent to Notion" }
                        catch { status = error.localizedDescription }
                        sending = false
                    }
                }.disabled(sending || !IntegrationsConfigManager.shared.config.notion.isConfigured)
                }.fixedSize()
            }.controlSize(.small)
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
        .alert("Create task from answer", isPresented: $showTask) {
            TextField("Task title", text: $taskTitle)
            Button("Create") {
                let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Database.shared.saveTask(.manual(title: title, notes: message.content))
                NotificationCenter.default.post(name: .libraryContentChanged, object: nil)
                status = "Task created"
            }.disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        } message: { Text("The answer will be saved as task context. Enter the action you want to track.") }
        .alert("Save answer as note", isPresented: $showSaveNote) {
            TextField("Note title", text: $noteTitle)
            Button("Save") {
                let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let note = answerNote(title: title)
                Database.shared.saveMeeting(note)
                RAGEngine.shared.indexMeetingNow(note)
                NotificationCenter.default.post(name: .libraryContentChanged, object: nil)
                status = "Saved to Notes"
            }.disabled(noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        } message: { Text("Choose a title you’ll recognize in your notes list.") }
    }

    private func answerNote(title: String) -> Meeting {
        let sources = message.evidence.map { "[\($0.id)] \($0.title) — \($0.section)\n\($0.quote)" }.joined(separator: "\n\n")
        let question = sourceQuestion.map { "Question\n\($0)\n\n" } ?? ""
        return Meeting(
            id: UUID().uuidString,
            title: title,
            timestamp: Date().timeIntervalSince1970,
            manualNotes: question + message.content + (sources.isEmpty ? "" : "\n\nSources\n" + sources),
            transcript: "",
            summary: "",
            template: "Note"
        )
    }
}

struct EvidenceCards: View {
    let evidence: [AskEvidence]
    let answer: String
    var openSource: (AskEvidence) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources · \(evidence.count) retrieved").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(evidence) { source in
                        Button { openSource(source) } label: {
                            Text("[\(source.id)] \(source.title)").lineLimit(1)
                                .frame(maxWidth: 220).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain).help(source.title)
                    }
                }
            }
        }
    }
}
