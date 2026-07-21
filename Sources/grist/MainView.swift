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
enum CreateKind: String, CaseIterable, Identifiable {
    case meeting
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .note: return "Note"
        }
    }

    var subtitle: String {
        switch self {
        case .meeting: return "Record mic + system audio, then AI summary"
        case .note: return "Write freely — no recording required"
        }
    }

    var icon: String {
        switch self {
        case .meeting: return "waveform.circle.fill"
        case .note: return "note.text"
        }
    }

    var accent: Color {
        switch self {
        case .meeting: return .red
        case .note: return .blue
        }
    }
}

/// Sidebar library scope (fills the lower-left with real navigation).
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case unfiled
    case meetings
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .unfiled: return "Unfiled"
        case .meetings: return "Meetings"
        case .notes: return "Notes"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .unfiled: return "tray"
        case .meetings: return "waveform"
        case .notes: return "note.text"
        }
    }
}

// MARK: - Root View (Handles Sheet + Keyboard)

struct RootView: View {
    @State private var showingNewMeetingSheet = false

    var body: some View {
        MainView(showingNewMeetingSheet: $showingNewMeetingSheet)
    }
}

extension Notification.Name {
    static let meetingDeleted = Notification.Name("meetingDeleted")
}

// MARK: - Main View

struct MainView: View {
    @Binding var showingNewMeetingSheet: Bool
    @Environment(\.openSettings) private var openSettings

    // Data
    @State private var meetings: [Meeting] = []
    @State private var folders: [String] = []
    @State private var selectedMeeting: Meeting? = nil
    @State private var searchText = ""
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showingImportUrlAlert = false
    @State private var importUrlString = ""
    @State private var isImportingUrl = false
    @State private var showingImportErrorAlert = false
    @State private var importErrorMessage = ""
    @State private var showingSettingsSheet = false

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

