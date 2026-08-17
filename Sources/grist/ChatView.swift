import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

enum ChatScope: Equatable {
    case item(Meeting)
    case global
    /// User-selected text only (from editor or summary).
    case selection(id: String, title: String, text: String)

    /// Per-item history so folder mates don’t share one thread with the open note.
    var historyKey: String {
        switch self {
        case .item(let m): return "item:\(m.id)"
        case .global: return "__global__"
        case .selection(let id, _, _): return "sel:\(id)"
        }
    }

    var emptyTitle: String {
        switch self {
        case .item: return "Ask about this note or meeting"
        case .global: return "Ask across your whole library"
        case .selection: return "Ask about your selection"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .item(let m):
            let name = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                return "Answers use this item’s AI summary, written notes, and transcript."
            }
            return "Answers use “\(name)” — AI summary, notes, and transcript."
        case .global:
            return "Semantic search + keywords across your library. Use Clear chat if a previous topic sticks."
        case .selection(_, let title, let text):
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
            return "Only the selected text from “\(title)” is used:\n\(short)"
        }
    }
}

struct ChatView: View {
    let scope: ChatScope
    let selectedModel: String
    let customModelName: String
    var onExitSelection: (() -> Void)? = nil

    @State private var chatHistory: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking = false
    /// Multi-thread history (ChatGPT / WhatsApp style).
    @State private var conversations: [ChatConversation] = []
    @State private var activeConversationId: String = ""
    @State private var threadSearch: String = ""
    @State private var showingThreadPicker = false
    @State private var renameConversationId: String? = nil
    @State private var renameConversationTitle: String = ""
    @State private var showingRenameAlert = false

    /// Cap per item when stuffing (characters).
    private let itemContextLimit = 80_000
    private let multiItemContextLimit = 14_000
    private let keywordHitLimit = 24_000

    private var activeConversation: ChatConversation? {
        conversations.first(where: { $0.id == activeConversationId })
            ?? Database.shared.fetchConversation(id: activeConversationId)
    }

