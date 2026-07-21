import SwiftUI
import AppKit

// MARK: - Data Model

struct Meeting: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var timestamp: Double
    var manualNotes: String
    var transcript: String
    var summary: String
    var template: String
    var groupName: String? = nil
    var isDeleted: Bool = false
    /// Recorded audio length in seconds (0 if unknown / note-only).
    var durationSeconds: Int = 0

    /// Notes created via the Note flow use template `"Note"`.
    var isNoteType: Bool { template == "Note" }

    var kindLabel: String { isNoteType ? "Note" : "Meeting" }

    /// Default titles we may safely replace with an AI title.
    var isPlaceholderTitle: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("Untitled ") { return true }
        if t.hasPrefix("Meeting ") { return true }
        if t.hasPrefix("Note ") { return true }
        return false
    }

    var formattedCreated: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: timestamp))
    }

    var formattedDuration: String? {
        guard durationSeconds > 0 else { return nil }
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        if m >= 60 {
            return String(format: "%dh %02dm", m / 60, m % 60)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct MeetingGroup: Identifiable {
    var id: String { name }
    let name: String
    let meetings: [Meeting]
}

/// What the user is creating from the Create sheet.
enum CreateKind: String, CaseIterable, Identifiable, Hashable {
    case meeting
    case note
    case article

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .article: return "Article"
        }
    }

    var subtitle: String {
        switch self {
        case .meeting: return "Record mic + system audio, then AI summary"
        case .note: return "Write freely — no recording required"
        case .article: return "Paste one or more URLs — pages or YouTube"
        }
    }

    var icon: String {
        switch self {
        case .meeting: return "waveform.circle.fill"
        case .note: return "note.text"
        case .article: return "link.circle.fill"
        }
    }

    var accent: Color {
        switch self {
        case .meeting: return .red
        case .note: return .blue
        case .article: return .orange
        }
    }
}

/// Sheet presentation token so the create UI always opens with the correct kind.
struct CreateSheetRequest: Identifiable, Hashable {
    let id: UUID
    let kind: CreateKind

    init(kind: CreateKind) {
        self.id = UUID()
        self.kind = kind
    }
}

/// Result handed back from the create sheet (kind is explicit — never inferred from parent state).
struct CreateItemPayload {
    let kind: CreateKind
    let title: String
    let folderName: String?
    let template: String
    let model: String
    let autoStartRecording: Bool
    /// Used when kind == .article
    let articleURL: String?
}

/// Sidebar library scope (fills the lower-left with real navigation).
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case unfiled
    case meetings
    case notes
    case askEverything

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .unfiled: return "Unfiled"
        case .meetings: return "Meetings"
        case .notes: return "Notes"
        case .askEverything: return "Ask everything"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .unfiled: return "tray"
        case .meetings: return "waveform"
        case .notes: return "note.text"
        case .askEverything: return "sparkles.rectangle.stack"
        }
    }
}

/// Presets for “Summarize folder” — user can also type free-form specs.
enum FolderSummarizePreset: String, CaseIterable, Identifiable {
    case actionItems
    case executive
    case themes
    case research
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actionItems: return "Action items & decisions"
        case .executive: return "Executive brief"
        case .themes: return "Themes & insights"
        case .research: return "Research synthesis"
        case .custom: return "Custom instructions"
        }
    }

    var defaultSpecs: String {
        switch self {
        case .actionItems:
            return """
            Produce:
            1) Key decisions (if any)
            2) Concrete action items (bullet list; owner/deadline when mentioned)
            3) Open questions / risks
            4) One-paragraph overview of the folder
            """
        case .executive:
            return """
            Write a short executive brief for a busy reader:
            - Bottom line up front (3–5 sentences)
            - Why it matters
            - Main takeaways (bullets)
            - Recommended next steps
            """
        case .themes:
            return """
            Cluster content into themes across all items. For each theme: summary, supporting points with source titles, contradictions if any.
            End with overall insights.
            """
        case .research:
            return """
            Research synthesis: claims vs evidence, key facts, sources cited by item title, gaps, and suggested follow-up reading/questions.
            """
        case .custom:
            return ""
        }
    }
}

// MARK: - Root View (Handles Sheet + Keyboard)

struct RootView: View {
    var body: some View {
        MainView()
    }
}

extension Notification.Name {
    static let meetingDeleted = Notification.Name("meetingDeleted")
    static let exportMeetingRequested = Notification.Name("exportMeetingRequested")
}

// MARK: - Main View

struct MainView: View {
    @Environment(\.openSettings) private var openSettings

    // Data
    @State private var meetings: [Meeting] = []
    @State private var folders: [String] = []
    @State private var selectedMeeting: Meeting? = nil
    @State private var searchText = ""
    /// When set, open the best tab for a search hit (summary / notes / transcript).
    @State private var pendingSearchReveal = false
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showingImportUrlAlert = false
    @State private var importUrlString = ""
    @State private var isImportingUrl = false
    /// When true (and an item is selected), fetch content into the current note/meeting instead of creating new ones.
    @State private var importAppendToSelected = false
    @State private var showingImportErrorAlert = false
    @State private var importErrorMessage = ""
    /// When set, Import Failed alert offers “Open in Browser”.
    @State private var importErrorOpenURL: String? = nil
    /// After a web article import: offer to pull linked YouTube captions.
    @State private var showingYouTubeSuggestAlert = false
    @State private var suggestedYouTubeURL: String = ""
    @State private var suggestedYouTubeMeetingId: String? = nil
    /// Queue when multi-import finds several pages with YouTube links.
    @State private var pendingYouTubeSuggestions: [(meetingId: String, ytURL: String)] = []
    @State private var isImportingSuggestedYouTube = false
    @State private var showingSettingsSheet = false
    /// Folder-level multi-item summarize
    @State private var showingFolderSummarizeSheet = false
    @State private var folderSummarizeName: String = ""
    @State private var folderSummarizePreset: FolderSummarizePreset = .actionItems
    @State private var folderSummarizeCustomSpecs: String = ""
    @State private var isFolderSummarizing = false

    // AI Config
    @State private var selectedModel = "gemma2:2b"
    @State private var customModelName = ""
    @State private var selectedTemplate = "Standard Summary"
    @State private var customTemplates: [AITemplate] = []
    @AppStorage("autoEnhance") private var autoEnhance = true

    // Recording
    @State private var isRecording = false
    @State private var recordingSeconds = 0
    @State private var statusMessage = ""
    @State private var recordingTimer: Timer? = nil

    // UI
    @State private var selectedTab = "summary"
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var suggestedGroup: String? = nil
    @State private var isSuggestingGroup = false
    @State private var libraryFilter: LibraryFilter = .all
    /// When set, sidebar shows only this folder (overrides library filter).
    @State private var focusedFolder: String? = nil

    // Create sheet form — present via item so kind is never stale
    @State private var createSheetRequest: CreateSheetRequest? = nil
    @State private var createKind: CreateKind = .meeting
    @State private var newTitle = ""
    /// Empty string = Unfiled; otherwise an existing or newly named folder.
    @State private var newFolderSelection: String = ""
    @State private var isCreatingNewFolder = false
    @State private var newFolderInlineName = ""
    @State private var newTemplate = "Standard Summary"
    @State private var newModel = "gemma2:2b"
    @State private var autoStartRecording = true

    // Import sheet folder (mirrors create chips)
    @State private var importFolderSelection: String = ""
    @State private var importIsCreatingFolder = false
    @State private var importNewFolderName = ""
    /// Markdown format command for the note body editor.
    @State private var noteFormatCommand: MarkdownFormatCommand? = nil
    @State private var noteShowPreview = false

    // Auto-organize
    @State private var isOrganizing = false
    @State private var showingOrganizeReport = false
    @State private var organizeReportLines: [String] = []
    @State private var organizeReportTitle = "Auto-organize"

    // Delete folder
    @State private var folderPendingDelete: String? = nil
    @State private var showingDeleteFolderConfirm = false

    private let db = Database.shared
    private let recorder = AudioRecorder.shared
    private let transcriber = WhisperTranscriber.shared
    private let ollama = OllamaClient.shared

