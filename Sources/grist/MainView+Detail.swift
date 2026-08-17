import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Detail

    @ViewBuilder
    var detailContent: some View {
        Group {
            if selectedMeeting?.isNoteType == true {
                noteDetailView
            } else {
                meetingDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { detailToolbar }
    }

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

    func startSelectionChat(text: String, title: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            statusMessage = "Select some text first"
            return
        }
        let id = "\(selectedMeeting?.id ?? "note")-\(abs(t.hashValue))"
        selectionChat = (id: id, title: title, text: t)
        selectedTab = "chat"
        statusMessage = "Chat scoped to selection"
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
            GristEmptyState(
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

    // MARK: Meeting-focused UI

    @ViewBuilder
    var meetingDetailView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $selectedTab) {
                    Text("Summary").tag("summary")
                    Text("Notes").tag("notes")
                    Text("Transcript").tag("transcript")
                    Text("Chat").tag("chat")
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                aiConfigControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            if let m = selectedMeeting {
                metadataBar(for: m)
            }

            Divider()

            if let suggestion = suggestedGroup, (selectedMeeting?.groupName?.isEmpty ?? true) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Suggested Folder: **\(suggestion)**")
                    Spacer()
                    Button("Accept") {
                        if var m = selectedMeeting {
                            m.groupName = suggestion
                            db.saveFolder(suggestion)
                            db.saveMeeting(m)
                            loadMeetings()
                            suggestedGroup = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.purple.opacity(0.1))
            }

            aiContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    var manualNotesView: some View {
        // Meeting detail “Notes” tab — write freely; Add URL appends articles/YouTube into this same item
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes for this meeting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Your thoughts, follow-ups, and anything you paste here are included when you Enhance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !noteSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        startSelectionChat(text: noteSelectedText, title: selectedMeeting?.title ?? "Meeting")
                    } label: {
                        Label("Chat selection", systemImage: "text.quote")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
                Button {
                    openImportSheet(appendToCurrent: true)
                } label: {
                    Label("Add URL", systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import an article or YouTube captions into this meeting")
                .disabled(isImportingUrl || selectedMeeting == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            MarkdownNoteEditor(
                text: Binding(
                    get: { selectedMeeting?.manualNotes ?? "" },
                    set: { selectedMeeting?.manualNotes = $0; saveMeeting() }
                ),
                pendingFormat: $noteFormatCommand,
                selectedText: $noteSelectedText,
                fontSize: 15
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    func metadataBar(for m: Meeting) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                metaChip(icon: m.isNoteType ? "note.text" : "waveform", text: m.kindLabel)
                metaChip(icon: "calendar", text: m.formattedCreated)
                if let dur = m.formattedDuration {
                    metaChip(icon: "timer", text: dur)
                }
                if let folder = m.groupName, !folder.isEmpty {
                    metaChip(icon: "folder.fill", text: folder)
                } else {
                    metaChip(icon: "tray", text: "Unfiled")
                }
                if !m.transcript.isEmpty {
                    let words = m.transcript.split { $0.isWhitespace || $0.isNewline }.count
                    if words > 0 {
                        metaChip(icon: "text.alignleft", text: "\(words) words")
                    }
                }
                if m.isPlaceholderTitle && !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error") {
                    Button {
                        generateAutoTitle(force: true)
                    } label: {
                        Label("Auto-title", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Generate a title from the content")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.03))
    }

    func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(Capsule())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    var aiConfigControls: some View {
        HStack(spacing: 8) {
            // Model picker
            Picker("", selection: $selectedModel) {
                ForEach(presetModels, id: \.self) { m in
                    Text(m).tag(m)
                }
                Divider()
                Text("Custom…").tag("custom")
            }
            .labelsHidden()
            .frame(width: 120)
            .help("Synced with Settings → AI Models (\(currentModelPickerRole().label))")

            if selectedModel == "custom" {
                TextField("model:tag", text: $customModelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            // Template picker
            Picker("", selection: $selectedTemplate) {
                ForEach(templates, id: \.self) { t in
                    Text(t).tag(t)
                }
                if !customTemplates.isEmpty {
                    Divider()
                    ForEach(customTemplates) { ct in
                        Text(ct.name).tag(ct.name)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Button {
                openImportSheet(appendToCurrent: true)
            } label: {
                Label("Add URL", systemImage: "link.badge.plus")
            }
            .help("Append article or YouTube content to this meeting")
            .disabled(isImportingUrl || selectedMeeting == nil)
            .controlSize(.regular)

            // Enhance button & Auto toggle
            Toggle("Auto", isOn: $autoEnhance)
                .toggleStyle(.checkbox)
                .help("Automatically enhance after recording stops")
            
            Button {
                extractTasksFromCurrent()
            } label: {
                Label(isExtractingTasks ? "Tasks…" : "Tasks", systemImage: "checklist")
            }
            .help("Extract action items into Tasks")
            .disabled(isExtractingTasks || !meetingHasEnhanceableContent)
            .controlSize(.regular)

            enhanceToolbarButton(
                title: statusMessage == "Enhancing…" ? "Enhancing…" : "Enhance",
                disabled: statusMessage == "Enhancing…" || !meetingHasEnhanceableContent,
                help: "Generate structured AI summary from transcript and notes"
            )
            .controlSize(.regular)
        }
    }

    /// Prominent Enhance control that stays readable in light and dark mode.
    /// System `.borderedProminent` + blue tint often yields an empty blue pill in dark appearance.
    @ViewBuilder
    func enhanceToolbarButton(title: String, disabled: Bool, help: String) -> some View {
        Button {
            runEnhance()
        } label: {
            HStack(spacing: 6) {
                if statusMessage == "Enhancing…" {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: disabled
                        ? [Color.gray.opacity(0.45), Color.gray.opacity(0.35)]
                        : [Color.blue, Color.purple.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.75 : 1)
        .help(help)
    }

    /// Meeting can enhance from transcript and/or written notes.
    var meetingHasEnhanceableContent: Bool {
        guard let m = selectedMeeting else { return false }
        let t = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("[Error") { return true }
        return !n.isEmpty
    }

    /// Play AI summary aloud (macOS system voice).
    @ViewBuilder
    func summarySpeechBar(text: String) -> some View {
        SummarySpeechBar(text: text)
    }

    @ViewBuilder
    var aiContentView: some View {
        switch selectedTab {
        case "summary":
            if let summary = selectedMeeting?.summary, !summary.isEmpty {
                VStack(spacing: 0) {
                    summarySpeechBar(text: summary)
                    MarkdownView.summary(summary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                aiEmptyState(
                    icon: "wand.and.stars",
                    title: "No Summary Yet",
                    subtitle: "Select a model and template above, then tap Enhance to generate structured notes."
                )
            }
        case "notes":
            manualNotesView
        case "chat":
            if let m = selectedMeeting {
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
            }
        case "transcript":
            if let transcript = selectedMeeting?.transcript, !transcript.isEmpty {
                MarkdownView(markdown: transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                aiEmptyState(
                    icon: "waveform",
                    title: "No Transcript",
                    subtitle: "Record a meeting using the toolbar button. The transcript will appear here automatically."
                )
            }
        default:
            EmptyView()
        }
    }

    func aiEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Empty Detail

    var emptyDetailPlaceholder: some View {
        VStack(spacing: 22) {
            GristEmptyState(
                systemImage: "square.stack.3d.up",
                title: "Nothing selected",
                message: "Capture a meeting, jot a note, or pick something from the sidebar.",
                tint: .accent,
                badgeSize: 80
            )

            HStack(spacing: 14) {
                emptyCreateCard(kind: .meeting)
                emptyCreateCard(kind: .note)
                emptyCreateCard(kind: .article)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    func emptyCreateCard(kind: CreateKind) -> some View {
        Button {
            openCreateSheet(kind: kind)
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(kind.accent.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: kind.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(kind.accent)
                }
                Text(kind.title)
                    .font(.headline)
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 140)
            }
            .padding(20)
            .frame(width: 180, height: 160)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(kind.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    func sidebarCreateButton(kind: CreateKind) -> some View {
        Button {
            openCreateSheet(kind: kind)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind == .meeting ? "plus.circle.fill" : "square.and.pencil")
                Text(kind.title)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(kind.accent.opacity(0.12))
            .foregroundStyle(kind.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(kind.accent.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(kind.subtitle)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                openCreateSheet(kind: .meeting)
            } label: {
                Label("New", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Create meeting or note (⌘N)")
        }
    }

    @ToolbarContentBuilder
    var detailToolbar: some ToolbarContent {
        // Editable title in toolbar centre
        ToolbarItem(placement: .principal) {
            TextField("Title", text: Binding(
                get: { selectedMeeting?.title ?? "" },
                set: { selectedMeeting?.title = $0; saveMeeting() }
            ))
            .font(.headline)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .frame(maxWidth: 340)
        }

        // Recording status indicator — always has a frame to avoid zero-size warning
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(.red.opacity(0.3), lineWidth: 4)
                                .scaleEffect(1.6)
                                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isRecording)
                        )
                    Text(formattedDuration(recordingSeconds))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(minWidth: 44)
                } else {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44)
                }
            }
            .frame(minWidth: 60)
        }

        // Export & Record / Note actions
        ToolbarItemGroup(placement: .primaryAction) {
            if let m = selectedMeeting {
                Menu {
                    Button {
                        openExportSheet(meeting: m)
                    } label: {
                        Label("Export Markdown…", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button {
                        sendToObsidian(meeting: m)
                    } label: {
                        Label("Send to Obsidian", systemImage: "book.closed")
                    }
                    .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                    .help(IntegrationsConfigManager.shared.config.obsidian.isConfigured
                          ? "Write Markdown into your Obsidian vault"
                          : "Enable and pick a vault in Settings → Integrations")
                    if let folder = m.groupName, !folder.isEmpty {
                        Divider()
                        Button {
                            openFolderSummarize(name: folder)
                        } label: {
                            Label("Summarize Folder “\(folder)”…", systemImage: "sparkles")
                        }
                        Button {
                            openExportSheet(folder: folder)
                        } label: {
                            Label("Export Folder “\(folder)”…", systemImage: "folder")
                        }
                        Button {
                            sendFolderToObsidian(folder)
                        } label: {
                            Label("Send Folder to Obsidian…", systemImage: "book.closed")
                        }
                        .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export Markdown or send to Obsidian")
            }

            if selectedMeeting?.isNoteType == true {
                // Notes: recording is optional / secondary
                Button {
                    toggleRecording()
                } label: {
                    Label(isRecording ? "Stop" : "Record audio", systemImage: isRecording ? "stop.circle.fill" : "mic")
                }
                .help(isRecording ? "Stop and attach transcript" : "Optional: record audio into this note")
            } else {
                Button {
                    toggleRecording()
                } label: {
                    Label(
                        isRecording ? "Stop Recording" : "Record",
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .symbolRenderingMode(.multicolor)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .help(isRecording ? "Stop and transcribe" : "Start recording")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Create Sheet helpers

    /// Default create folder: Unfiled (don't inherit sidebar focus — that mis-filed YT into Cooking).
    func preferredCreateFolder() -> String {
        ""
    }

    /// Open create sheet; kind is owned entirely by the sheet view.
    func openCreateSheet(kind: CreateKind) {
        createSheetRequest = CreateSheetRequest(kind: kind)
    }

    func folderChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

}