    private var filteredConversations: [ChatConversation] {
        let q = threadSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return conversations }
        // Prefer DB search (title + message body) when user types
        return Database.shared.fetchConversations(scopeKey: scope.historyKey, search: q, limit: 80)
    }

    /// Readable column width for chat (avoids full-width walls of text).
    private let chatColumnMax: CGFloat = 720

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private var composerPlaceholder: String {
        switch scope {
        case .item: return "Ask about this note or meeting…"
        case .global: return "Ask across your library…"
        case .selection: return "Ask about the selection…"
        }
    }

    private var suggestionPrompts: [String] {
        switch scope {
        case .item:
            return [
                "What is the crux of this note?",
                "List key action items",
                "Summarize in 5 bullets",
            ]
        case .global:
            return [
                "What themes show up across my library?",
                "Find decisions I need to follow up on",
            ]
        case .selection:
            return [
                "Explain this in plain language",
                "What are the key points?",
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            chatToolbar

            if case .selection(_, _, let sel) = scope {
                selectionBanner(sel)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if chatHistory.isEmpty && !isThinking {
                            chatEmptyState
                                .padding(.top, 36)
                        } else {
                            ForEach(chatHistory) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        if isThinking {
                            ChatThinkingBubble()
                                .id("thinking")
                        }
                        Color.clear
                            .frame(height: 8)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: chatColumnMax)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.primary.opacity(0.02))
                .onChange(of: chatHistory.count) { _, _ in
                    scrollChatToBottom(proxy)
                }
                .onChange(of: isThinking) { _, _ in
                    scrollChatToBottom(proxy)
                }
            }

            chatComposer
        }
        .onAppear {
            bootstrapThreads()
        }
        .onChange(of: scope.historyKey) { _, _ in bootstrapThreads() }
    }

    private func scrollChatToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(isThinking ? "thinking" : "chat-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var chatToolbar: some View {
        HStack(spacing: 10) {
            if case .selection(_, let title, _) = scope {
                Label("Selection", systemImage: "text.quote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let onExitSelection {
                    Button("Exit") { onExitSelection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer(minLength: 8)
            }

            Button {
                threadSearch = ""
                reloadConversationList()
                showingThreadPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text(activeConversation?.title ?? "New chat")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Past chats — search and reopen any thread")
            .popover(isPresented: $showingThreadPicker, arrowEdge: .bottom) {
                threadPickerPopover
            }

            Spacer(minLength: 8)

            Button {
                startNewChat()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isThinking)

            Button {
                deleteCurrentChat()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isThinking || activeConversationId.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func selectionBanner(_ sel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Using selected text only")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.purple)
            Text(sel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.purple.opacity(0.08))
    }

    @ViewBuilder
    private var chatEmptyState: some View {
        VStack(spacing: 18) {
            GristEmptyState(
                systemImage: "bubble.left.and.bubble.right",
                title: scope.emptyTitle,
                message: scope.emptySubtitle,
                tint: .purple,
                badgeSize: 56
            )
            Text("History keeps past threads. New chat starts fresh.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // One-tap starters so the pane doesn’t feel empty
            VStack(alignment: .leading, spacing: 8) {
                Text("Try asking")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayoutChips(items: suggestionPrompts) { prompt in
                    inputText = prompt
                    sendMessage()
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chatComposer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField(composerPlaceholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .onSubmit { sendMessage() }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: chatColumnMax)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    // MARK: - Thread picker (searchable history)

    @ViewBuilder
    private var threadPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats…", text: $threadSearch)
                    .textFieldStyle(.plain)
                    .onChange(of: threadSearch) { _, _ in
                        // Live filter via filteredConversations
                    }
            }
            .padding(10)
            Divider()
            if filteredConversations.isEmpty {
                Text(threadSearch.isEmpty ? "No chats yet" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredConversations) { conv in
                            Button {
                                selectConversation(conv.id)
                                showingThreadPicker = false
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: conv.isPinned
                                          ? "pin.fill"
                                          : (conv.id == activeConversationId
                                             ? "bubble.left.and.bubble.right.fill"
                                             : "bubble.left.and.bubble.right"))
                                        .foregroundStyle(conv.isPinned ? .orange : (conv.id == activeConversationId ? Color.accentColor : .secondary))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conv.title)
                                            .font(.body.weight(conv.id == activeConversationId ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(relativeDate(conv.updatedAt))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .background(conv.id == activeConversationId ? Color.accentColor.opacity(0.1) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    renameConversationId = conv.id
                                    renameConversationTitle = conv.title
                                    showingRenameAlert = true
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }
                                Button {
                                    Database.shared.setConversationPinned(id: conv.id, pinned: !conv.isPinned)
                                    reloadConversationList()
                                } label: {
                                    Label(conv.isPinned ? "Unpin" : "Pin", systemImage: conv.isPinned ? "pin.slash" : "pin")
                                }
                                Button(role: .destructive) {
                                    Database.shared.deleteConversation(id: conv.id)
                                    reloadConversationList()
                                    if activeConversationId == conv.id {
                                        if let next = conversations.first {
                                            selectConversation(next.id)
                                        } else {
                                            startNewChat()
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
            Divider()
            Button {
                startNewChat()
                showingThreadPicker = false
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 360)
        .alert("Rename chat", isPresented: $showingRenameAlert) {
            TextField("Title", text: $renameConversationTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renameConversationId {
                    Database.shared.renameConversation(id: id, title: renameConversationTitle)
                    reloadConversationList()
                }
            }
        } message: {
            Text("Choose a short name for this thread.")
        }
    }

    private func relativeDate(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Thread lifecycle

    func bootstrapThreads() {
        reloadConversationList()
        if let first = conversations.first {
            activeConversationId = first.id
        } else {
            let c = Database.shared.createConversation(scopeKey: scope.historyKey)
            activeConversationId = c.id
            reloadConversationList()
        }
        loadActiveMessages()
    }

    func reloadConversationList() {
        conversations = Database.shared.fetchConversations(scopeKey: scope.historyKey, search: nil, limit: 100)
    }

    func loadActiveMessages() {
        guard !activeConversationId.isEmpty else {
            chatHistory = []
            return
        }
        chatHistory = Database.shared.fetchChatMessages(conversationId: activeConversationId)
    }

    func selectConversation(_ id: String) {
        activeConversationId = id
        loadActiveMessages()
        reloadConversationList()
    }

    /// New empty thread — does **not** delete past chats.
    func startNewChat() {
        // Reuse existing empty "New chat" if present at top
        if let empty = conversations.first(where: {
            $0.title == "New chat"
                && Database.shared.fetchChatMessages(conversationId: $0.id).isEmpty
        }) {
            selectConversation(empty.id)
            return
        }
        let c = Database.shared.createConversation(scopeKey: scope.historyKey)
        reloadConversationList()
        selectConversation(c.id)
    }

    /// Delete only the open thread.
    func deleteCurrentChat() {
        let id = activeConversationId
        guard !id.isEmpty else { return }
        Database.shared.deleteConversation(id: id)
        reloadConversationList()
        if let next = conversations.first {
            selectConversation(next.id)
        } else {
            let c = Database.shared.createConversation(scopeKey: scope.historyKey)
            reloadConversationList()
            selectConversation(c.id)
        }
    }

    /// Legacy name used elsewhere — now means “new chat” semantics.
    func clearChat() {
        startNewChat()
    }

    private func titleFromFirstMessage(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty else { return "New chat" }
        return t.count > 48 ? String(t.prefix(48)) + "…" : t
    }

    /// Fresh copy from DB so Write / Enhance updates are always included.
    private func freshMeeting(id: String, fallback: Meeting) -> Meeting {
        Database.shared.getMeeting(id: id) ?? fallback
    }

    private func contextMeetings() -> [Meeting] {
        let all = Database.shared.fetchActiveMeetings()
        switch scope {
        case .global:
            return all
        case .item(let meeting):
            let m = freshMeeting(id: meeting.id, fallback: meeting)
            return [m]
        case .selection:
            return []
        }
    }

    /// Prefer AI summary + written notes + transcript. Action / summary questions lean on Summary first.
    private func contextBlob(
        for m: Meeting,
        limit: Int,
        actionFocused: Bool = false,
        summaryFocused: Bool = false
    ) -> String {
        var parts: [String] = []
        let summary = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (m.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty { parts.append("### Folder\n\(folder)") }
        if !summary.isEmpty { parts.append("### AI Summary\n\(summary)") }

        if actionFocused || summaryFocused {
            // Prefer summary; only pull body/transcript when needed (keeps model on content, not noise)
            if !notes.isEmpty {
                let cap = summaryFocused ? 4_000 : 6_000
                let n = notes.count > cap ? String(notes.prefix(cap)) + "\n[…notes truncated…]" : notes
                if summary.isEmpty || (!summaryFocused && notes.count < 12_000) {
                    parts.append("### Notes (supporting)\n\(n)")
                } else if summaryFocused, summary.count < 400 {
                    parts.append("### Notes (supporting)\n\(n)")
                }
            }
            if summary.isEmpty, !transcript.isEmpty {
                let cap = summaryFocused ? 6_000 : 8_000
                let t = transcript.count > cap ? String(transcript.prefix(cap)) + "\n[…truncated…]" : transcript
                parts.append("### Transcript (supporting)\n\(t)")
            }
        } else {
            if !notes.isEmpty {
                let n = notes.count > 14_000 ? String(notes.prefix(14_000)) + "\n[…notes truncated…]" : notes
                parts.append("### Notes / article body\n\(n)")
            }
            if !transcript.isEmpty {
                // Cap huge YouTube mega-episodes so chat stays on topic
                let t = transcript.count > 10_000 ? String(transcript.prefix(10_000)) + "\n[…truncated…]" : transcript
                parts.append("### Transcript / captions\n\(t)")
            }
        }
        var blob = parts.joined(separator: "\n\n")
        if blob.count > limit {
            blob = String(blob.prefix(limit)) + "\n\n[…truncated…]"
        }
        return blob
    }

    /// User wants a summary / overview / “what is this about” — not a title list.
    private func isSummaryOrExplainQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        let keys = [
            "summary", "summarize", "summarise", "overview", "update", "explain",
            "what is", "what's", "whats", "about", "key points", "main points",
            "tell me", "describe", "recap", "tl;dr", "tldr", "gist",
            "how to", "how do", "what does", "walk me through",
        ]
        return keys.contains { l.contains($0) }
    }

    /// Assistant replies that are only note titles (bad model habit) — drop from history context.
    private func isTitleOnlyDump(_ content: String, knownTitles: [String]) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        // Very short, no sentence structure
        if t.count < 120, !t.contains("."), !t.contains("?") {
            return true
        }
        let lines = t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { return true }
        let titleSet = Set(knownTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let matching = lines.filter { titleSet.contains($0.lowercased()) }
        if matching.count == lines.count { return true }
        if matching.count >= 1, lines.count <= 3, t.count < 200 { return true }
        return false
    }

    /// User wants steps / advice / “what should I do” — stay in DOCUMENT, no generic coaching.
    private func isActionOrAdviceQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        let keys = [
            "what do i", "what should i", "need to do", "action", "steps", "plan",
            "advisor", "advice", "recommend", "next step", "how do i", "to-do", "todo",
            "give me what", "based on the content", "based on that",
        ]
        return keys.contains { l.contains($0) }
    }

    /// Locked list of real titles — copy exactly; do not invent.
    private func authoritativeTitleList(_ meetings: [Meeting], header: String) -> String {
        var lines = ["=== \(header) ===", "Copy TITLE= strings exactly. Do not invent titles.", ""]
        let sorted = meetings.sorted { $0.timestamp > $1.timestamp }
        if sorted.isEmpty {
            lines.append("(no matching notes)")
        } else {
            for (i, m) in sorted.enumerated() {
                let folder = m.groupName.map { " | folder=\($0)" } ?? " | folder=(none)"
                lines.append("\(i + 1). TITLE=\"\(m.title)\" | type=\(m.kindLabel)\(folder)")
            }
        }
        lines.append("=== END ===")
        return lines.joined(separator: "\n")
    }

    /// If the question names a real folder, return its items (case-insensitive, space-insensitive).
    private func meetingsMatchingFolderQuery(_ query: String, in all: [Meeting]) -> [Meeting]? {
        let folders = Set(all.compactMap { $0.groupName }.filter { !$0.isEmpty })
        guard !folders.isEmpty else { return nil }
        let q = query.lowercased()
        let qCompact = q.replacingOccurrences(of: " ", with: "")

        var best: String?
        var bestScore = 0
        for f in folders {
            let fl = f.lowercased()
            let fCompact = fl.replacingOccurrences(of: " ", with: "")
            var score = 0
            if q.contains(fl) { score += 10 }
            if qCompact.contains(fCompact) { score += 10 }
            // "financial planning" vs FinancialPlanning
            let parts = fl.replacingOccurrences(of: "planning", with: " planning")
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            for p in parts where q.contains(p) { score += 3 }
            if score > bestScore {
                bestScore = score
                best = f
            }
        }
        guard let folder = best, bestScore >= 6 else { return nil }
        let items = all.filter { ($0.groupName ?? "") == folder }
        return items.isEmpty ? nil : items
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        isThinking = true

        // Ensure we have a conversation thread
        if activeConversationId.isEmpty {
            let c = Database.shared.createConversation(scopeKey: scope.historyKey)
            activeConversationId = c.id
            reloadConversationList()
        }
        let convId = activeConversationId
        let group = scope.historyKey
        let isFirstMessage = chatHistory.isEmpty

        let userMsg = ChatMessage(
            id: UUID().uuidString,
            groupName: group,
            role: "user",
            content: text,
            timestamp: Date().timeIntervalSince1970,
            conversationId: convId
        )
        chatHistory.append(userMsg)
        Database.shared.saveChatMessage(userMsg)

        // Auto-title thread from first user message (like ChatGPT)
        if isFirstMessage {
            let title = titleFromFirstMessage(text)
            Database.shared.renameConversation(id: convId, title: title)
            reloadConversationList()
        }

        // Short history for weak models (listing questions shouldn't inherit hallucinations)
        let historySnapshot = Array(chatHistory.suffix(6))

        Task {
            do {
                // Role from scope; model from dropdown (kept in sync with ai-config.json).
                let chatRole: AIRole = {
                    if case .global = scope { return .askEverything }
                    return .chat
                }()
                let model = await MainActor.run {
                    if selectedModel == "custom", !customModelName.isEmpty { return customModelName }
                    let fromPicker = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fromPicker.isEmpty, fromPicker != "No models found", fromPicker != "Ollama not running" {
                        return fromPicker
                    }
                    return AIConfigManager.shared.modelName(for: chatRole)
                }
                let meetingsInContext = contextMeetings()

                var documentBlock = ""
                var titleInventory = ""
                /// Titles shown under the answer (RAG / document sources).
                var answerSources: [String] = []

                switch scope {
                case .selection(_, let title, let selText):
                    let body = selText.trimmingCharacters(in: .whitespacesAndNewlines)
                    documentBlock = """
                    === USER SELECTION from “\(title)” ===
                    (Answer ONLY using this selection. Ignore any other knowledge.)

                    \(body.isEmpty ? "(empty selection)" : body)
                    """
                    titleInventory = "SELECTION source title: \"\(title)\""
                    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        answerSources = [title]
                    }

                case .item(let meeting):
                    let m = meetingsInContext.first ?? meeting
                    titleInventory = authoritativeTitleList([m], header: "AUTHORITATIVE TITLE (this item only)")
                    let blob = contextBlob(for: m, limit: itemContextLimit)
                    if blob.isEmpty {
                        documentBlock = titleInventory + "\n\n(No summary, notes, or transcript saved on this item yet.)"
                    } else {
                        documentBlock = """
                        \(titleInventory)

                        === OPEN ITEM CONTENT: \(m.kindLabel) — \(m.title) ===
                        \(blob)
                        """
                    }
                    let t = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    answerSources = [t.isEmpty ? "This item" : t]

                case .global:
                    let actionFocused = isActionOrAdviceQuery(text)
                    let summaryFocused = isSummaryOrExplainQuery(text)
                    let listingish =
                        text.lowercased().contains("title")
                        || text.lowercased().contains("list")
                        || text.lowercased().contains("folder")
                        || text.lowercased().contains("which notes")
                        || text.lowercased().contains("what notes")

                    // Prefer exact folder membership when the question names a folder
                    if let folderItems = meetingsMatchingFolderQuery(text, in: meetingsInContext) {
                        let folderName = folderItems.first?.groupName ?? "folder"
                        titleInventory = authoritativeTitleList(
                            folderItems,
                            header: "NOTES IN FOLDER \"\(folderName)\" (use content below — do not only list titles)"
                        )
                        documentBlock = titleInventory + "\n\n"
                        documentBlock += "=== FULL CONTENT FOR THESE NOTES ONLY ===\n"
                        for m in folderItems.sorted(by: { $0.timestamp > $1.timestamp }) {
                            let blob = contextBlob(
                                for: m,
                                limit: keywordHitLimit,
                                actionFocused: actionFocused,
                                summaryFocused: summaryFocused
                            )
                            documentBlock += "\n--- NOTE TITLE=\"\(m.title)\" ---\n\(blob.isEmpty ? "(empty body)" : blob)\n"
                        }
                        answerSources = folderItems.map(\.title).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    } else {
                        let scored = RAGEngine.shared.rankMeetingsByKeywordsScored(meetingsInContext, query: text)
                        var ranked = RAGEngine.shared.rankMeetingsByKeywords(
                            meetingsInContext,
                            query: text,
                            topK: actionFocused || summaryFocused ? 5 : 6,
                            minScoreRatio: 0.35,
                            absoluteMinScore: 8
                        )
                        if ranked.isEmpty, let first = scored.first {
                            ranked = [first.meeting]
                        }
                        answerSources = ranked.map(\.title).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                        // Whole-library title dump only when user asks for a list
                        if listingish {
                            titleInventory = authoritativeTitleList(
                                meetingsInContext,
                                header: "AUTHORITATIVE TITLES — ENTIRE LIBRARY"
                            )
                            documentBlock = titleInventory + "\n\n"
                            documentBlock += authoritativeTitleList(
                                ranked,
                                header: "BEST MATCHES FOR THIS QUESTION"
                            ) + "\n\n"
                        } else {
                            // Normal Q&A: best matches only (prevents title-echo answers)
                            titleInventory = authoritativeTitleList(
                                ranked,
                                header: "NOTES TO USE (cite in prose; answer from content)"
                            )
                            documentBlock = titleInventory + "\n\n"
                        }

                        documentBlock += "=== SOURCE CONTENT (prefer AI Summary) ===\n"
                        for m in ranked {
                            let blob = contextBlob(
                                for: m,
                                limit: summaryFocused ? 12_000 : keywordHitLimit,
                                actionFocused: actionFocused,
                                summaryFocused: summaryFocused || actionFocused
                            )
                            if blob.isEmpty { continue }
                            documentBlock += "\n--- NOTE TITLE=\"\(m.title)\" ---\n\(blob)\n"
                        }

                        if !summaryFocused, !actionFocused {
                            let meetingIds = ranked.map(\.id)
                            if !meetingIds.isEmpty {
                                do {
                                    let topChunks = try await RAGEngine.shared.search(
                                        query: text,
                                        meetingIds: meetingIds,
                                        topK: 8,
                                        maxPerMeeting: 2
                                    )
                                    if !topChunks.isEmpty {
                                        documentBlock += "\n=== SEMANTIC EXCERPTS ===\n"
                                        for chunk in topChunks {
                                            let parentTitle = ranked.first(where: { $0.id == chunk.meetingId })?.title ?? "Unknown"
                                            documentBlock += "[TITLE=\"\(parentTitle)\"]:\n\(chunk.text)\n\n"
                                        }
                                    }
                                } catch {
                                    print("[Chat] RAG search failed: \(error)")
                                }
                            }
                        }
                    }
                }

                let actionFocused = isActionOrAdviceQuery(text)
                let summaryFocused = isSummaryOrExplainQuery(text)
                let listingish =
                    text.lowercased().contains("title")
                    || text.lowercased().contains("list")
                    || text.lowercased().contains("folder")
                    || text.lowercased().contains("which notes")
                    || text.lowercased().contains("what notes")

                var systemPrompt = """
                You are a library Q&A assistant. Answer using DOCUMENT only.

                CRITICAL — answer quality:
                - NEVER reply with only note titles. Titles alone are not an answer.
                - Write a real answer: multiple sentences, or bullets with substance from AI Summary / notes.
                - When the user asks for a summary, update, overview, or “how to…”, synthesize the content.
                - Prefer ### AI Summary sections when present.
                - If you name a note, use its TITLE= string exactly — but always add what the note says.
                - Do NOT invent notes or a Sources list (the app attaches sources).
                """
                if actionFocused {
                    systemPrompt += """

                    For this question: numbered actions only. Each action must cite a real note title and an idea from DOCUMENT. No generic advice that is not in DOCUMENT.
                    """
                }
                if summaryFocused {
                    systemPrompt += """

                    For this question: provide a clear summary of the relevant note(s). Structure with short bullets or short paragraphs. Include key ideas, not just the title.
                    """
                }
                if listingish {
                    systemPrompt += """

                    For this question: list matching note titles from DOCUMENT, each with a one-line description from content when available.
                    """
                }

                let knownTitles = meetingsInContext.map(\.title)
                let skipHistory = listingish || actionFocused
                    || historySnapshot.contains {
                        $0.role == "assistant" && isTitleOnlyDump($0.content, knownTitles: knownTitles)
                    }

                var apiMessages: [OllamaClient.OllamaChatMessage] = [
                    OllamaClient.OllamaChatMessage(role: "system", content: systemPrompt),
                ]
                if !skipHistory {
                    for msg in historySnapshot.dropLast() {
                        if msg.role == "assistant", isTitleOnlyDump(msg.content, knownTitles: knownTitles) {
                            continue
                        }
                        apiMessages.append(OllamaClient.OllamaChatMessage(role: msg.role, content: msg.content))
                    }
                }
                let docPayload = documentBlock.contains("TITLE=")
                    ? documentBlock
                    : "\(titleInventory)\n\n\(documentBlock)"
                let answerShape: String = {
                    if actionFocused {
                        return "Reply with numbered actions tied to real titles and content from DOCUMENT."
                    }
                    if summaryFocused {
                        return "Write a useful multi-sentence or multi-bullet summary from DOCUMENT content. Do not answer with titles only."
                    }
                    if listingish {
                        return "List matching notes with a short description from content when possible."
                    }
                    return "Write a useful answer from DOCUMENT content (paragraphs or bullets). Do not answer with titles only."
                }()
                apiMessages.append(
                    OllamaClient.OllamaChatMessage(
                        role: "user",
                        content: """
                        DOCUMENT:
                        \(docPayload)

                        QUESTION: \(text)

                        \(answerShape)
                        """
                    )
                )

                var response = try await OllamaClient.shared.chat(
                    messages: apiMessages,
                    model: model,
                    role: chatRole
                )

                // Retry once if the model still dumps titles only
                if isTitleOnlyDump(response.content, knownTitles: answerSources + knownTitles) {
                    GristLog.log("[Chat] title-only reply; retrying with stricter instruction")
                    var retry = apiMessages
                    retry.append(OllamaClient.OllamaChatMessage(role: "assistant", content: response.content))
                    retry.append(OllamaClient.OllamaChatMessage(
                        role: "user",
                        content: """
                        That reply was only title(s). Rewrite now as a full answer using the AI Summary / content in DOCUMENT.
                        At least 4 bullet points or 3 full sentences. Still no invented sources list.
                        """
                    ))
                    response = try await OllamaClient.shared.chat(
                        messages: retry,
                        model: model,
                        role: chatRole
                    )
                }

                await MainActor.run {
                    // Deduplicate sources, cap list for UI
                    var seen = Set<String>()
                    let sources = answerSources.filter { s in
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty, !seen.contains(t) else { return false }
                        seen.insert(t)
                        return true
                    }.prefix(8).map { $0 }

                    let aiMsg = ChatMessage(
                        id: UUID().uuidString,
                        groupName: group,
                        role: "assistant",
                        content: response.content,
                        timestamp: Date().timeIntervalSince1970,
                        conversationId: convId,
                        sources: Array(sources)
                    )
                    chatHistory.append(aiMsg)
                    Database.shared.saveChatMessage(aiMsg)
                    reloadConversationList()
                    isThinking = false
                }
            } catch {
                await MainActor.run {
                    let errorMsg = ChatMessage(
                        id: UUID().uuidString,
                        groupName: group,
                        role: "assistant",
                        content: "Error: \(error.localizedDescription)",
                        timestamp: Date().timeIntervalSince1970,
                        conversationId: convId
                    )
                    chatHistory.append(errorMsg)
                    // Still persist error so the thread shows what happened
                    Database.shared.saveChatMessage(errorMsg)
                    isThinking = false
                }
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }
    private var isError: Bool {
        message.content.hasPrefix("Error:")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 48) }

            if !isUser {
                // Assistant avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isError
                                    ? [Color.red.opacity(0.85), Color.orange.opacity(0.7)]
                                    : [Color.purple, Color.blue.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                    Image(systemName: isError ? "exclamationmark" : "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 2)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                if !isUser {
                    Text(isError ? "Error" : "Grist")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Group {
                    if isUser {
                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        chatMarkdownText(message.content)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(bubbleStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(isUser ? 0.12 : 0.04), radius: isUser ? 6 : 4, y: 2)
                .frame(maxWidth: isUser ? 480 : 600, alignment: isUser ? .trailing : .leading)

                if !isUser, !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Sources", systemImage: "link")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowSourceChips(titles: message.sources)
                    }
                    .padding(.leading, 2)
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            LinearGradient(
                colors: [Color.blue, Color.purple.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if isError {
            Color.red.opacity(0.08)
        } else {
            Color(NSColor.controlBackgroundColor)
        }
    }

    private var bubbleStroke: Color {
        if isUser { return Color.clear }
        if isError { return Color.red.opacity(0.25) }
        return Color.primary.opacity(0.08)
    }

    @ViewBuilder
    private func chatMarkdownText(_ raw: String) -> some View {
        if let attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attr)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(3)
        } else {
            Text(raw)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(3)
        }
    }
}

struct ChatThinkingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.2))
                    .frame(width: 28, height: 28)
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Grist")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            Spacer(minLength: 48)
        }
    }
}

/// Source chips (horizontal scroll).
struct FlowSourceChips: View {
    let titles: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(titles, id: \.self) { title in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                        Text(title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                    .help(title)
                }
            }
        }
    }
}

/// Prompt suggestion chips (wrap in rows of ~2 for empty state).
struct FlowLayoutChips: View {
    let items: [String]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunked(items, size: 2), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { title in
                        chip(title)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ title: String) -> some View {
        Button {
            onTap?(title)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.12))
            .foregroundStyle(.purple)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.purple.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private func chunked(_ arr: [String], size: Int) -> [[String]] {
        guard size > 0, !arr.isEmpty else { return [] }
        var out: [[String]] = []
        var i = 0
        while i < arr.count {
            let end = min(i + size, arr.count)
            out.append(Array(arr[i..<end]))
            i = end
        }
        return out
    }
}

// MARK: - Create Item Sheet (self-contained kind state)

/// Owns Meeting/Note selection locally so parent state can never force "Meeting".