    // Create sheet form
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
            if let _ = selectedMeeting {
                detailContent
            } else {
                emptyDetailPlaceholder
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewMeetingSheet) { createSheet }
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
                if let m = selectedMeeting, (m.groupName?.isEmpty ?? true), !m.transcript.isEmpty {
                    generateGroupSuggestion(for: m)
                }
            }
        }

        .frame(minWidth: 960, minHeight: 640)
    }

    // MARK: - Sidebar

    @ViewBuilder
    var sidebarContent: some View {
        VStack(spacing: 0) {
            // One-click create: Meeting | Note
            HStack(spacing: 8) {
                sidebarCreateButton(kind: .meeting)
                sidebarCreateButton(kind: .note)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
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

                // ITEMS (filtered list)
                ForEach(groupedMeetings) { group in
                    Section(group.name) {
                        ForEach(group.meetings) { meeting in
                            SidebarRow(meeting: meeting, isSelected: selectedMeeting?.id == meeting.id)
                                .tag(meeting)
                                .draggable(meeting.id)
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        moveMeetings(items, toFolder: dropFolder(fromSection: group.name))
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes & meetings")
        }
        .navigationTitle("Grist")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .alert("Import Failed", isPresented: $showingImportErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
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
        .sheet(isPresented: $showingImportUrlAlert) {
            importURLSheet
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Button {
                openImportSheet()
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
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(filter.label)
                    .font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
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
                openCreateSheet(kind: .meeting)
                newFolderSelection = name
            }
            Button("New note here") {
                openCreateSheet(kind: .note)
                newFolderSelection = name
            }
        }
    }

    private var importURLSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import URL")
                        .font(.title2.weight(.bold))
                    Text("Article or page → note, optionally filed in a folder.")
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("https://…", text: $importUrlString)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

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
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importUrlString.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 380)
    }

    private func openImportSheet() {
        importUrlString = ""
        importIsCreatingFolder = false
        importNewFolderName = ""
        if let f = focusedFolder {
            importFolderSelection = f
        } else if let g = selectedMeeting?.groupName, !g.isEmpty {
            importFolderSelection = g
        } else {
            importFolderSelection = ""
        }
        showingImportUrlAlert = true
    }

    private func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: return meetings.count
        case .unfiled: return meetings.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        case .meetings: return meetings.filter { !$0.isNoteType }.count
        case .notes: return meetings.filter { $0.isNoteType }.count
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
        aiPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { detailToolbar }
    }

    @ViewBuilder
    var manualNotesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: Binding(
                get: { selectedMeeting?.manualNotes ?? "" },
                set: { selectedMeeting?.manualNotes = $0; saveMeeting() }
            ))
            .font(.body)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.textBackgroundColor))
            .padding()
        }
    }

    @ViewBuilder
    var aiPanel: some View {
        VStack(spacing: 0) {
            // AI toolbar
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

            // Content area — WKWebView handles its own scrolling
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
            .disabled(statusMessage == "Enhancing…" || selectedMeeting?.transcript.isEmpty ?? true)
            .controlSize(.regular)
        }
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
                ChatView(meeting: m, selectedModel: selectedModel, customModelName: customModelName)
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

        // Export & Record Actions
        ToolbarItemGroup(placement: .primaryAction) {
            if selectedMeeting != nil && selectedTab == "summary" {
                Button {
                    copySummaryToClipboard()
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                }
                .help("Copy Markdown summary to clipboard")
            }
            
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

    // MARK: - Create Sheet (Meeting / Note)

    var createSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create")
                        .font(.title2.weight(.bold))
                    Text("One click to choose type — add to a folder if you want.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingNewMeetingSheet = false
                } label: {
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
                    // Type tiles — single click
                    HStack(spacing: 12) {
                        ForEach(CreateKind.allCases) { kind in
                            createKindTile(kind)
                        }
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TITLE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(createKind == .meeting ? "e.g. Weekly Sync" : "e.g. Product ideas", text: $newTitle)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // Folder picker — existing folders + unfiled + new
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("FOLDER")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(newFolderSelection.isEmpty ? "Unfiled" : newFolderSelection)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                folderChip(title: "Unfiled", icon: "tray", selected: newFolderSelection.isEmpty && !isCreatingNewFolder) {
                                    isCreatingNewFolder = false
                                    newFolderSelection = ""
                                    newFolderInlineName = ""
                                }
                                ForEach(folders.sorted(), id: \.self) { name in
                                    folderChip(title: name, icon: "folder.fill", selected: newFolderSelection == name && !isCreatingNewFolder) {
                                        isCreatingNewFolder = false
                                        newFolderSelection = name
                                        newFolderInlineName = ""
                                    }
                                }
                                folderChip(title: "New folder", icon: "folder.badge.plus", selected: isCreatingNewFolder) {
                                    isCreatingNewFolder = true
                                    newFolderSelection = ""
                                }
                            }
                        }

                        if isCreatingNewFolder {
                            TextField("Folder name", text: $newFolderInlineName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onChange(of: newFolderInlineName) { _, val in
                                    newFolderSelection = val.trimmingCharacters(in: .whitespaces)
                                }
                        }
                    }

                    if createKind == .meeting {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MEETING OPTIONS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Template")
                                Spacer()
                                Picker("", selection: $newTemplate) {
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
                                Picker("", selection: $newModel) {
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
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Opens a blank note in the editor. You can record later from the toolbar if you need audio.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel") { showingNewMeetingSheet = false }
                Spacer()
                Button {
                    createSession()
                } label: {
                    Label(
                        createKind == .meeting
                            ? (autoStartRecording ? "Start Meeting" : "Create Meeting")
                            : "Create Note",
                        systemImage: createKind == .meeting ? "record.circle" : "square.and.pencil"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(createKind.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: createKind == .meeting ? 620 : 480)
        .animation(.easeInOut(duration: 0.2), value: createKind)
    }

    private func createKindTile(_ kind: CreateKind) -> some View {
        let selected = createKind == kind
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                createKind = kind
                // Sensible defaults when switching type
                if kind == .meeting {
                    autoStartRecording = true
                    if newTitle.hasPrefix("Note ") || newTitle.isEmpty {
                        newTitle = defaultTitle(for: .meeting)
                    }
                    if newTemplate == "Note" { newTemplate = "Standard Summary" }
                } else {
                    autoStartRecording = false
                    if newTitle.hasPrefix("Meeting ") || newTitle.isEmpty {
                        newTitle = defaultTitle(for: .note)
                    }
                    newTemplate = "Note"
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: kind.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(kind.accent)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(kind.accent)
                    }
                }
                Text(kind.title)
                    .font(.headline)
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(selected ? kind.accent.opacity(0.12) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? kind.accent.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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

    private func defaultTitle(for kind: CreateKind) -> String {
        // Placeholder titles are replaced by AI after content exists.
        kind == .meeting ? "Untitled Meeting" : "Untitled Note"
    }

    /// Open create sheet pre-selecting a kind; seed folder from current selection if any.
    func openCreateSheet(kind: CreateKind) {
        createKind = kind
        autoStartRecording = (kind == .meeting)
        newTemplate = kind == .note ? "Note" : "Standard Summary"
        newTitle = defaultTitle(for: kind)
        isCreatingNewFolder = false
        newFolderInlineName = ""
        // Prefer folder of the currently selected item, else unfiled
        if let g = selectedMeeting?.groupName, !g.trimmingCharacters(in: .whitespaces).isEmpty {
            newFolderSelection = g
        } else {
            newFolderSelection = ""
        }
        showingNewMeetingSheet = true
    }

    // MARK: - Computed Data

    var filteredMeetings: [Meeting] {
        var list = meetings

        // Folder focus wins over library filter
        if let folder = focusedFolder {
            list = list.filter { ($0.groupName ?? "") == folder }
        } else {
            switch libraryFilter {
            case .all:
                break
            case .unfiled:
                list = list.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            case .meetings:
                list = list.filter { !$0.isNoteType }
            case .notes:
                list = list.filter { $0.isNoteType }
            }
        }

        guard !searchText.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.transcript.localizedCaseInsensitiveContains(searchText) ||
            $0.manualNotes.localizedCaseInsensitiveContains(searchText) ||
            $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    var groupedMeetings: [MeetingGroup] {
        // Single folder focus → one flat section by time still helps
        if focusedFolder != nil {
            return timeGrouped(filteredMeetings, headerPrefix: nil)
        }

        switch libraryFilter {
        case .unfiled, .meetings, .notes:
            // Don't re-split into every folder; show timeline (and folder name on each row)
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
    
    func importFromUrl() {
        logImport("importFromUrl called with string: '\(importUrlString)'")
        let url = importUrlString.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { 
            logImport("URL was empty, aborting.")
            return 
        }
        
        isImportingUrl = true
        Task {
            logImport("Starting Task to fetch URL: \(url)")
            do {
                let result = try await URLFetcher.shared.fetchContent(from: url)
                logImport("Successfully fetched content: \(result.title) (length: \(result.content.count))")
                
                await MainActor.run {
                    var folder: String? = nil
                    if importIsCreatingFolder {
                        let name = importNewFolderName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty {
                            folder = name
                            db.saveFolder(name)
                        }
                    } else {
                        let name = importFolderSelection.trimmingCharacters(in: .whitespaces)
                        folder = name.isEmpty ? nil : name
                        if let folder { db.saveFolder(folder) }
                    }

                    var newMeeting = Meeting(
                        id: UUID().uuidString,
                        title: result.title,
                        timestamp: Date().timeIntervalSince1970,
                        manualNotes: "",
                        transcript: result.content,
                        summary: "",
                        template: "Note",
                        groupName: folder,
                        isDeleted: false
                    )
                    newMeeting.transcript = result.content

                    db.saveMeeting(newMeeting)
                    loadMeetings()
                    if let folder { focusedFolder = folder }
                    selectedMeeting = meetings.first(where: { $0.id == newMeeting.id })
                    selectedTab = "summary"

                    if autoEnhance {
                        logImport("Triggering runEnhance()")
                        runEnhance()
                    } else if newMeeting.isPlaceholderTitle {
                        generateAutoTitle(force: false)
                    }
                    isImportingUrl = false
                    logImport("Import complete.")
                }
            } catch {
                logImport("Import failed with error: \(error)")
                await MainActor.run { 
                    importErrorMessage = error.localizedDescription
                    showingImportErrorAlert = true
                    isImportingUrl = false 
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

    func createSession() {
        showingNewMeetingSheet = false

        let id = String(Int(Date().timeIntervalSince1970))
        let title = newTitle.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultTitle(for: createKind)
            : newTitle.trimmingCharacters(in: .whitespaces)

        // Resolve folder: chip selection or new folder name
        var folder: String? = nil
        if isCreatingNewFolder {
            let name = newFolderInlineName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                folder = name
                db.saveFolder(name)
            }
        } else {
            let name = newFolderSelection.trimmingCharacters(in: .whitespaces)
            folder = name.isEmpty ? nil : name
            if let folder { db.saveFolder(folder) } // ensure it exists in folders table
        }

        let template = createKind == .note ? "Note" : newTemplate
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

        selectedModel = newModel
        selectedTemplate = template
        db.saveMeeting(m)
        loadMeetings()
        if let folder { focusedFolder = folder }
        selectedMeeting = m
        selectedTab = createKind == .note ? "notes" : "summary"

        if createKind == .meeting && autoStartRecording {
            startRecording(meetingId: id)
        } else {
            statusMessage = createKind == .note ? "Note ready" : "Meeting created"
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
        guard let m = selectedMeeting, !m.transcript.isEmpty else { return }
        // Don't "enhance" failed transcription error strings into fake summaries.
        if m.transcript.hasPrefix("[Error") {
            statusMessage = "Transcription failed — fix capture/Whisper, then re-record"
            return
        }
        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else { statusMessage = "Enter model name"; return }

        statusMessage = "Enhancing…"
        let templateName = m.template
        let customPrompt = customTemplates.first(where: { $0.name == templateName })?.prompt
        let shouldTitle = m.isPlaceholderTitle
        let kind = m.kindLabel.lowercased()
        let contentForTitle = m.transcript

        Task {
            do {
                async let enhancedTask = ollama.enhance(
                    transcript: m.transcript,
                    notes: m.manualNotes,
                    template: templateName,
                    customPrompt: customPrompt,
                    model: model
                )
                async let titleTask: String? = {
                    guard shouldTitle else { return nil }
                    return try? await ollama.suggestTitle(content: contentForTitle, kind: kind, model: model)
                }()

                let enhanced = try await enhancedTask
                let title = await titleTask

                await MainActor.run {
                    selectedMeeting?.summary = enhanced
                    if let title, !title.isEmpty, selectedMeeting?.isPlaceholderTitle == true {
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
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                Database.shared.softDeleteMeeting(id: meeting.id)
                NotificationCenter.default.post(name: .meetingDeleted, object: nil)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: meeting.timestamp), relativeTo: Date())
    }
}

// MARK: - Chat View (RAG Multi-Meeting Chat)
struct ChatView: View {
    let meeting: Meeting
    let selectedModel: String
    let customModelName: String
    
    @State private var chatHistory: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking = false
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if chatHistory.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Ask questions about this meeting")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                            if let group = meeting.groupName {
                                Text("Because this is in the '\(group)' group, the AI will answer using transcripts from ALL meetings in this group.")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 320)
                            }
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
                TextField("Ask anything...", text: $inputText)
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
        .onChange(of: meeting.id) { _, _ in loadHistory() }
    }
    
    func loadHistory() {
        let group = meeting.groupName ?? meeting.id
        chatHistory = Database.shared.fetchChatMessages(forGroup: group)
    }
    
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        isThinking = true
        
        let group = meeting.groupName ?? meeting.id
        let userMsg = ChatMessage(id: UUID().uuidString, groupName: group, role: "user", content: text, timestamp: Date().timeIntervalSince1970)
        chatHistory.append(userMsg)
        Database.shared.saveChatMessage(userMsg)
        
        Task {
            do {
                let model = selectedModel == "custom" ? customModelName : selectedModel
                
                // Fetch context
                let meetingsInContext: [Meeting]
                if let g = meeting.groupName {
                    meetingsInContext = Database.shared.fetchActiveMeetings().filter { $0.groupName == g }
                } else {
                    meetingsInContext = [meeting]
                }
                
                var systemContext = "You are a helpful meeting assistant. Answer the user's questions based ONLY on the following meeting transcripts. If the answer is not in the transcripts, say so.\n\n"
                
                if meetingsInContext.count > 6 {
                    // Use True RAG
                    let meetingIds = meetingsInContext.map { $0.id }
                    let topChunks = try await RAGEngine.shared.search(query: text, meetingIds: meetingIds, topK: 15)
                    
                    systemContext += "=== RELEVANT CONTEXT EXCERPTS ===\n"
                    for chunk in topChunks {
                        let parentTitle = meetingsInContext.first(where: { $0.id == chunk.meetingId })?.title ?? "Unknown Meeting"
                        systemContext += "[From \(parentTitle)]:\n\(chunk.text)\n\n"
                    }
                } else {
                    // Use Context Stuffing
                    for m in meetingsInContext {
                        systemContext += "=== Meeting: \(m.title) (Date: \(Date(timeIntervalSince1970: m.timestamp))) ===\n"
                        systemContext += "\(m.transcript)\n\n"
                    }
                }
                
                var apiMessages: [OllamaClient.OllamaChatMessage] = []
                apiMessages.append(OllamaClient.OllamaChatMessage(role: "system", content: systemContext))
                for msg in chatHistory {
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
