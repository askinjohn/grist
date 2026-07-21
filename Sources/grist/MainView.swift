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
}

struct MeetingGroup: Identifiable {
    var id: String { name }
    let name: String
    let meetings: [Meeting]
}

// MARK: - Root View (Handles Sheet + Keyboard)

struct RootView: View {
    @State private var showingNewMeetingSheet = false

    var body: some View {
        MainView(showingNewMeetingSheet: $showingNewMeetingSheet)
            .onReceive(NotificationCenter.default.publisher(for: .newMeetingRequested)) { _ in
                showingNewMeetingSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetingDeleted)) { _ in
                // Using NotificationCenter to tell MainView to reload if needed,
                // but we can just handle it inside MainView if we want.
                // It's cleaner to handle it directly inside MainView's state.
            }
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
    


    // New Meeting Form
    @State private var newTitle = ""
    @State private var newGroup = ""
    @State private var newTemplate = "Standard Summary"
    @State private var newModel = "gemma2:2b"
    @State private var autoStartRecording = true

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
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            if let _ = selectedMeeting {
                detailContent
            } else {
                emptyDetailPlaceholder
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewMeetingSheet) { newMeetingSheet }
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
            Button {
                newTitle = "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                showingNewMeetingSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Meeting")
                    Spacer()
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            
            List(selection: $selectedMeeting) {
            ForEach(groupedMeetings) { group in
                Section(group.name) {
                    ForEach(group.meetings) { meeting in
                        SidebarRow(meeting: meeting, isSelected: selectedMeeting?.id == meeting.id)
                            .tag(meeting)
                            .draggable(meeting.id)
                    }
                }
                .dropDestination(for: String.self) { items, location in
                    guard let meetingId = items.first else { return false }
                    var destGroup: String? = group.name
                    if destGroup == "Today" || destGroup == "Yesterday" || destGroup == "Last 7 Days" || destGroup == "Older" {
                        destGroup = nil
                    } else if destGroup?.hasPrefix("📁 ") == true {
                        destGroup = String(destGroup!.dropFirst(2))
                    }
                    
                    if var m = db.getMeeting(id: meetingId) {
                        m.groupName = destGroup
                        db.saveMeeting(m)
                        loadMeetings()
                        return true
                    }
                    return false
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        
        } // End of VStack
        .navigationTitle("Grist")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newFolderName = ""
                    showingNewFolderAlert = true
                } label: {
                    Label("Folder", systemImage: "folder.badge.plus")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "gear")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if isImportingUrl {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        importUrlString = ""
                        showingImportUrlAlert = true
                    } label: {
                        Label("Import", systemImage: "link.badge.plus")
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.bar)
            .alert("Import Failed", isPresented: $showingImportErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importErrorMessage)
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    db.saveFolder(name)
                    loadMeetings()
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingImportUrlAlert) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import from URL").font(.headline)
                Text("Paste a Blog article or web link to instantly summarize it.")
                TextField("https://youtube.com/...", text: $importUrlString)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 350)
                HStack {
                    Spacer()
                    Button("Cancel") { showingImportUrlAlert = false }
                    Button("Import") {
                        showingImportUrlAlert = false
                        importFromUrl()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
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
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("No Meeting Selected")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Choose a meeting from the sidebar or press ⌘N to start a new one.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("New Meeting") {
                newTitle = "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                showingNewMeetingSheet = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
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
                newTitle = "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                showingNewMeetingSheet = true
            } label: {
                Label("New Meeting", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New Meeting (⌘N)")
        }
    }

    @ToolbarContentBuilder
    var detailToolbar: some ToolbarContent {
        // Editable title in toolbar centre
        ToolbarItem(placement: .principal) {
            TextField("Meeting Title", text: Binding(
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

    // MARK: - New Meeting Sheet

    var newMeetingSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sheet header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Session")
                        .font(.title2.weight(.bold))
                    Text("Configure your meeting session")
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
            }
            .padding(24)

            Divider()

            // Form
            Form {
                Section {
                    TextField("e.g. Weekly Sync", text: $newTitle)
                    TextField("Group/Folder (Optional)", text: $newGroup)
                } header: {
                    Text("TITLE & GROUP")
                }

                Section {
                    Picker("Template", selection: $newTemplate) {
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
                    Picker("AI Model", selection: $newModel) {
                        ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
                    }
                } header: {
                    Text("AI SETTINGS")
                }

                Section {
                    Toggle("Start recording immediately", isOn: $autoStartRecording)
                } header: {
                    Text("RECORDING")
                } footer: {
                    Text("You can also start recording manually from the toolbar.")
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    showingNewMeetingSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Session") {
                    createSession()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 460, height: 500)
    }

    // MARK: - Computed Data

    var filteredMeetings: [Meeting] {
        guard !searchText.isEmpty else { return meetings }
        return meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.transcript.localizedCaseInsensitiveContains(searchText)
        }
    }

    var groupedMeetings: [MeetingGroup] {
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
        
        let allFolderNames = Set(folders + customGroups.keys)
        
        for name in allFolderNames.sorted() {
            let list = customGroups[name] ?? []
            result.append(MeetingGroup(name: "📁 " + name, meetings: list.sorted { $0.timestamp > $1.timestamp }))
        }
        
        let cal = Calendar.current
        let now = Date()
        var today: [Meeting] = [], yesterday: [Meeting] = [], week: [Meeting] = [], older: [Meeting] = []

        for m in timeBased {
            let d = Date(timeIntervalSince1970: m.timestamp)
            if cal.isDateInToday(d) { today.append(m) }
            else if cal.isDateInYesterday(d) { yesterday.append(m) }
            else if let diff = cal.dateComponents([.day], from: d, to: now).day, diff <= 7 { week.append(m) }
            else { older.append(m) }
        }

        func grp(_ name: String, _ list: [Meeting]) -> MeetingGroup? {
            list.isEmpty ? nil : MeetingGroup(name: name, meetings: list.sorted { $0.timestamp > $1.timestamp })
        }

        let timeGroups = [grp("Today", today), grp("Yesterday", yesterday), grp("Last 7 Days", week), grp("Older", older)]
            .compactMap { $0 }
        
        result.append(contentsOf: timeGroups)
        return result
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
                    var newMeeting = Meeting(
                        id: UUID().uuidString,
                        title: result.title,
                        timestamp: Date().timeIntervalSince1970,
                        manualNotes: "",
                        transcript: result.content,
                        summary: "",
                        template: selectedTemplate
                    )
                    newMeeting.transcript = result.content
                    newMeeting.template = selectedTemplate
                    
                    db.saveMeeting(newMeeting)
                    loadMeetings()
                    selectedMeeting = meetings.first(where: { $0.id == newMeeting.id })
                    selectedTab = "summary"
                    
                    // Auto-enhance
                    if autoEnhance {
                        logImport("Triggering runEnhance()")
                        runEnhance()
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
            ? "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            : newTitle
        let group = newGroup.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newGroup
        let m = Meeting(id: id, title: title, timestamp: Date().timeIntervalSince1970,
                        manualNotes: "", transcript: "", summary: "", template: newTemplate, groupName: group, isDeleted: false)
        selectedModel = newModel
        selectedTemplate = newTemplate
        db.saveMeeting(m)
        loadMeetings()
        selectedMeeting = m

        if autoStartRecording { startRecording(meetingId: id) }
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
        recordingSeconds = 0
        statusMessage = "Transcribing…"

        guard let m = selectedMeeting else { return }
        Task {
            await recorder.stop()
            let transcript = await transcriber.transcribe(meetingId: m.id)
            await MainActor.run {
                selectedMeeting?.transcript = transcript
                saveMeeting()
                statusMessage = ""
                
                let meetingIdToRAG = selectedMeeting?.id
                let transcriptToRAG = transcript
                
                if autoEnhance {
                    runEnhance()
                }
                
                if let mid = meetingIdToRAG, !transcriptToRAG.isEmpty {
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

        Task {
            do {
                let enhanced = try await ollama.enhance(
                    transcript: m.transcript,
                    notes: m.manualNotes,
                    template: templateName,
                    customPrompt: customPrompt,
                    model: model
                )
                await MainActor.run {
                    selectedMeeting?.summary = enhanced
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
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !meeting.summary.isEmpty {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                }
                if !meeting.transcript.isEmpty && meeting.summary.isEmpty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                Database.shared.softDeleteMeeting(id: meeting.id)
                NotificationCenter.default.post(name: .meetingDeleted, object: nil)
            } label: {
                Label("Delete Meeting", systemImage: "trash")
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
