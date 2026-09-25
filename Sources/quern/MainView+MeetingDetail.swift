import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
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
                Button {
                    attachFilesToCurrentNote()
                } label: {
                    Label(isAttachingFiles ? "Attaching…" : "Attach file", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Append .md, .txt, or .pdf text into these notes for AI")
                .disabled(isAttachingFiles || selectedMeeting == nil)
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

            Button {
                attachFilesToCurrentNote()
            } label: {
                Label(isAttachingFiles ? "Attaching…" : "Attach file", systemImage: "doc.badge.plus")
            }
            .help("Append .md, .txt, or .pdf text into notes for AI")
            .disabled(isAttachingFiles || selectedMeeting == nil)
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

    /// Meeting can enhance from transcript and/or written notes.
    var meetingHasEnhanceableContent: Bool {
        guard let m = selectedMeeting else { return false }
        let t = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("[Error") { return true }
        return !n.isEmpty
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
            liveOrSavedTranscriptView
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    var liveOrSavedTranscriptView: some View {
        let saved = selectedMeeting?.transcript ?? ""
        let liveText = liveTranscription.liveText
        let showLive = isRecording || liveTranscription.isRunning

        if showLive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(liveTranscription.isProcessingChunk ? 1 : 0.45)
                    Text("Live transcript")
                        .font(.caption.weight(.semibold))
                    if liveTranscription.isProcessingChunk {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text("Updates every few seconds · final pass on Stop")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.06))

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(liveText.isEmpty
                             ? "Listening… speak or play audio. Text will appear here shortly."
                             : liveText)
                            .font(.body)
                            .foregroundStyle(liveText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(20)
                            .id("live-tail")
                    }
                    .onChange(of: liveText) { _, _ in
                        withAnimation {
                            proxy.scrollTo("live-tail", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !saved.isEmpty {
            MarkdownView(markdown: saved)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            aiEmptyState(
                icon: "waveform",
                title: "No Transcript",
                subtitle: "Record a meeting using the toolbar button. A live transcript appears while recording; the final pass runs when you stop."
            )
        }
    }
}