    let templates = ["Standard Summary", "Daily Standup", "Sales Call", "Action Items Focus"]
    @State private var presetModels: [String] = []

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 288, max: 360)
        } detail: {
            if libraryFilter == .askEverything && focusedFolder == nil {
                globalChatDetail
            } else if let _ = selectedMeeting {
                detailContent
            } else {
                emptyDetailPlaceholder
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .sheet(item: $createSheetRequest) { request in
            CreateItemSheet(
                initialKind: request.kind,
                folders: folders,
                presetModels: presetModels,
                templates: templates,
                customTemplates: customTemplates,
                initialFolder: preferredCreateFolder(),
                initialModel: newModel,
                onCancel: { createSheetRequest = nil },
                onCreate: { payload in
                    createSheetRequest = nil
                    createSession(from: payload)
                }
            )
            .id(request.id) // force fresh state per open (Meeting vs Note)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
                .frame(width: 600, height: 400)
                .overlay(alignment: .topTrailing) {
                    Button {
                        showingSettingsSheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
        }
        .onAppear { 
            loadMeetings()
            loadTemplates()
            Task {
                do {
                    let models = try await ollama.getModels()
                    await MainActor.run {
                        if models.isEmpty {
                            presetModels = ["No models found"]
                        } else {
                            presetModels = models
                            if newModel == "gemma2:2b" || !models.contains(newModel) {
                                newModel = models[0]
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        presetModels = ["Ollama not running"]
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDeleted)) { _ in
            let wasSelectedId = selectedMeeting?.id
            loadMeetings()
            if meetings.first(where: { $0.id == wasSelectedId }) == nil {
                selectedMeeting = meetings.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportMeetingRequested)) { note in
            guard let id = note.object as? String,
                  let m = meetings.first(where: { $0.id == id }) ?? db.getMeeting(id: id) else { return }
            exportMeeting(m)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMeetingRequested)) { note in
            let kind: CreateKind
            if let raw = note.object as? String, let k = CreateKind(rawValue: raw) {
                kind = k
            } else {
                kind = .meeting
            }
            openCreateSheet(kind: kind)
        }
        .onChange(of: selectedMeeting?.id) { _, id in
            suggestedGroup = nil
            if let id {
                loadDetails(id: id)
                if let m = selectedMeeting {
                    if pendingSearchReveal || isSearching {
                        pendingSearchReveal = false
                        revealSearchMatch(in: m)
                    } else if m.isNoteType {
                        // Notes open on Write; long imports default to Preview (reading mode)
                        selectedTab = "notes"
                        let longBody = m.manualNotes.count > 400 || m.transcript.count > 400
                        noteShowPreview = longBody
                    }
                    if (m.groupName?.isEmpty ?? true), !m.transcript.isEmpty {
                        generateGroupSuggestion(for: m)
                    }
                }
            }
        }
        .onChange(of: searchText) { _, query in
            handleSearchQueryChange(query)
        }

        .frame(minWidth: 960, minHeight: 640)
    }

    // MARK: - Sidebar

    @ViewBuilder
    var sidebarContent: some View {
        VStack(spacing: 0) {
            // One-click create: Meeting | Note | Article
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    sidebarCreateButton(kind: .meeting)
                    sidebarCreateButton(kind: .note)
                }
                sidebarCreateButton(kind: .article)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Single-button auto-organize for unfiled / untitled items
            Button {
                runAutoOrganize()
            } label: {
                HStack(spacing: 8) {
                    if isOrganizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles.rectangle.stack")
                    }
                    Text(isOrganizing ? "Organizing…" : "Auto-organize")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    let n = itemsNeedingOrganize.count
                    if n > 0 && !isOrganizing {
                        Text("\(n)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.purple.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.purple.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isOrganizing || itemsNeedingOrganize.isEmpty)
            .help("Name untitled items and file unfiled ones, then show a summary")
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List(selection: $selectedMeeting) {
                // LIBRARY
                Section {
                    ForEach(LibraryFilter.allCases) { filter in
                        libraryFilterRow(filter)
                    }
                } header: {
                    Text("Library")
                }

                // FOLDERS (+ in header)
                Section {
                    if folders.isEmpty {
                        Text("No folders yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(folders.sorted(), id: \.self) { name in
                            folderNavRow(name)
                                .dropDestination(for: String.self) { items, _ in
                                    moveMeetings(items, toFolder: name)
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Folders")
                        Spacer()
                        Button {
                            newFolderName = ""
                            showingNewFolderAlert = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("New folder")
                    }
                }

                // ITEMS (filtered list) — while searching, a flat “Search results” section
                if isSearching {
                    Section {
                        if filteredMeetings.isEmpty {
                            Text("No matches for “\(searchText)”")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(filteredMeetings) { meeting in
                                SidebarRow(
                                    meeting: meeting,
                                    isSelected: selectedMeeting?.id == meeting.id,
                                    searchQuery: searchText
                                )
                                .tag(meeting)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    openSearchResult(meeting)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Search results")
                            Spacer()
                            Text("\(filteredMeetings.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    ForEach(groupedMeetings) { group in
                        Section(group.name) {
                            ForEach(group.meetings) { meeting in
                                SidebarRow(meeting: meeting, isSelected: selectedMeeting?.id == meeting.id)
                                    .tag(meeting)
                                    .draggable(meeting.id)
                                    .contextMenu {
                                        Button {
                                            exportMeeting(meeting)
                                        } label: {
                                            Label("Export Markdown…", systemImage: "square.and.arrow.up")
                                        }
                                        Button(role: .destructive) {
                                            Database.shared.softDeleteMeeting(id: meeting.id)
                                            NotificationCenter.default.post(name: .meetingDeleted, object: nil)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            moveMeetings(items, toFolder: dropFolder(fromSection: group.name))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes & meetings")
            .onSubmit(of: .search) {
                if let first = filteredMeetings.first {
                    openSearchResult(first)
                }
            }
        }
        .navigationTitle("Grist")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .alert("Import Failed", isPresented: $showingImportErrorAlert) {
            if let openURL = importErrorOpenURL, let url = URL(string: openURL) {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
        .alert("YouTube episode found", isPresented: $showingYouTubeSuggestAlert) {
            Button("Import captions & summarize") {
                importSuggestedYouTubeCaptions()
            }
            Button("Not now", role: .cancel) {
                // Article-only: still run enhance if Auto is on
                if autoEnhance {
                    if let id = suggestedYouTubeMeetingId {
                        selectedMeeting = meetings.first(where: { $0.id == id }) ?? selectedMeeting
                    }
                    runEnhance()
                }
                presentNextYouTubeSuggestion()
            }
        } message: {
            let more = pendingYouTubeSuggestions.isEmpty
                ? ""
                : "\n\n(\(pendingYouTubeSuggestions.count) more linked video\(pendingYouTubeSuggestions.count == 1 ? "" : "s") after this)"
            Text(
                "This page links to a YouTube video.\n\n\(suggestedYouTubeURL)\n\nImport captions into this note and run an AI summary?\(more)"
            )
            .textSelection(.enabled)
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    db.saveFolder(name)
                    loadMeetings()
                    focusedFolder = name
                    libraryFilter = .all
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingDeleteFolderConfirm) {
            deleteFolderSheet
        }
        .sheet(isPresented: $showingImportUrlAlert) {
            importURLSheet
        }
        .sheet(isPresented: $showingOrganizeReport) {
            organizeReportSheet
        }
        .sheet(isPresented: $showingFolderSummarizeSheet) {
            folderSummarizeSheet
        }
    }

    // MARK: - Folder summarize sheet

    private var folderSummarizeSheet: some View {
        let count = meetings.filter { ($0.groupName ?? "") == folderSummarizeName }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summarize folder")
                        .font(.title2.weight(.bold))
                    Text("“\(folderSummarizeName)” · \(count) item\(count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingFolderSummarizeSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(isFolderSummarizing)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What do you need from this folder?")
                        .font(.headline)

                    Text("Collect blogs, videos, meetings, and notes into one summary. Pick a style or write your own specs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(FolderSummarizePreset.allCases) { preset in
                            Button {
                                folderSummarizePreset = preset
                                if preset != .custom {
                                    folderSummarizeCustomSpecs = preset.defaultSpecs
                                } else if folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    folderSummarizeCustomSpecs = "Describe what you want (e.g. action items for the product team, risks only, compare viewpoints…)"
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: folderSummarizePreset == preset ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(folderSummarizePreset == preset ? Color.accentColor : .secondary)
                                    Text(preset.title)
                                        .font(.callout.weight(folderSummarizePreset == preset ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(12)
                                .background(folderSummarizePreset == preset ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("INSTRUCTIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $folderSummarizeCustomSpecs)
                            .font(.body)
                            .frame(minHeight: 120, maxHeight: 180)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        Picker("", selection: $selectedModel) {
                            ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()
            HStack {
                Button("Cancel") { showingFolderSummarizeSheet = false }
                    .disabled(isFolderSummarizing)
                Spacer()
                Button {
                    runFolderSummarize()
                } label: {
                    if isFolderSummarizing {
                        Label("Summarizing…", systemImage: "ellipsis")
                    } else {
                        Label("Summarize folder", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFolderSummarizing || count == 0
                          || folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                folderSummarizeCustomSpecs = folderSummarizePreset.defaultSpecs
            }
        }
    }

    private func openFolderSummarize(name: String) {
        folderSummarizeName = name
        folderSummarizePreset = .actionItems
        folderSummarizeCustomSpecs = FolderSummarizePreset.actionItems.defaultSpecs
        showingFolderSummarizeSheet = true
    }

    private func runFolderSummarize() {
        let name = folderSummarizeName
        let items = meetings.filter { ($0.groupName ?? "") == name }
        guard !items.isEmpty else {
            statusMessage = "Folder is empty"
            return
        }
        let specs = folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !specs.isEmpty else { return }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else {
            statusMessage = "Pick a model"
            return
        }

        isFolderSummarizing = true
        statusMessage = "Summarizing folder…"

        // Build content payloads (prefer summary; fall back to notes + transcript)
        let payloads: [(title: String, kind: String, content: String)] = items.map { m in
            var parts: [String] = []
            if !m.summary.isEmpty { parts.append("AI Summary:\n\(m.summary)") }
            if !m.manualNotes.isEmpty { parts.append("Notes:\n\(m.manualNotes.prefix(20_000))") }
            if !m.transcript.isEmpty {
                let t = m.transcript
                parts.append("Transcript:\n\(t.prefix(20_000))")
            }
            let content = parts.joined(separator: "\n\n")
            return (title: m.title, kind: m.kindLabel, content: content.isEmpty ? "(empty)" : content)
        }

        Task {
            do {
                let result = try await ollama.folderSummarize(
                    folderName: name,
                    items: payloads,
                    userSpecs: specs,
                    model: model
                )
                await MainActor.run {
                    let title = result.title?.isEmpty == false
                        ? result.title!
                        : "Folder summary: \(name)"
                    let id = UUID().uuidString
                    let body = """
                    [Folder summary of “\(name)” — \(items.count) items]

                    ## Specs used
                    \(specs)

                    ---

                    \(result.summary)
                    """
                    let note = Meeting(
                        id: id,
                        title: title,
                        timestamp: Date().timeIntervalSince1970,
                        manualNotes: body,
                        transcript: payloads.map { "=== \($0.kind): \($0.title) ===\n\($0.content.prefix(8000))" }.joined(separator: "\n\n"),
                        summary: result.summary,
                        template: "Note",
                        groupName: name,
                        isDeleted: false
                    )
                    db.saveMeeting(note)
                    db.saveFolder(name)
                    loadMeetings()
                    focusedFolder = name
                    libraryFilter = .all
                    selectedMeeting = meetings.first(where: { $0.id == id })
                    selectedTab = "summary"
                    noteShowPreview = true
                    isFolderSummarizing = false
                    showingFolderSummarizeSheet = false
                    statusMessage = "Folder summary ready"
                }
            } catch {
                await MainActor.run {
                    isFolderSummarizing = false
                    statusMessage = "Folder summary failed"
                    importErrorMessage = error.localizedDescription
                    importErrorOpenURL = nil
                    showingImportErrorAlert = true
                }
            }
        }
    }

    @ViewBuilder
    private var deleteFolderSheet: some View {
        let name = folderPendingDelete ?? ""
        let count = meetings.filter { ($0.groupName ?? "") == name }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete folder")
                        .font(.title2.weight(.bold))
                    Text(name.isEmpty ? "" : "“\(name)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingDeleteFolderConfirm = false
                    folderPendingDelete = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                if count == 0 {
                    Text("This folder is empty. Deleting it only removes the folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This folder has \(count) item\(count == 1 ? "" : "s"). Choose what to do with them:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        Button {
                            confirmDeleteFolder(contents: .moveToUnfiled)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Move to Unfiled")
                                        .font(.headline)
                                    Text("Keep all notes/meetings; only remove the folder.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            confirmDeleteFolder(contents: .softDeleteContents)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "trash.fill")
                                    .font(.title3)
                                    .foregroundStyle(.red)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Delete all contents")
                                        .font(.headline)
                                        .foregroundStyle(.red)
                                    Text("Soft-delete every item in the folder (hidden, not erased from disk). Then remove the folder.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)

            Spacer(minLength: 8)
            Divider()
            HStack {
                if count == 0 {
                    Button("Delete folder", role: .destructive) {
                        confirmDeleteFolder(contents: .moveToUnfiled)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Spacer()
                Button("Cancel") {
                    showingDeleteFolderConfirm = false
                    folderPendingDelete = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 440, height: count == 0 ? 220 : 360)
    }

    private var organizeReportSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(organizeReportTitle)
                        .font(.title2.weight(.bold))
                    Text("Untitled items got names; unfiled items got folders when the AI found a fit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingOrganizeReport = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider()

            if organizeReportLines.isEmpty {
                Text("Nothing needed organizing.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(organizeReportLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(line)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(24)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { showingOrganizeReport = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 420)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Button {
                openImportSheet(appendToCurrent: false)
            } label: {
                Label(isImportingUrl ? "Importing…" : "Import URL", systemImage: "link")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isImportingUrl)
            .help("Import as new note(s). Open an item and use Add URL to append.")

            if isImportingUrl {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                showingSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func libraryFilterRow(_ filter: LibraryFilter) -> some View {
        let selected = focusedFolder == nil && libraryFilter == filter
        let count = count(for: filter)
        return Button {
            focusedFolder = nil
            libraryFilter = filter
            if filter == .askEverything {
                selectedMeeting = nil
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? (filter == .askEverything ? .purple : Color.accentColor) : .secondary)
                Text(filter.label)
                    .font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
                if filter != .askEverything {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? (filter == .askEverything ? Color.purple.opacity(0.12) : Color.accentColor.opacity(0.12)) : Color.clear)
    }

    @ViewBuilder
    private var globalChatDetail: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask everything")
                        .font(.headline)
                    Text("Answers use all notes and meetings in your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $selectedModel) {
                    ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ChatView(
                scope: .global,
                selectedModel: selectedModel,
                customModelName: customModelName
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderNavRow(_ name: String) -> some View {
        let selected = focusedFolder == name
        let count = meetings.filter { ($0.groupName ?? "") == name }.count
        return Button {
            focusedFolder = name
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            Button("Show only this folder") { focusedFolder = name }
            Button("New meeting here") {
                focusedFolder = name
                openCreateSheet(kind: .meeting)
            }
            Button("New note here") {
                focusedFolder = name
                openCreateSheet(kind: .note)
            }
            Button {
                openFolderSummarize(name: name)
            } label: {
                Label("Summarize folder…", systemImage: "sparkles")
            }
            Button {
                exportFolder(name)
            } label: {
                Label("Export folder as Markdown…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete Folder…", role: .destructive) {
                folderPendingDelete = name
                showingDeleteFolderConfirm = true
            }
        }
    }

    private func confirmDeleteFolder(contents: Database.FolderDeleteContentsMode) {
        guard let name = folderPendingDelete else { return }
        let count = meetings.filter { ($0.groupName ?? "") == name }.count
        let selectedWasInFolder = selectedMeeting?.groupName == name

        db.deleteFolder(name, contents: contents)

        if focusedFolder == name {
            focusedFolder = nil
            libraryFilter = contents == .softDeleteContents ? .all : .unfiled
        }
        loadMeetings()

        // If the open item was soft-deleted, clear selection
        if selectedWasInFolder, contents == .softDeleteContents {
            selectedMeeting = meetings.first
        } else if let id = selectedMeeting?.id {
            selectedMeeting = meetings.first(where: { $0.id == id }) ?? meetings.first
        }

        folderPendingDelete = nil
        showingDeleteFolderConfirm = false

        switch contents {
        case .moveToUnfiled:
            statusMessage = count > 0
                ? "Deleted “\(name)” — \(count) item\(count == 1 ? "" : "s") → Unfiled"
                : "Deleted folder “\(name)”"
        case .softDeleteContents:
            statusMessage = count > 0
                ? "Deleted “\(name)” and soft-deleted \(count) item\(count == 1 ? "" : "s")"
                : "Deleted folder “\(name)”"
        }
    }

    private var importURLSheet: some View {
        let canAppend = selectedMeeting != nil
        let appendTargetTitle = selectedMeeting?.title ?? "current item"
        let n = Self.parseImportURLs(from: importUrlString).count

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(importAppendToSelected && canAppend ? "Add to item" : "Import URL")
                        .font(.title2.weight(.bold))
                    Text(importAppendToSelected && canAppend
                         ? "Fetch page/YouTube content and append it to the open note or meeting, then you can re-Enhance."
                         : "Paste one or many URLs. Each link becomes its own note (or append to the open item).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingImportUrlAlert = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            VStack(alignment: .leading, spacing: 18) {
                if canAppend {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DESTINATION")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $importAppendToSelected) {
                            Text("New note(s)").tag(false)
                            Text("Add to current").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if importAppendToSelected {
                            HStack(spacing: 8) {
                                Image(systemName: selectedMeeting?.isNoteType == true ? "note.text" : "waveform")
                                    .foregroundStyle(.blue)
                                Text(appendTargetTitle)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("URL(S)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if n > 1 {
                            Text("\(n) links")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    TextEditor(text: $importUrlString)
                        .font(.body)
                        .frame(minHeight: 88, maxHeight: 140)
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if importUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("One per line (or space-separated)\nhttps://…\nhttps://youtube.com/…")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                    let parsed = Self.parseImportURLs(from: importUrlString)
                    let ytCount = parsed.filter { YouTubeImporter.isYouTubeURL($0) }.count
                    if ytCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: YouTubeImporter.resolveYtDlpPath() == nil ? "exclamationmark.triangle.fill" : "play.rectangle.fill")
                                .foregroundStyle(YouTubeImporter.resolveYtDlpPath() == nil ? .orange : .red)
                            Text(YouTubeImporter.resolveYtDlpPath() == nil
                                 ? "\(ytCount) YouTube — install yt-dlp: brew install yt-dlp"
                                 : "\(ytCount) YouTube — will pull captions via yt-dlp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if parsed.count > 1 {
                        Text(importAppendToSelected && canAppend
                             ? "All \(parsed.count) pages will be appended to this item"
                             : "Will import \(parsed.count) pages as separate notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !(importAppendToSelected && canAppend) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FOLDER")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                folderChip(title: "Unfiled", icon: "tray", selected: importFolderSelection.isEmpty && !importIsCreatingFolder) {
                                    importIsCreatingFolder = false
                                    importFolderSelection = ""
                                    importNewFolderName = ""
                                }
                                ForEach(folders.sorted(), id: \.self) { name in
                                    folderChip(title: name, icon: "folder.fill", selected: importFolderSelection == name && !importIsCreatingFolder) {
                                        importIsCreatingFolder = false
                                        importFolderSelection = name
                                        importNewFolderName = ""
                                    }
                                }
                                folderChip(title: "New folder", icon: "folder.badge.plus", selected: importIsCreatingFolder) {
                                    importIsCreatingFolder = true
                                    importFolderSelection = ""
                                }
                            }
                        }
                        if importIsCreatingFolder {
                            TextField("Folder name", text: $importNewFolderName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onChange(of: importNewFolderName) { _, val in
                                    importFolderSelection = val.trimmingCharacters(in: .whitespaces)
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            Divider()
            HStack {
                Button("Cancel") { showingImportUrlAlert = false }
                Spacer()
                Button {
                    showingImportUrlAlert = false
                    importFromUrl()
                } label: {
                    if importAppendToSelected && canAppend {
                        Label(n > 1 ? "Add \(n) to item" : "Add to item", systemImage: "plus.rectangle.on.rectangle")
                    } else {
                        Label(n > 1 ? "Import \(n) URLs" : "Import", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(Self.parseImportURLs(from: importUrlString).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 500, height: canAppend ? 480 : 420)
    }

    private func openImportSheet(appendToCurrent: Bool = false) {
        importUrlString = ""
        importIsCreatingFolder = false
        importNewFolderName = ""
        // Always start Unfiled for new notes — don't inherit sidebar focus.
        importFolderSelection = ""
        importAppendToSelected = appendToCurrent && selectedMeeting != nil
        showingImportUrlAlert = true
    }

    private func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: return meetings.count
        case .unfiled: return meetings.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        case .meetings: return meetings.filter { !$0.isNoteType }.count
        case .notes: return meetings.filter { $0.isNoteType }.count
        case .askEverything: return meetings.count
        }
    }

    private func dropFolder(fromSection name: String) -> String? {
        if name == "Today" || name == "Yesterday" || name == "Last 7 Days" || name == "Older" || name == "Items" {
            return nil
        }
        if name.hasPrefix("📁 ") { return String(name.dropFirst(2)) }
        return name
    }

    @discardableResult
    private func moveMeetings(_ ids: [String], toFolder folder: String?) -> Bool {
        guard let meetingId = ids.first, var m = db.getMeeting(id: meetingId) else { return false }
        m.groupName = folder
        db.saveMeeting(m)
        if let folder { db.saveFolder(folder) }
        loadMeetings()
        return true
    }

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
                    MarkdownView(markdown: summary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noteEmptyAIState
                }
            } else if selectedTab == "chat", let m = selectedMeeting {
                ChatView(scope: .item(m), selectedModel: selectedModel, customModelName: customModelName)
                    .id(m.id)
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
    }

    @ViewBuilder
    var noteWritingSurface: some View {
        VStack(spacing: 0) {
            // Slim format bar
            HStack(spacing: 10) {
                MarkdownFormatToolbar(pendingFormat: $noteFormatCommand)
                Spacer(minLength: 8)
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

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func isYouTubeLink(_ link: String) -> Bool {
        link.localizedCaseInsensitiveContains("youtube.com") || link.localizedCaseInsensitiveContains("youtu.be")
    }

    /// Pull first markdown link or raw URL from note (legacy helpers).
    private func extractSourceURL(from notes: String) -> String? {
        extractSourceURLs(from: notes).first
    }

    /// Source / YouTube links meant for the copiable header cards (not every URL in the body).
    private func extractSourceURLs(from notes: String) -> [String] {
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
    private func stripSourceHeader(from notes: String) -> String {
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
                generateAutoTitle(force: true)
            } label: {
                Label("Title", systemImage: "textformat")
            }
            .help("Generate title from note body")
            .disabled(noteBodyEmpty)

            Button {
                runEnhance()
            } label: {
                Label(statusMessage == "Enhancing…" ? "Working…" : "Enhance", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(statusMessage == "Enhancing…" || noteBodyEmpty)
            .help("AI summary + title from what you wrote")
        }
    }

    private var noteBodyEmpty: Bool {
        let t = selectedMeeting?.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tr = selectedMeeting?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let s = selectedMeeting?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasTranscript = !tr.isEmpty && !tr.hasPrefix("[Error")
        return t.isEmpty && s.isEmpty && !hasTranscript
    }

    @ViewBuilder
    var noteEmptyAIState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.blue.opacity(0.7))
            Text("No AI summary yet")
                .font(.title3.weight(.semibold))
            Text("Write in the Write tab, then tap Enhance to get a structured summary and auto-title.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                selectedTab = "notes"
            } label: {
                Label("Back to writing", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
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

    private func metaChip(icon: String, text: String) -> some View {
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
                runEnhance()
            } label: {
                Label(statusMessage == "Enhancing…" ? "Enhancing…" : "Enhance",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(statusMessage == "Enhancing…" || !meetingHasEnhanceableContent)
            .controlSize(.regular)
        }
    }

    /// Meeting can enhance from transcript and/or written notes.
    private var meetingHasEnhanceableContent: Bool {
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
                MarkdownView(markdown: summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ChatView(scope: .item(m), selectedModel: selectedModel, customModelName: customModelName)
                    .id(m.id)
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
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("Nothing selected")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Capture a meeting, jot a note, or pick something from the sidebar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: 14) {
                emptyCreateCard(kind: .meeting)
                emptyCreateCard(kind: .note)
                emptyCreateCard(kind: .article)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    private func emptyCreateCard(kind: CreateKind) -> some View {
        Button {
            openCreateSheet(kind: kind)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(kind.accent)
                Text(kind.title)
                    .font(.headline)
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 140)
            }
            .padding(20)
            .frame(width: 180, height: 150)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sidebarCreateButton(kind: CreateKind) -> some View {
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
                        exportMeeting(m)
                    } label: {
                        Label("Export Markdown…", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button {
                        copyFullExportToClipboard(m)
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                    }
                    if !m.summary.isEmpty {
                        Button {
                            copySummaryToClipboard()
                        } label: {
                            Label("Copy Summary Only", systemImage: "doc.on.doc")
                        }
                    }
                    if let folder = m.groupName, !folder.isEmpty {
                        Divider()
                        Button {
                            openFolderSummarize(name: folder)
                        } label: {
                            Label("Summarize Folder “\(folder)”…", systemImage: "sparkles")
                        }
                        Button {
                            exportFolder(folder)
                        } label: {
                            Label("Export Folder “\(folder)”…", systemImage: "folder")
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export this note/meeting as Markdown")
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
    private func preferredCreateFolder() -> String {
        ""
    }

    /// Open create sheet; kind is owned entirely by the sheet view.
    func openCreateSheet(kind: CreateKind) {
        createSheetRequest = CreateSheetRequest(kind: kind)
    }

    private func folderChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
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

    // MARK: - Computed Data

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredMeetings: [Meeting] {
        var list = meetings

        // While searching, look across the whole library (ignore folder / filter scope)
        // so results always “jump” to the real item.
        if isSearching {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return list.filter { Self.meeting($0, matchesSearch: q) }
                .sorted { a, b in
                    // Prefer title hits, then recency
                    let at = a.title.localizedCaseInsensitiveContains(q)
                    let bt = b.title.localizedCaseInsensitiveContains(q)
                    if at != bt { return at && !bt }
                    return a.timestamp > b.timestamp
                }
        }

        // Folder focus wins over library filter
        if let folder = focusedFolder {
            list = list.filter { ($0.groupName ?? "") == folder }
        } else {
            switch libraryFilter {
            case .all, .askEverything:
                break
            case .unfiled:
                list = list.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            case .meetings:
                list = list.filter { !$0.isNoteType }
            case .notes:
                list = list.filter { $0.isNoteType }
            }
        }
        return list
    }

    static func meeting(_ m: Meeting, matchesSearch q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return m.title.localizedCaseInsensitiveContains(q)
            || m.transcript.localizedCaseInsensitiveContains(q)
            || m.manualNotes.localizedCaseInsensitiveContains(q)
            || m.summary.localizedCaseInsensitiveContains(q)
            || (m.groupName?.localizedCaseInsensitiveContains(q) ?? false)
    }

    /// Open a search hit in the detail pane and jump to the matching tab.
    func openSearchResult(_ meeting: Meeting) {
        pendingSearchReveal = true
        // Clear folder focus so the row stays visible under “Search results”
        focusedFolder = nil
        libraryFilter = .all
        selectedMeeting = meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private func handleSearchQueryChange(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let hits = filteredMeetings
        guard !hits.isEmpty else { return }
        // If nothing selected or selection not in results, jump to the best hit
        if selectedMeeting == nil || !hits.contains(where: { $0.id == selectedMeeting?.id }) {
            openSearchResult(hits[0])
        }
    }

    /// Pick the tab where the search query appears (summary > notes > transcript).
    private func revealSearchMatch(in m: Meeting) {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if m.isNoteType {
            if m.summary.localizedCaseInsensitiveContains(q) {
                selectedTab = "summary"
            } else {
                selectedTab = "notes"
                // Preview when the hit is in a long body
                noteShowPreview = m.manualNotes.count > 400 || m.transcript.localizedCaseInsensitiveContains(q)
            }
            return
        }
        // Meeting
        if m.summary.localizedCaseInsensitiveContains(q) {
            selectedTab = "summary"
        } else if m.manualNotes.localizedCaseInsensitiveContains(q) {
            selectedTab = "notes"
        } else if m.transcript.localizedCaseInsensitiveContains(q) {
            selectedTab = "transcript"
        } else {
            selectedTab = m.summary.isEmpty ? "transcript" : "summary"
        }
    }

    // MARK: - Export

    func exportMeeting(_ m: Meeting) {
        let md = NoteExporter.markdown(for: m)
        if let url = NoteExporter.saveMarkdownPanel(defaultName: NoteExporter.safeFilename(for: m), contents: md) {
            statusMessage = "Exported \(url.lastPathComponent)"
        }
    }

    func exportFolder(_ name: String) {
        let items = meetings.filter { ($0.groupName ?? "") == name }
        guard !items.isEmpty else {
            statusMessage = "Folder is empty"
            return
        }
        if let dir = NoteExporter.saveFolderPanel(meetings: items, suggestedName: name) {
            statusMessage = "Exported \(items.count) files → \(dir.lastPathComponent)"
            NSWorkspace.shared.open(dir)
        }
    }

    func copyFullExportToClipboard(_ m: Meeting) {
        copyToPasteboard(NoteExporter.markdown(for: m))
        statusMessage = "Copied Markdown"
    }

    var groupedMeetings: [MeetingGroup] {
        // Single folder focus → one flat section by time still helps
        if focusedFolder != nil {
            return timeGrouped(filteredMeetings, headerPrefix: nil)
        }

        switch libraryFilter {
        case .unfiled, .meetings, .notes, .askEverything:
            // Don't re-split into every folder; show timeline (and folder name on each row)
            // askEverything uses the detail pane for chat; list can still show All-style items
            if libraryFilter == .askEverything {
                return timeGrouped(filteredMeetings, headerPrefix: nil)
            }
            return timeGrouped(filteredMeetings, headerPrefix: nil)
        case .all:
            var customGroups: [String: [Meeting]] = [:]
            var timeBased: [Meeting] = []

            for m in filteredMeetings {
                if let g = m.groupName, !g.trimmingCharacters(in: .whitespaces).isEmpty {
                    customGroups[g, default: []].append(m)
                } else {
                    timeBased.append(m)
                }
            }

            var result: [MeetingGroup] = []
            // Only show folder sections that have items (nav already lists all folders)
            for name in customGroups.keys.sorted() {
                let list = customGroups[name] ?? []
                result.append(MeetingGroup(name: name, meetings: list.sorted { $0.timestamp > $1.timestamp }))
            }
            result.append(contentsOf: timeGrouped(timeBased, headerPrefix: nil))
            return result
        }
    }

    private func timeGrouped(_ items: [Meeting], headerPrefix: String?) -> [MeetingGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [Meeting] = [], yesterday: [Meeting] = [], week: [Meeting] = [], older: [Meeting] = []

        for m in items {
            let d = Date(timeIntervalSince1970: m.timestamp)
            if cal.isDateInToday(d) { today.append(m) }
            else if cal.isDateInYesterday(d) { yesterday.append(m) }
            else if let diff = cal.dateComponents([.day], from: d, to: now).day, diff <= 7 { week.append(m) }
            else { older.append(m) }
        }

        func grp(_ name: String, _ list: [Meeting]) -> MeetingGroup? {
            guard !list.isEmpty else { return nil }
            let title = headerPrefix.map { "\($0) · \(name)" } ?? name
            return MeetingGroup(name: title, meetings: list.sorted { $0.timestamp > $1.timestamp })
        }

        return [grp("Today", today), grp("Yesterday", yesterday), grp("Last 7 Days", week), grp("Older", older)]
            .compactMap { $0 }
    }

    // MARK: - Data Methods
    

    
    func generateGroupSuggestion(for meeting: Meeting) {
        let f = folders.joined(separator: ", ")
        guard !f.isEmpty else { return }
        
        isSuggestingGroup = true
        
        Task {
            let prompt = "Based on this meeting transcript, which of these folders does it belong in? Folders: [\(f)]. If none fit perfectly, suggest a new short folder name (1-3 words) based on the project/topic. Respond ONLY with the folder name.\n\nTranscript: \(String(meeting.transcript.prefix(1500)))"
            
            do {
                let msg = OllamaClient.OllamaChatMessage(role: "user", content: prompt)
                let resp = try await OllamaClient.shared.chat(messages: [msg], model: "gemma2:2b")
                
                let cleaned = resp.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                if !cleaned.isEmpty {
                    await MainActor.run {
                        self.suggestedGroup = cleaned
                        self.isSuggestingGroup = false
                    }
                }
            } catch {
                await MainActor.run { self.isSuggestingGroup = false }
            }
        }
    }
    
    func logImport(_ msg: String) {
        let path = "/tmp/grist_import.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write((msg + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? (msg + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    
    /// Pull http(s) URLs from a paste — newlines, spaces, commas, or embedded in text.
    static func parseImportURLs(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var found: [String] = []
        var seen = Set<String>()

        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"'`\[\]{}|\\^]+"#, options: .caseInsensitive) {
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                var s = ns.substring(with: m.range)
                // Strip trailing punctuation common in pasted lists
                while let last = s.last, ".,;:)]}>\"'".contains(last) {
                    s.removeLast()
                }
                s = s.replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: s), url.scheme != nil, url.host != nil else { continue }
                if seen.insert(s).inserted {
                    found.append(s)
                }
            }
        }

        // Single bare URL without scheme (rare)
        if found.isEmpty {
            let one = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            for line in one {
                var s = line
                if !s.contains("://") { s = "https://\(s)" }
                if let url = URL(string: s), url.host != nil, seen.insert(s).inserted {
                    found.append(s)
                }
            }
        }
        return found
    }

    func importFromUrl() {
        logImport("importFromUrl called with string: '\(importUrlString)' append=\(importAppendToSelected)")
        let urls = Self.parseImportURLs(from: importUrlString)
        guard !urls.isEmpty else {
            logImport("No URLs parsed, aborting.")
            statusMessage = "Enter at least one URL"
            return
        }

        let appendMode = importAppendToSelected && selectedMeeting != nil
        let appendTargetId = appendMode ? selectedMeeting?.id : nil

        if appendMode, appendTargetId == nil {
            statusMessage = "Select a note or meeting first"
            return
        }

        isImportingUrl = true
        statusMessage = urls.count == 1
            ? (YouTubeImporter.isYouTubeURL(urls[0]) ? "Fetching YouTube captions…" : "Fetching page…")
            : (appendMode ? "Adding 1/\(urls.count)…" : "Importing 1/\(urls.count)…")

        // Snapshot folder choice for new-note batch only
        let folderSnapshot: String? = {
            guard !appendMode else { return nil }
            if importIsCreatingFolder {
                let name = importNewFolderName.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            let name = importFolderSelection.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }()

        Task {
            var failures: [(url: String, message: String)] = []
            var ytSuggestions: [(meetingId: String, ytURL: String)] = []
            var lastSuccessId: String?
            var successCount = 0
            var anyHasYTOffer = false

            if let folderSnapshot {
                await MainActor.run { db.saveFolder(folderSnapshot) }
            }

            for (idx, url) in urls.enumerated() {
                await MainActor.run {
                    statusMessage = urls.count == 1
                        ? (YouTubeImporter.isYouTubeURL(url) ? "Fetching YouTube captions…" : "Fetching page…")
                        : (appendMode ? "Adding \(idx + 1)/\(urls.count)…" : "Importing \(idx + 1)/\(urls.count)…")
                }
                logImport("Starting fetch \(idx + 1)/\(urls.count): \(url)")

                do {
                    let result = try await URLFetcher.shared.fetchContent(from: url)
                    logImport("Fetched (\(result.sourceKind)): \(result.title) (length: \(result.content.count))")

                    let body = result.content
                    let blockNotes: String = {
                        if result.sourceKind == "youtube" {
                            return """
                            ## Added from YouTube
                            [Open on YouTube](\(url))

                            \(body)
                            """
                        }
                        return """
                        ## Added from web
                        [Source](\(url))

                        \(body)
                        """
                    }()
                    let blockTranscript: String = {
                        if result.sourceKind == "youtube" {
                            return "=== YouTube: \(result.title) ===\n\(body)"
                        }
                        return "=== Article: \(result.title) ===\n\(body)"
                    }()

                    let ytLinks = result.relatedYouTubeURLs.filter { YouTubeImporter.isYouTubeURL($0) }
                    let hasYTOffer = result.sourceKind == "web" && ytLinks.first != nil

                    if appendMode, let targetId = appendTargetId {
                        await MainActor.run {
                            guard var m = db.getMeeting(id: targetId) ?? meetings.first(where: { $0.id == targetId }) else {
                                failures.append((url: url, message: "Item no longer exists"))
                                return
                            }
                            // Append to notes + transcript (Enhance uses both)
                            if m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                m.manualNotes = blockNotes
                            } else {
                                m.manualNotes = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                                    + "\n\n---\n\n" + blockNotes
                            }
                            if m.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                m.transcript = blockTranscript
                            } else {
                                m.transcript = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                    + "\n\n" + blockTranscript
                            }
                            db.saveMeeting(m)
                            if selectedMeeting?.id == targetId {
                                selectedMeeting = m
                            }
                            successCount += 1
                            lastSuccessId = targetId
                            if let firstYT = ytLinks.first, hasYTOffer {
                                ytSuggestions.append((meetingId: targetId, ytURL: firstYT))
                                anyHasYTOffer = true
                            }
                        }
                    } else {
                        let newNotes: String = {
                            if result.sourceKind == "youtube" {
                                return """
                                [Open on YouTube](\(url))

                                \(body)
                                """
                            }
                            return """
                            [Source](\(url))

                            \(body)
                            """
                        }()

                        let newMeeting = Meeting(
                            id: UUID().uuidString,
                            title: result.title,
                            timestamp: Date().timeIntervalSince1970 + Double(idx) * 0.001,
                            manualNotes: newNotes,
                            transcript: body,
                            summary: "",
                            template: "Note",
                            groupName: folderSnapshot,
                            isDeleted: false
                        )

                        await MainActor.run {
                            db.saveMeeting(newMeeting)
                            successCount += 1
                            lastSuccessId = newMeeting.id
                            if let firstYT = ytLinks.first, hasYTOffer {
                                ytSuggestions.append((meetingId: newMeeting.id, ytURL: firstYT))
                            }
                        }

                        // Enhance each *new* note that isn't waiting on a YouTube offer
                        if !hasYTOffer, autoEnhance {
                            await enhanceMeetingById(newMeeting.id)
                        } else if !hasYTOffer, newMeeting.isPlaceholderTitle {
                            await MainActor.run {
                                selectedMeeting = db.getMeeting(id: newMeeting.id) ?? newMeeting
                                generateAutoTitle(force: false)
                            }
                        }
                    }
                } catch {
                    logImport("Import failed for \(url): \(error)")
                    let message: String = {
                        if let e = error as? URLFetchError { return e.localizedDescription }
                        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
                        return error.localizedDescription
                    }()
                    failures.append((url: url, message: message))
                }
            }

            // Append mode: one enhance after all URLs (unless YT offers pending)
            if appendMode, let targetId = appendTargetId, successCount > 0, !anyHasYTOffer, autoEnhance {
                await enhanceMeetingById(targetId)
            }

            await MainActor.run {
                loadMeetings()
                if let folderSnapshot, !appendMode { focusedFolder = folderSnapshot }
                if let lastSuccessId {
                    selectedMeeting = meetings.first(where: { $0.id == lastSuccessId })
                    if appendMode {
                        // Meetings: show Notes tab; Notes: Write tab
                        selectedTab = "notes"
                    } else {
                        selectedTab = "notes"
                        noteShowPreview = true
                    }
                }

                if successCount > 0 {
                    if appendMode {
                        statusMessage = urls.count == 1
                            ? "Added to item"
                            : "Added \(successCount)/\(urls.count) to item"
                    } else {
                        statusMessage = urls.count == 1
                            ? (successCount == 1 ? "Imported" : "Done")
                            : "Imported \(successCount)/\(urls.count)"
                    }
                }

                pendingYouTubeSuggestions = []
                // Dedupe YT suggestions by meeting+url when appending multiple pages that share the same video
                var seenYT = Set<String>()
                var uniqueYT: [(meetingId: String, ytURL: String)] = []
                for s in ytSuggestions {
                    let key = "\(s.meetingId)|\(s.ytURL)"
                    if seenYT.insert(key).inserted { uniqueYT.append(s) }
                }
                if let first = uniqueYT.first {
                    pendingYouTubeSuggestions = Array(uniqueYT.dropFirst())
                    suggestedYouTubeURL = first.ytURL
                    suggestedYouTubeMeetingId = first.meetingId
                    selectedMeeting = meetings.first(where: { $0.id == first.meetingId }) ?? selectedMeeting
                    showingYouTubeSuggestAlert = true
                }

                if !failures.isEmpty {
                    let lines = failures.map { "• \($0.url)\n  \($0.message)" }.joined(separator: "\n\n")
                    let verb = appendMode ? "Added" : "Imported"
                    importErrorMessage = successCount > 0
                        ? "\(verb) \(successCount) of \(urls.count).\n\nFailed:\n\n\(lines)"
                        : lines
                    importErrorOpenURL = failures.count == 1 ? failures[0].url : nil
                    showingImportErrorAlert = true
                    if successCount == 0 {
                        statusMessage = "Import failed"
                    }
                }

                isImportingUrl = false
                logImport("Batch import complete. append=\(appendMode) success=\(successCount) fail=\(failures.count)")
            }
        }
    }

    /// Show the next queued “YouTube on this page?” offer, if any.
    func presentNextYouTubeSuggestion() {
        guard let next = pendingYouTubeSuggestions.first else {
            suggestedYouTubeMeetingId = nil
            suggestedYouTubeURL = ""
            return
        }
        pendingYouTubeSuggestions.removeFirst()
        suggestedYouTubeURL = next.ytURL
        suggestedYouTubeMeetingId = next.meetingId
        selectedMeeting = meetings.first(where: { $0.id == next.meetingId }) ?? selectedMeeting
        // slight delay so previous alert can dismiss cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showingYouTubeSuggestAlert = true
        }
    }

    /// Run enhance for a specific note (used by multi-URL import).
    func enhanceMeetingById(_ id: String) async {
        guard var m = await MainActor.run(body: { db.getMeeting(id: id) ?? meetings.first(where: { $0.id == id }) }) else {
            return
        }

        let transcriptSource: String = {
            if !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error") { return m.transcript }
            return m.manualNotes
        }()
        let notesSource: String = {
            if m.transcript.isEmpty || m.transcript.hasPrefix("[Error") { return "" }
            return m.manualNotes
        }()
        guard !transcriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let model = await MainActor.run { selectedModel == "custom" ? customModelName : selectedModel }
        guard !model.isEmpty else { return }

        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = await MainActor.run {
            customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        }
        let applyTitle = m.isPlaceholderTitle

        await MainActor.run {
            if selectedMeeting?.id == id {
                statusMessage = "Enhancing…"
            }
        }

        do {
            let result = try await ollama.enhance(
                transcript: transcriptSource,
                notes: notesSource,
                template: templateName,
                customPrompt: customPrompt,
                model: model
            )
            await MainActor.run {
                m.summary = result.summary
                if applyTitle, let title = result.title, !title.isEmpty, m.isPlaceholderTitle {
                    m.title = title
                }
                db.saveMeeting(m)
                if let idx = meetings.firstIndex(where: { $0.id == id }) {
                    meetings[idx] = m
                }
                if selectedMeeting?.id == id {
                    selectedMeeting = m
                    statusMessage = "Done"
                }
            }
        } catch {
            await MainActor.run {
                if selectedMeeting?.id == id {
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pull captions from a YouTube link discovered on an article page, merge into the note, then summarize.
    func importSuggestedYouTubeCaptions() {
        let ytURL = suggestedYouTubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingId = suggestedYouTubeMeetingId ?? selectedMeeting?.id
        guard !ytURL.isEmpty, let meetingId else {
            statusMessage = "No YouTube link to import"
            return
        }
        guard YouTubeImporter.resolveYtDlpPath() != nil else {
            importErrorMessage = YouTubeImporter.ImportError.ytDlpMissing.localizedDescription
            importErrorOpenURL = nil
            showingImportErrorAlert = true
            statusMessage = "yt-dlp missing"
            return
        }

        isImportingSuggestedYouTube = true
        isImportingUrl = true
        statusMessage = "Fetching YouTube captions…"

        Task {
            do {
                let yt = try await YouTubeImporter.importVideo(urlString: ytURL)
                await MainActor.run {
                    // Prefer live selection; fall back to id
                    if selectedMeeting?.id != meetingId {
                        selectedMeeting = meetings.first(where: { $0.id == meetingId }) ?? db.getMeeting(id: meetingId)
                    }
                    guard var m = selectedMeeting, m.id == meetingId else {
                        statusMessage = "Note not found for YouTube import"
                        isImportingSuggestedYouTube = false
                        isImportingUrl = false
                        return
                    }

                    let captions = yt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let articleBody = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Transcript drives Enhance/RAG: article blurb + full captions
                    m.transcript = """
                    === Article page ===
                    \(articleBody)

                    === YouTube captions (\(yt.title)) ===
                    \(captions)
                    """

                    let sourceHeader: String = {
                        if m.manualNotes.contains("[Source]") || m.manualNotes.contains("[Open on YouTube]") {
                            return m.manualNotes
                        }
                        return m.manualNotes
                    }()

                    m.manualNotes = """
                    \(sourceHeader)

                    ---

                    ## Full episode (YouTube captions)
                    [Open on YouTube](\(yt.sourceURL))

                    \(captions)
                    """

                    // Prefer the video title if note still looks generic/scraped
                    if m.isPlaceholderTitle || m.title.count > 80 {
                        m.title = yt.title
                    }

                    selectedMeeting = m
                    db.saveMeeting(m)
                    loadMeetings()
                    selectedMeeting = meetings.first(where: { $0.id == meetingId })
                    selectedTab = "notes"
                    noteShowPreview = true
                    statusMessage = "YouTube captions added (\(captions.count) chars)"
                    isImportingSuggestedYouTube = false
                    isImportingUrl = false
                    suggestedYouTubeMeetingId = nil

                    runEnhance()
                    presentNextYouTubeSuggestion()
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    importErrorOpenURL = ytURL
                    showingImportErrorAlert = true
                    statusMessage = "YouTube import failed"
                    isImportingSuggestedYouTube = false
                    isImportingUrl = false
                    // Still offer article enhance
                    if autoEnhance {
                        runEnhance()
                    }
                    presentNextYouTubeSuggestion()
                }
            }
        }
    }

    func loadMeetings() {
        meetings = db.fetchActiveMeetings()
        folders = db.fetchFolders()
        if selectedMeeting == nil { selectedMeeting = meetings.first }
    }
    
    func loadTemplates() {
        customTemplates = db.fetchTemplates()
    }

    func loadDetails(id: String) {
        if let m = db.getMeeting(id: id) {
            selectedMeeting = m
            selectedTemplate = m.template
        }
    }

    func saveMeeting() {
        guard let m = selectedMeeting else { return }
        db.saveMeeting(m)
        if let idx = meetings.firstIndex(where: { $0.id == m.id }) {
            meetings[idx] = m
        }
    }

    func createSession(from payload: CreateItemPayload) {
        // Article → same pipeline as Import URL (supports multi-URL paste)
        if payload.kind == .article {
            let raw = (payload.articleURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.parseImportURLs(from: raw).isEmpty else {
                statusMessage = "Enter at least one URL"
                return
            }
            importUrlString = raw
            importIsCreatingFolder = false
            importNewFolderName = ""
            importFolderSelection = payload.folderName ?? ""
            newModel = payload.model
            selectedModel = payload.model
            importFromUrl()
            return
        }

        let id = String(Int(Date().timeIntervalSince1970))
        let title = payload.title.trimmingCharacters(in: .whitespaces).isEmpty
            ? (payload.kind == .note ? "Untitled Note" : "Untitled Meeting")
            : payload.title.trimmingCharacters(in: .whitespaces)

        var folder = payload.folderName
        if let folder, !folder.isEmpty {
            db.saveFolder(folder)
        } else {
            folder = nil
        }

        // Notes are always template "Note" so the library filter / icons work.
        let template = payload.kind == .note ? "Note" : payload.template
        let m = Meeting(
            id: id,
            title: title,
            timestamp: Date().timeIntervalSince1970,
            manualNotes: "",
            transcript: "",
            summary: "",
            template: template,
            groupName: folder,
            isDeleted: false
        )

        selectedModel = payload.model
        selectedTemplate = template
        newModel = payload.model
        db.saveMeeting(m)
        loadMeetings()
        if let folder { focusedFolder = folder }
        selectedMeeting = meetings.first(where: { $0.id == id }) ?? m
        selectedTab = payload.kind == .note ? "notes" : "summary"

        print("[Create] kind=\(payload.kind.rawValue) template=\(template) title=\(title) folder=\(folder ?? "nil")")

        if payload.kind == .meeting && payload.autoStartRecording {
            startRecording(meetingId: id)
        } else {
            statusMessage = payload.kind == .note ? "Note ready" : "Meeting created"
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else {
            guard let m = selectedMeeting else { return }
            startRecording(meetingId: m.id)
        }
    }

    func startRecording(meetingId: String) {
        isRecording = true
        recordingSeconds = 0
        statusMessage = "Starting capture…"
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in recordingSeconds += 1 }
        }
        Task {
            do {
                try await recorder.start(meetingId: meetingId)
                await MainActor.run {
                    if recorder.isCapturingSystemAudio {
                        statusMessage = "Recording mic + system audio"
                    } else {
                        statusMessage = "Recording mic only (no system audio). Toggle Grist OFF→ON in Screen Recording, quit app, relaunch."
                    }
                }
            } catch {
                await MainActor.run {
                    isRecording = false
                    recordingTimer?.invalidate()
                    statusMessage = "Mic error"
                }
            }
        }
    }

    func stopRecording() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        let capturedDuration = recordingSeconds
        recordingSeconds = 0
        statusMessage = "Transcribing…"

        guard let m = selectedMeeting else { return }
        Task {
            await recorder.stop()
            let transcript = await transcriber.transcribe(meetingId: m.id)
            await MainActor.run {
                selectedMeeting?.transcript = transcript
                if capturedDuration > 0 {
                    selectedMeeting?.durationSeconds = max(selectedMeeting?.durationSeconds ?? 0, capturedDuration)
                }
                saveMeeting()
                statusMessage = ""

                let meetingIdToRAG = selectedMeeting?.id
                let transcriptToRAG = transcript

                if autoEnhance {
                    runEnhance()
                } else if !(transcriptToRAG.hasPrefix("[Error")) {
                    // Still name the item even if summary is skipped
                    generateAutoTitle(force: false)
                }

                if let mid = meetingIdToRAG, !transcriptToRAG.isEmpty, !transcriptToRAG.hasPrefix("[Error") {
                    Task {
                        await RAGEngine.shared.processTranscriptForRAG(meetingId: mid, transcript: transcriptToRAG)
                    }
                }
            }
        }
    }

    // MARK: - AI

    func runEnhance() {
        guard let m = selectedMeeting else { return }

        // Prefer transcript; for notes fall back to written body.
        let transcriptSource: String = {
            if !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error") {
                return m.transcript
            }
            return m.manualNotes
        }()
        let notesSource: String = {
            // If we're enhancing from note body, don't double-send as both fields
            if m.transcript.isEmpty || m.transcript.hasPrefix("[Error") {
                return ""
            }
            return m.manualNotes
        }()

        guard !transcriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = m.isNoteType ? "Write something first" : "No transcript yet"
            return
        }
        if m.transcript.hasPrefix("[Error") && m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Transcription failed — fix capture/Whisper, then re-record"
            return
        }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else { statusMessage = "Enter model name"; return }

        statusMessage = "Enhancing…"
        // Notes: use a readable summary style even if template is the type marker "Note"
        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        let applyTitle = m.isPlaceholderTitle

        Task {
            do {
                // Single model call: TITLE: … + markdown summary
                let result = try await ollama.enhance(
                    transcript: transcriptSource,
                    notes: notesSource,
                    template: templateName,
                    customPrompt: customPrompt,
                    model: model
                )
                await MainActor.run {
                    selectedMeeting?.summary = result.summary
                    if applyTitle, let title = result.title, !title.isEmpty,
                       selectedMeeting?.isPlaceholderTitle == true {
                        selectedMeeting?.title = title
                    }
                    saveMeeting()
                    statusMessage = "Done"
                    selectedTab = "summary"
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Items missing a real title and/or a folder, with enough content to organize.
    var itemsNeedingOrganize: [Meeting] {
        meetings.filter { m in
            let unfiled = (m.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let untitled = m.isPlaceholderTitle
            guard unfiled || untitled else { return false }
            let content = organizeContent(for: m)
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !content.hasPrefix("[Error")
        }
    }

    private func organizeContent(for m: Meeting) -> String {
        if !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error") { return m.transcript }
        if !m.manualNotes.isEmpty { return m.manualNotes }
        return m.summary
    }

    /// Single-button: fix missing titles + folders, then show a report popup.
    func runAutoOrganize() {
        let targets = itemsNeedingOrganize
        guard !targets.isEmpty else {
            organizeReportTitle = "Auto-organize"
            organizeReportLines = ["Nothing to do — every item already has a name and folder (or no content yet)."]
            showingOrganizeReport = true
            return
        }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else {
            statusMessage = "Pick an AI model first"
            return
        }

        isOrganizing = true
        statusMessage = "Organizing \(targets.count)…"
        let folderSnapshot = folders

        Task {
            var lines: [String] = []
            var success = 0
            var failed = 0

            for m in targets {
                let needsTitle = m.isPlaceholderTitle
                let needsFolder = (m.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                let content = organizeContent(for: m)
                let oldTitle = m.title

                do {
                    let result = try await ollama.organizeMetadata(
                        content: content,
                        kind: m.kindLabel.lowercased(),
                        existingFolders: folderSnapshot,
                        needsTitle: needsTitle,
                        needsFolder: needsFolder,
                        model: model
                    )

                    var updated = m
                    var parts: [String] = []

                    if needsTitle, let t = result.title, !t.isEmpty {
                        updated.title = t
                        parts.append("titled “\(t)”")
                    }
                    if needsFolder, let f = result.folder, !f.isEmpty {
                        updated.groupName = f
                        await MainActor.run { db.saveFolder(f) }
                        parts.append("filed in “\(f)”")
                    }

                    if parts.isEmpty {
                        lines.append("• \(oldTitle) — no change (AI returned KEEP/NONE)")
                    } else {
                        await MainActor.run {
                            db.saveMeeting(updated)
                        }
                        success += 1
                        let label = needsTitle ? oldTitle : updated.title
                        lines.append("• \(label) → " + parts.joined(separator: ", "))
                    }
                } catch {
                    failed += 1
                    lines.append("• \(oldTitle) — failed: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                loadMeetings()
                isOrganizing = false
                statusMessage = "Organized \(success)"
                organizeReportTitle = failed == 0
                    ? "Organized \(success) item\(success == 1 ? "" : "s")"
                    : "Organized \(success), \(failed) failed"
                organizeReportLines = lines
                showingOrganizeReport = true
            }
        }
    }

    /// AI title from transcript/summary. By default only replaces placeholder titles.
    func generateAutoTitle(force: Bool = false) {
        guard let m = selectedMeeting else { return }
        let source: String = {
            if !m.summary.isEmpty { return m.summary }
            if !m.transcript.isEmpty { return m.transcript }
            return m.manualNotes
        }()
        guard !source.isEmpty, !source.hasPrefix("[Error") else { return }
        guard force || m.isPlaceholderTitle else { return }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else { return }
        let kind = m.kindLabel.lowercased()
        statusMessage = "Titling…"

        Task {
            do {
                let title = try await ollama.suggestTitle(content: source, kind: kind, model: model)
                await MainActor.run {
                    if !title.isEmpty {
                        selectedMeeting?.title = title
                        saveMeeting()
                    }
                    statusMessage = ""
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Title failed"
                }
            }
        }
    }
    
    func copySummaryToClipboard() {
        guard let summary = selectedMeeting?.summary, !summary.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
    }

    // MARK: - Helpers

    func formattedDuration(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let meeting: Meeting
    let isSelected: Bool
    var searchQuery: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: meeting.isNoteType ? "note.text" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(meeting.isNoteType ? .blue : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let snippet = matchSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Text(meeting.kindLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(meeting.isNoteType ? .blue : .secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(relativeTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let dur = meeting.formattedDuration {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(dur)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let folder = meeting.groupName, !folder.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if !meeting.summary.isEmpty {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        } else if !meeting.transcript.isEmpty {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                // Export is handled by parent when available; post so MainView can listen — use Notification
                NotificationCenter.default.post(name: .exportMeetingRequested, object: meeting.id)
            } label: {
                Label("Export Markdown…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Database.shared.softDeleteMeeting(id: meeting.id)
                NotificationCenter.default.post(name: .meetingDeleted, object: nil)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Short excerpt around the first search hit (title hits skip snippet).
    private var matchSnippet: String? {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if meeting.title.localizedCaseInsensitiveContains(q) {
            if let folder = meeting.groupName, !folder.isEmpty {
                return "\(meeting.kindLabel) · \(folder)"
            }
            return meeting.kindLabel
        }
        for field in [meeting.summary, meeting.manualNotes, meeting.transcript] {
            if let snip = Self.snippet(in: field, around: q) {
                return snip
            }
        }
        return nil
    }

    private static func snippet(in text: String, around query: String, radius: Int = 42) -> String? {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        return prefix + s + suffix
    }

    var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: meeting.timestamp), relativeTo: Date())
    }
}

// MARK: - Chat View (item / global)

enum ChatScope: Equatable {
    case item(Meeting)
    case global

    /// Per-item history so folder mates don’t share one thread with the open note.
    var historyKey: String {
        switch self {
        case .item(let m): return "item:\(m.id)"
        case .global: return "__global__"
        }
    }

    var emptyTitle: String {
        switch self {
        case .item: return "Ask about this note or meeting"
        case .global: return "Ask across your whole library"
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
            return "Searches all notes and meetings. Best with nomic-embed-text installed."
        }
    }

    var focusedMeetingId: String? {
        if case .item(let m) = self { return m.id }
        return nil
    }
}

struct ChatView: View {
    let scope: ChatScope
    let selectedModel: String
    let customModelName: String

    @State private var chatHistory: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking = false

    /// Cap per item when stuffing (characters).
    private let itemContextLimit = 80_000
    private let multiItemContextLimit = 12_000

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if chatHistory.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(scope.emptyTitle)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(scope.emptySubtitle)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                        }
                        .padding(.top, 60)
                    } else {
                        ForEach(chatHistory) { msg in
                            ChatBubble(message: msg)
                        }
                    }
                    if isThinking {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("AI is thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding()
            }

            Divider()
            HStack(spacing: 12) {
                TextField("Ask about this content…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1))
                    .onSubmit { sendMessage() }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isThinking ? Color.gray.opacity(0.5) : Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .shadow(color: .black.opacity(0.05), radius: 10, y: -5)
        }
        .onAppear { loadHistory() }
        .onChange(of: scope.historyKey) { _, _ in loadHistory() }
    }

    func loadHistory() {
        chatHistory = Database.shared.fetchChatMessages(forGroup: scope.historyKey)
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
            // Chat on an open item = that item only (folder-wide synthesis is “Summarize folder”)
            let m = freshMeeting(id: meeting.id, fallback: meeting)
            return [m]
        }
    }

    /// Prefer AI summary + written notes + transcript (all three).
    private func contextBlob(for m: Meeting, limit: Int) -> String {
        var parts: [String] = []
        let summary = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { parts.append("### AI Summary\n\(summary)") }
        if !notes.isEmpty { parts.append("### Notes / article body\n\(notes)") }
        if !transcript.isEmpty { parts.append("### Transcript / captions\n\(transcript)") }
        var blob = parts.joined(separator: "\n\n")
        if blob.count > limit {
            blob = String(blob.prefix(limit)) + "\n\n[…truncated…]"
        }
        return blob
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        isThinking = true

        let group = scope.historyKey
        let userMsg = ChatMessage(id: UUID().uuidString, groupName: group, role: "user", content: text, timestamp: Date().timeIntervalSince1970)
        chatHistory.append(userMsg)
        Database.shared.saveChatMessage(userMsg)

        // Snapshot history for the request (includes the new user msg)
        let historySnapshot = chatHistory

        Task {
            do {
                let model = selectedModel == "custom" ? customModelName : selectedModel
                let meetingsInContext = contextMeetings()

                var documentBlock = ""
                let isSingleItem = {
                    if case .item = scope { return true }
                    return false
                }()

                if isSingleItem, let m = meetingsInContext.first {
                    let blob = contextBlob(for: m, limit: itemContextLimit)
                    if blob.isEmpty {
                        documentBlock = "(No summary, notes, or transcript saved on this item yet.)"
                    } else {
                        documentBlock = """
                        === OPEN ITEM: \(m.kindLabel) — \(m.title) ===
                        \(blob)
                        """
                    }
                } else {
                    // Global / multi: pin nothing; use RAG with stuffing fallback
                    let useRAG = meetingsInContext.count > 4
                    if useRAG {
                        let meetingIds = meetingsInContext.map { $0.id }
                        let topChunks = (try? await RAGEngine.shared.search(query: text, meetingIds: meetingIds, topK: 20)) ?? []
                        if topChunks.isEmpty {
                            for m in meetingsInContext.prefix(10) {
                                let blob = contextBlob(for: m, limit: multiItemContextLimit)
                                if blob.isEmpty { continue }
                                documentBlock += "=== \(m.kindLabel): \(m.title) ===\n\(blob)\n\n"
                            }
                        } else {
                            documentBlock += "=== RELEVANT EXCERPTS ===\n"
                            for chunk in topChunks {
                                let parentTitle = meetingsInContext.first(where: { $0.id == chunk.meetingId })?.title ?? "Unknown"
                                documentBlock += "[From \(parentTitle)]:\n\(chunk.text)\n\n"
                            }
                            // Also include full AI summaries for hit parents (cheap, high signal)
                            var seen = Set<String>()
                            for chunk in topChunks {
                                guard seen.insert(chunk.meetingId).inserted,
                                      let m = meetingsInContext.first(where: { $0.id == chunk.meetingId }),
                                      !m.summary.isEmpty else { continue }
                                documentBlock += "=== AI Summary: \(m.title) ===\n\(m.summary.prefix(4000))\n\n"
                            }
                        }
                    } else {
                        for m in meetingsInContext {
                            let blob = contextBlob(for: m, limit: multiItemContextLimit)
                            if blob.isEmpty { continue }
                            documentBlock += "=== \(m.kindLabel): \(m.title) ===\n\(blob)\n\n"
                        }
                    }
                }

                let systemPrompt = """
                You are Grist’s knowledge assistant. You already have the user’s notes/meetings in the DOCUMENT block below.

                Rules:
                1. Answer using ONLY that document (and prior chat turns).
                2. NEVER ask the user to paste, upload, or “provide the blog/article” — it is already in DOCUMENT if available.
                3. If DOCUMENT is empty, say this item has no content yet.
                4. Prefer AI Summary when present; use Notes and Transcript for detail.
                5. Cite the item title when useful. Be concrete.
                """

                // Small local models often ignore pure system messages — put DOCUMENT in a user turn too.
                var apiMessages: [OllamaClient.OllamaChatMessage] = [
                    OllamaClient.OllamaChatMessage(role: "system", content: systemPrompt),
                    OllamaClient.OllamaChatMessage(
                        role: "user",
                        content: "DOCUMENT (source material — use this to answer):\n\n\(documentBlock)"
                    ),
                    OllamaClient.OllamaChatMessage(
                        role: "assistant",
                        content: "I have the document loaded. I will answer only from it and will not ask you to paste it."
                    ),
                ]
                for msg in historySnapshot {
                    apiMessages.append(OllamaClient.OllamaChatMessage(role: msg.role, content: msg.content))
                }

                let response = try await OllamaClient.shared.chat(messages: apiMessages, model: model)

                await MainActor.run {
                    let aiMsg = ChatMessage(id: UUID().uuidString, groupName: group, role: "assistant", content: response.content, timestamp: Date().timeIntervalSince1970)
                    chatHistory.append(aiMsg)
                    Database.shared.saveChatMessage(aiMsg)
                    isThinking = false
                }
            } catch {
                await MainActor.run {
                    let errorMsg = ChatMessage(id: UUID().uuidString, groupName: group, role: "assistant", content: "Error: \(error.localizedDescription)", timestamp: Date().timeIntervalSince1970)
                    chatHistory.append(errorMsg)
                    isThinking = false
                }
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
                Text(LocalizedStringKey(message.content))
                    .padding(14)
                    .background(LinearGradient(colors: [Color.blue, Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 2)
            } else {
                Text(LocalizedStringKey(message.content))
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
                Spacer()
            }
        }
    }
}

// MARK: - Create Item Sheet (self-contained kind state)

/// Owns Meeting/Note selection locally so parent state can never force "Meeting".
struct CreateItemSheet: View {
    let initialKind: CreateKind
    let folders: [String]
    let presetModels: [String]
    let templates: [String]
    let customTemplates: [AITemplate]
    let initialFolder: String
    let initialModel: String
    let onCancel: () -> Void
    let onCreate: (CreateItemPayload) -> Void

    @State private var kind: CreateKind
    @State private var title: String
    @State private var articleURL: String = ""
    @State private var folderSelection: String
    @State private var isCreatingNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var template: String
    @State private var model: String
    @State private var autoStartRecording: Bool

    init(
        initialKind: CreateKind,
        folders: [String],
        presetModels: [String],
        templates: [String],
        customTemplates: [AITemplate],
        initialFolder: String,
        initialModel: String,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (CreateItemPayload) -> Void
    ) {
        self.initialKind = initialKind
        self.folders = folders
        self.presetModels = presetModels
        self.templates = templates
        self.customTemplates = customTemplates
        self.initialFolder = initialFolder
        self.initialModel = initialModel
        self.onCancel = onCancel
        self.onCreate = onCreate

        _kind = State(initialValue: initialKind)
        let defaultTitle: String = {
            switch initialKind {
            case .note, .article: return "Untitled Note"
            case .meeting: return "Untitled Meeting"
            }
        }()
        _title = State(initialValue: defaultTitle)
        _folderSelection = State(initialValue: initialFolder)
        _template = State(initialValue: (initialKind == .note || initialKind == .article) ? "Note" : "Standard Summary")
        _model = State(initialValue: initialModel)
        _autoStartRecording = State(initialValue: initialKind == .meeting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create \(kind.title)")
                        .font(.title2.weight(.bold))
                    Text(kind.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 3 type tiles can wrap — use LazyVGrid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(CreateKind.allCases) { k in
                            kindTile(k)
                        }
                    }

                    if kind == .article {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("URL(S)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                let n = MainView.parseImportURLs(from: articleURL).count
                                if n > 1 {
                                    Text("\(n) links")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            TextEditor(text: $articleURL)
                                .font(.body)
                                .frame(minHeight: 88, maxHeight: 130)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .topLeading) {
                                    if articleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("One or more links — one per line\nhttps://… article or YouTube")
                                            .font(.body)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 16)
                                            .allowsHitTesting(false)
                                    }
                                }
                            let parsed = MainView.parseImportURLs(from: articleURL)
                            let ytCount = parsed.filter { YouTubeImporter.isYouTubeURL($0) }.count
                            if ytCount > 0 {
                                Label(
                                    YouTubeImporter.resolveYtDlpPath() == nil
                                        ? "\(ytCount) YouTube — install yt-dlp: brew install yt-dlp"
                                        : "\(ytCount) YouTube — will import captions",
                                    systemImage: "play.rectangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(YouTubeImporter.resolveYtDlpPath() == nil ? .orange : .secondary)
                            } else if parsed.count > 1 {
                                Text("Will import \(parsed.count) pages as separate notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TITLE")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField(kind == .meeting ? "e.g. Weekly Sync" : "e.g. Product ideas", text: $title)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("FOLDER")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(folderSelection.isEmpty ? "Unfiled" : folderSelection)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("Unfiled", icon: "tray", selected: folderSelection.isEmpty && !isCreatingNewFolder) {
                                    isCreatingNewFolder = false
                                    folderSelection = ""
                                    newFolderName = ""
                                }
                                ForEach(folders.sorted(), id: \.self) { name in
                                    chip(name, icon: "folder.fill", selected: folderSelection == name && !isCreatingNewFolder) {
                                        isCreatingNewFolder = false
                                        folderSelection = name
                                        newFolderName = ""
                                    }
                                }
                                chip("New folder", icon: "folder.badge.plus", selected: isCreatingNewFolder) {
                                    isCreatingNewFolder = true
                                    folderSelection = ""
                                }
                            }
                        }

                        if isCreatingNewFolder {
                            TextField("Folder name", text: $newFolderName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onChange(of: newFolderName) { _, val in
                                    folderSelection = val.trimmingCharacters(in: .whitespaces)
                                }
                        }
                    }

                    if kind == .meeting {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MEETING OPTIONS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Template")
                                Spacer()
                                Picker("", selection: $template) {
                                    ForEach(templates, id: \.self) { t in Text(t).tag(t) }
                                    if !customTemplates.isEmpty {
                                        Divider()
                                        ForEach(customTemplates) { ct in
                                            Text(ct.name).tag(ct.name)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            HStack {
                                Text("AI Model")
                                Spacer()
                                Picker("", selection: $model) {
                                    ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Toggle(isOn: $autoStartRecording) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Start recording immediately")
                                    Text("Uses mic + system audio when permitted")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } else if kind == .note {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Creates a blank note. Opens the writing surface — no recording.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Fetches the page or YouTube captions, creates a Note, and can Enhance automatically if Auto is on.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button {
                    let folder: String? = {
                        if isCreatingNewFolder {
                            let n = newFolderName.trimmingCharacters(in: .whitespaces)
                            return n.isEmpty ? nil : n
                        }
                        let n = folderSelection.trimmingCharacters(in: .whitespaces)
                        return n.isEmpty ? nil : n
                    }()
                    let url = articleURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(CreateItemPayload(
                        kind: kind,
                        title: title,
                        folderName: folder,
                        template: (kind == .note || kind == .article) ? "Note" : template,
                        model: model,
                        autoStartRecording: kind == .meeting && autoStartRecording,
                        articleURL: kind == .article ? url : nil
                    ))
                } label: {
                    Label(createButtonTitle, systemImage: createButtonIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(kind.accent)
                .disabled(kind == .article && MainView.parseImportURLs(from: articleURL).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: kind == .meeting ? 640 : 520)
        .animation(.easeInOut(duration: 0.2), value: kind)
    }

    private var createButtonTitle: String {
        switch kind {
        case .meeting: return autoStartRecording ? "Start Meeting" : "Create Meeting"
        case .note: return "Create Note"
        case .article:
            let n = MainView.parseImportURLs(from: articleURL).count
            return n > 1 ? "Import \(n) URLs" : "Import Article"
        }
    }

    private var createButtonIcon: String {
        switch kind {
        case .meeting: return "record.circle"
        case .note: return "square.and.pencil"
        case .article: return "square.and.arrow.down"
        }
    }

    private func kindTile(_ k: CreateKind) -> some View {
        let selected = kind == k
        return Button {
            kind = k
            autoStartRecording = (k == .meeting)
            switch k {
            case .note, .article:
                template = "Note"
                if isPlaceholderTitle(title) { title = "Untitled Note" }
            case .meeting:
                if template == "Note" { template = "Standard Summary" }
                if isPlaceholderTitle(title) { title = "Untitled Meeting" }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: k.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(k.accent)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? k.accent : Color.secondary.opacity(0.35))
                }
                Text(k.title)
                    .font(.headline)
                Text(k.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(selected ? k.accent.opacity(0.14) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? k.accent.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func isPlaceholderTitle(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.hasPrefix("Untitled ") || s.hasPrefix("Meeting ") || s.hasPrefix("Note ")
    }
}
