import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: Note-focused UI (writing surface)

    @ViewBuilder
    var noteDetailView: some View {
        VStack(spacing: 0) {
            // Compact note chrome
            HStack(spacing: 12) {
                Picker("", selection: $selectedTab) {
                    Text("Write").tag("notes")
                    Text("AI Summary").tag("summary")
                    Text("Chat").tag("chat")
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                if selectedTab == "summary" || selectedTab == "notes" {
                    noteAIControls
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            if let m = selectedMeeting {
                noteMetadataBar(for: m)
            }

            Divider()

            if selectedTab == "notes" {
                noteWritingSurface
            } else if selectedTab == "summary" {
                if let summary = selectedMeeting?.summary, !summary.isEmpty {
                    VStack(spacing: 0) {
                        summarySpeechBar(text: summary)
                        MarkdownView.summary(summary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    noteEmptyAIState
                }
            } else if selectedTab == "chat", let m = selectedMeeting {
                if let sel = selectionChat {
                    ChatView(
                        scope: .selection(id: sel.id, title: sel.title, text: sel.text),
                        selectedModel: selectedModel,
                        customModelName: customModelName,
                        onExitSelection: { selectionChat = nil }
                    )
                    .id("sel-\(sel.id)")
                } else {
                    ChatView(scope: .item(m), selectedModel: selectedModel, customModelName: customModelName)
                        .id(m.id)
                }
            } else {
                noteWritingSurface
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if selectedTab == "transcript" || (selectedTab == "summary" && (selectedMeeting?.summary.isEmpty ?? true)) {
                selectedTab = "notes"
            }
        }
        .onChange(of: selectedMeeting?.id) { _, _ in
            selectionChat = nil
            noteSelectedText = ""
        }
    }

    @ViewBuilder
    var noteWritingSurface: some View {
        VStack(spacing: 0) {
            // Slim format bar
            HStack(spacing: 10) {
                MarkdownFormatToolbar(pendingFormat: $noteFormatCommand)
                Spacer(minLength: 8)
                if !noteSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        startSelectionChat(text: noteSelectedText, title: selectedMeeting?.title ?? "Note")
                    } label: {
                        Label("Chat with selection", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .help("Open Chat using only the highlighted text")
                }
                Picker("", selection: $noteShowPreview) {
                    Image(systemName: "square.and.pencil").tag(false)
                    Image(systemName: "doc.richtext").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 88)
                .help(noteShowPreview ? "Switch to edit" : "Preview markdown")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            if noteShowPreview {
                noteReadingView
            } else {
                noteEditingView
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    /// Full-width reading layout — title + body span the whole detail pane.
    @ViewBuilder
    var noteReadingView: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(selectedMeeting?.title.isEmpty == false ? (selectedMeeting?.title ?? "") : "Untitled")
                        .font(.system(size: 28, weight: .bold, design: .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)

                    if let m = selectedMeeting {
                        let links = extractSourceURLs(from: m.manualNotes)
                        if !links.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(links, id: \.self) { link in
                                    noteSourceCard(urlString: link, isYouTube: isYouTubeLink(link))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(width: geo.size.width, alignment: .leading)

                Divider()

                if let body = selectedMeeting?.manualNotes, !body.isEmpty {
                    let display = stripSourceHeader(from: body)
                    MarkdownView(markdown: display, bodyFontSize: 16, contentPadding: 24)
                        .frame(width: geo.size.width, height: max(200, geo.size.height - 160), alignment: .topLeading)
                } else {
                    Text("Nothing to preview yet — switch to edit and write.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    var noteEditingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Note title", text: Binding(
                get: { selectedMeeting?.title ?? "" },
                set: { selectedMeeting?.title = $0; saveMeeting() }
            ), axis: .vertical)
            .font(.system(size: 26, weight: .bold, design: .default))
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let m = selectedMeeting {
                let links = extractSourceURLs(from: m.manualNotes)
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(links, id: \.self) { link in
                            noteSourceCard(urlString: link, isYouTube: isYouTubeLink(link))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 4)

            ZStack(alignment: .topLeading) {
                if (selectedMeeting?.manualNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Start writing…\n\nSelect text and use the toolbar for **bold**, lists, and more.")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }

                MarkdownNoteEditor(
                    text: Binding(
                        get: { selectedMeeting?.manualNotes ?? "" },
                        set: { selectedMeeting?.manualNotes = $0; saveMeeting() }
                    ),
                    pendingFormat: $noteFormatCommand,
                    selectedText: $noteSelectedText,
                    fontSize: 16
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    func noteSourceCard(urlString: String, isYouTube: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isYouTube ? "play.rectangle.fill" : "link.circle.fill")
                .font(.title2)
                .foregroundStyle(isYouTube ? .red : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYouTube ? "YouTube source" : "Web source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(urlString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(urlString)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Button {
                copyToPasteboard(urlString)
                statusMessage = "Link copied"
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy link to clipboard")
            Button("Open") {
                if let u = URL(string: urlString) {
                    NSWorkspace.shared.open(u)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open in browser")
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Link") {
                copyToPasteboard(urlString)
                statusMessage = "Link copied"
            }
            Button("Open in Browser") {
                if let u = URL(string: urlString) {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    func isYouTubeLink(_ link: String) -> Bool {
        link.localizedCaseInsensitiveContains("youtube.com") || link.localizedCaseInsensitiveContains("youtu.be")
    }

    /// Pull first markdown link or raw URL from note (legacy helpers).
    func extractSourceURL(from notes: String) -> String? {
        extractSourceURLs(from: notes).first
    }

    /// Source / YouTube links meant for the copiable header cards (not every URL in the body).
    func extractSourceURLs(from notes: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = s.last, ".,;:)]}>\"'".contains(last) { s.removeLast() }
            s = s.replacingOccurrences(of: "&amp;", with: "&")
            guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return }
            if seen.insert(s).inserted { found.append(s) }
        }

        // Explicit import markers we write: [Source](…), [Open on YouTube](…)
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\((https?://[^)\s]+)\)"#) {
            let ns = notes as NSString
            for m in regex.matches(in: notes, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges >= 3 else { continue }
                let label = ns.substring(with: m.range(at: 1)).lowercased()
                let url = ns.substring(with: m.range(at: 2))
                if label.contains("source")
                    || label.contains("youtube")
                    || label.contains("open")
                    || label.hasPrefix("http") {
                    add(url)
                }
            }
        }

        // Fallback: first bare URL near the top of the note
        if found.isEmpty {
            let head = String(notes.prefix(800))
            if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"'`\[\]{}|\\^]+"#) {
                let ns = head as NSString
                if let m = regex.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
                    add(ns.substring(with: m.range))
                }
            }
        }

        return found
    }

    /// Remove leading source markdown link lines so reading view isn't redundant with the card.
    func stripSourceHeader(from notes: String) -> String {
        var lines = notes.components(separatedBy: .newlines)
        while let first = lines.first {
            let t = first.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.removeFirst(); continue }
            if t.hasPrefix("[Open on YouTube]") || t.hasPrefix("[Source]") { lines.removeFirst(); continue }
            if t.lowercased().hasPrefix("source:") { lines.removeFirst(); continue }
            if t.lowercased().hasPrefix("captions:") { lines.removeFirst(); continue }
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var noteAIControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedModel) {
                ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                openImportSheet(appendToCurrent: true)
            } label: {
                Label("Add URL", systemImage: "link.badge.plus")
            }
            .help("Fetch a page or YouTube captions into this note")
            .disabled(isImportingUrl || selectedMeeting == nil)

            Button {
                attachFilesToCurrentNote()
            } label: {
                Label(isAttachingFiles ? "Attaching…" : "Attach file", systemImage: "doc.badge.plus")
            }
            .help("Append .md, .txt, or .pdf text into this note for AI")
            .disabled(isAttachingFiles || selectedMeeting == nil)

            Button {
                let title = selectedMeeting?.title ?? "Note"
                startSelectionChat(text: noteSelectedText, title: title)
            } label: {
                Label("Chat selection", systemImage: "text.quote")
            }
            .help("Select text in Write, then chat only about that selection")
            .disabled(noteSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .tint(.purple)

            Button {
                generateAutoTitle(force: true)
            } label: {
                Label("Title", systemImage: "textformat")
            }
            .help("Generate title from note body")
            .disabled(noteBodyEmpty)

            Button {
                extractTasksFromCurrent()
            } label: {
                Label(isExtractingTasks ? "Tasks…" : "Tasks", systemImage: "checklist")
            }
            .help("Extract action items into Tasks")
            .disabled(isExtractingTasks || noteBodyEmpty)

            enhanceToolbarButton(
                title: statusMessage == "Enhancing…" ? "Working…" : "Enhance",
                disabled: statusMessage == "Enhancing…" || noteBodyEmpty,
                help: "AI summary + title from what you wrote"
            )
        }
    }

    var noteBodyEmpty: Bool {
        let t = selectedMeeting?.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tr = selectedMeeting?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let s = selectedMeeting?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasTranscript = !tr.isEmpty && !tr.hasPrefix("[Error")
        return t.isEmpty && s.isEmpty && !hasTranscript
    }

    @ViewBuilder
    var noteEmptyAIState: some View {
        VStack(spacing: 18) {
            QuernEmptyState(
                systemImage: "sparkles.rectangle.stack",
                title: "No AI summary yet",
                message: "Write in the Write tab, then tap Enhance for a structured summary and auto-title.",
                tint: .blue
            )
            Button {
                selectedTab = "notes"
            } label: {
                Label("Back to writing", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func noteMetadataBar(for m: Meeting) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                metaChip(icon: "note.text", text: "Note")
                metaChip(icon: "calendar", text: m.formattedCreated)
                if let folder = m.groupName, !folder.isEmpty {
                    metaChip(icon: "folder.fill", text: folder)
                } else {
                    metaChip(icon: "tray", text: "Unfiled")
                }
                let words = m.manualNotes.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
                if words > 0 {
                    metaChip(icon: "text.alignleft", text: "\(words) words")
                }
                if extractSourceURLs(from: m.manualNotes).contains(where: { isYouTubeLink($0) }) {
                    metaChip(icon: "play.rectangle.fill", text: "YouTube")
                }
                if m.isPlaceholderTitle && !noteBodyEmpty {
                    Button {
                        generateAutoTitle(force: true)
                    } label: {
                        Label("Auto-title", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color.blue.opacity(0.04))
    }
}
