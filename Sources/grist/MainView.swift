import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct MainView: View {
    @Environment(\.openSettings) var openSettings

    // Data
    @State var meetings: [Meeting] = []
    @State var folders: [String] = []
    @State var tasks: [GristTask] = []
    @State var selectedMeeting: Meeting? = nil
    @State var selectedTask: GristTask? = nil
    @State var searchText = ""
    @State var showingNewTaskSheet = false
    @State var newTaskTitle = ""
    @State var newTaskNotes = ""
    /// When creating a task while a note/meeting is open, optionally attach it as source.
    @State var newTaskLinkToOpenItem = true
    @FocusState var newTaskTitleFocused: Bool
    @State var isExtractingTasks = false
    /// open | done | all
    @State var taskListFilter: String = "open"
    @AppStorage("autoExtractTasks") var autoExtractTasks = true
    @AppStorage("healthBannerDismissedAt") var healthBannerDismissedAt: Double = 0
    @State var healthReport: GristHealthReport? = nil
    @State var showingHealthSheet = false
    @State var isCheckingHealth = false
    /// When set, open the best tab for a search hit (summary / notes / transcript).
    @State var pendingSearchReveal = false
    @State var showingNewFolderAlert = false
    @State var newFolderName = ""
    @State var showingImportUrlAlert = false
    @State var importUrlString = ""
    @State var isImportingUrl = false
    /// When true (and an item is selected), fetch content into the current note/meeting instead of creating new ones.
    @State var importAppendToSelected = false
    @State var showingImportErrorAlert = false
    @State var importErrorMessage = ""
    /// When set, Import Failed alert offers “Open in Browser”.
    @State var importErrorOpenURL: String? = nil
    /// After a web article import: offer to pull linked YouTube captions.
    @State var showingYouTubeSuggestAlert = false
    @State var suggestedYouTubeURL: String = ""
    @State var suggestedYouTubeMeetingId: String? = nil
    /// Queue when multi-import finds several pages with YouTube links.
    @State var pendingYouTubeSuggestions: [(meetingId: String, ytURL: String)] = []
    @State var isImportingSuggestedYouTube = false
    @State var showingSettingsSheet = false
    /// Folder-level multi-item summarize
    @State var showingFolderSummarizeSheet = false
    @State var folderSummarizeName: String = ""
    @State var folderSummarizePreset: FolderSummarizePreset = .actionItems
    @State var folderSummarizeCustomSpecs: String = ""
    @State var isFolderSummarizing = false
    /// Export section picker
    @State var showingExportOptionsSheet = false
    @State var exportTargetMeeting: Meeting? = nil
    @State var exportTargetFolder: String? = nil
    @State var exportOptions: ExportOptions = .default

    // AI Config — selectedModel stays in sync with ai-config.json for the active role.
    @State var selectedModel = AIConfigManager.shared.modelName(for: .enhance)
    @State var customModelName = ""
    /// Which ai-config role the model dropdown currently edits (chat / askEverything / enhance).
    @State var modelPickerRole: AIRole = .enhance
    /// True while we push config → dropdown so we don't write that change back to disk.
    @State var isApplyingModelFromConfig = false
    @State var selectedTemplate = "Standard Summary"
    @State var customTemplates: [AITemplate] = []
    @AppStorage("autoEnhance") var autoEnhance = true

    // Recording
    @State var isRecording = false
    @State var recordingSeconds = 0
    @State var statusMessage = ""
    @State var recordingTimer: Timer? = nil

    // UI
    @State var selectedTab = "summary"
    @State var columnVisibility = NavigationSplitViewVisibility.all
    @State var suggestedGroup: String? = nil
    @State var isSuggestingGroup = false
    @State var libraryFilter: LibraryFilter = .all
    /// When set, sidebar shows only this folder (overrides library filter).
    @State var focusedFolder: String? = nil
    /// Accordion: which folders are expanded to list their files.
    @State var expandedFolders: Set<String> = []
    /// Folder currently highlighted as a drop target (drag-and-drop).
    @State var folderDropTarget: String? = nil

    // Create sheet form — present via item so kind is never stale
    @State var createSheetRequest: CreateSheetRequest? = nil
    @State var createKind: CreateKind = .meeting
    @State var newTitle = ""
    /// Empty string = Unfiled; otherwise an existing or newly named folder.
    @State var newFolderSelection: String = ""
    @State var isCreatingNewFolder = false
    @State var newFolderInlineName = ""
    @State var newTemplate = "Standard Summary"
    @State var newModel = AIConfigManager.shared.modelName(for: .enhance)
    @State var autoStartRecording = true

    // Import sheet folder (mirrors create chips)
    @State var importFolderSelection: String = ""
    @State var importIsCreatingFolder = false
    @State var importNewFolderName = ""
    /// Markdown format command for the note body editor.
    @State var noteFormatCommand: MarkdownFormatCommand? = nil
    /// Live text selection from the note editor (for Chat with selection).
    @State var noteSelectedText: String = ""
    /// When set, Chat tab uses only this selected text.
    @State var selectionChat: (id: String, title: String, text: String)? = nil
    @State var noteShowPreview = false

    // Auto-organize
    @State var isOrganizing = false
    @State var showingOrganizeReport = false
    @State var organizeReportLines: [String] = []
    @State var organizeReportTitle = "Auto-organize"

    // Delete folder
    @State var folderPendingDelete: String? = nil
    @State var showingDeleteFolderConfirm = false

    let db = Database.shared
    let recorder = AudioRecorder.shared
    let transcriber = WhisperTranscriber.shared
    let ollama = OllamaClient.shared

    let templates = ["Standard Summary", "Daily Standup", "Sales Call", "Action Items Focus"]
    @State var presetModels: [String] = []

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 288, max: 360)
        } detail: {
            if libraryFilter == .tasks && focusedFolder == nil {
                tasksDetailView
            } else if libraryFilter == .askEverything && focusedFolder == nil {
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
            GristLog.log("[Grist] app MainView.onAppear logFile=\(GristLog.path)")
            loadMeetings()
            loadTemplates()
            // Config → dropdown immediately (don't wait for Ollama)
            ensureConfigModelsInPicker()
            syncModelPickerFromConfig(for: currentModelPickerRole())
            Task {
                do {
                    let models = try await ollama.getModels()
                    await MainActor.run {
                        applyOllamaModelsToPicker(models)
                        syncModelPickerFromConfig(for: currentModelPickerRole())
                    }
                } catch {
                    await MainActor.run {
                        // Keep any config model names already in the list so selection still shows.
                        if presetModels.isEmpty {
                            presetModels = ["Ollama not running"]
                            ensureConfigModelsInPicker()
                        }
                        syncModelPickerFromConfig(for: currentModelPickerRole())
                    }
                }
            }
            refreshHealthCheck(showSheetIfNeeded: true)
        }
        .sheet(isPresented: $showingHealthSheet) {
            healthChecklistSheet
        }
        .onChange(of: libraryFilter) { _, _ in
            syncModelPickerFromConfig(for: currentModelPickerRole())
        }
        .onChange(of: selectedTab) { _, _ in
            syncModelPickerFromConfig(for: currentModelPickerRole())
        }
        .onChange(of: selectedModel) { _, newVal in
            guard !isApplyingModelFromConfig else { return }
            persistModelPickerToConfig(model: newVal)
        }
        .onChange(of: customModelName) { _, newVal in
            guard !isApplyingModelFromConfig else { return }
            if selectedModel == "custom", !newVal.isEmpty {
                persistModelPickerToConfig(model: newVal)
            }
        }
        .onChange(of: showingSettingsSheet) { _, open in
            // After Settings → AI Models edits, reload dropdown from file
            if !open {
                AIConfigManager.shared.reloadFromDisk()
                ensureConfigModelsInPicker()
                syncModelPickerFromConfig(for: currentModelPickerRole())
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
            openExportSheet(meeting: m)
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
}
