import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Data Methods

    func loadMeetings() {
        meetings = db.fetchActiveMeetings()
        folders = db.fetchFolders()
        loadTasks()
        if selectedMeeting == nil { selectedMeeting = meetings.first }
    }

    /// Re-read SQLite when the app becomes key again so MCP / external DB writes show up.
    /// Keeps the open note’s in-memory editor state (edits already autosave) to avoid cursor jumps.
    func refreshLibraryOnFocus() {
        guard !isRefreshingLibrary else { return }
        // Don’t fight in-progress capture / import / AI work.
        if isRecording || isEnhancing || isImportingUrl || isFolderSummarizing || isOrganizing
            || isExtractingTasks || isImportingSuggestedYouTube || isAttachingFiles
            || statusMessage == "Transcribing…" || statusMessage.hasPrefix("Enhancing") {
            return
        }

        isRefreshingLibrary = true
        let previousId = selectedMeeting?.id
        let previousTaskId = selectedTask?.id
        let prior = selectedMeeting

        meetings = db.fetchActiveMeetings()
        folders = db.fetchFolders()
        loadTasks()

        if let previousId {
            if let fresh = meetings.first(where: { $0.id == previousId }) {
                // Reload open note from DB when MCP/external writers changed it and
                // local editor content still matches the last-known disk snapshot
                // (autosave keeps them equal when the user typed; MCP updates diverge).
                if let prior,
                   prior.manualNotes != fresh.manualNotes
                    || prior.transcript != fresh.transcript
                    || prior.summary != fresh.summary
                    || prior.title != fresh.title {
                    selectedMeeting = fresh
                    statusMessage = "Note updated from disk"
                }
            } else {
                selectedMeeting = meetings.first
            }
        } else if selectedMeeting == nil {
            selectedMeeting = meetings.first
        }

        if let previousTaskId {
            selectedTask = tasks.first(where: { $0.id == previousTaskId })
        }

        // SQLite is fast — hold the banner briefly so the indicator is readable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            isRefreshingLibrary = false
        }
    }

    var libraryRefreshBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Fetching latest notes…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel("Fetching latest notes")
    }

    func loadTasks() {
        tasks = db.fetchTasks(includeDone: true)
        if let id = selectedTask?.id {
            selectedTask = tasks.first(where: { $0.id == id })
        }
    }

    func toggleTaskDone(_ task: QuernTask) {
        var t = task
        if t.isDone {
            t.status = "open"
            t.completedAt = nil
        } else {
            t.status = "done"
            t.completedAt = Date().timeIntervalSince1970
        }
        db.saveTask(t)
        loadTasks()
        if selectedTask?.id == t.id { selectedTask = t }
    }

    func createManualTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let source: Meeting? = (newTaskLinkToOpenItem ? selectedMeeting : nil)
        let task = QuernTask.manual(
            title: title,
            notes: newTaskNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source
        )
        db.saveTask(task)
        newTaskTitle = ""
        newTaskNotes = ""
        newTaskLinkToOpenItem = true
        showingNewTaskSheet = false
        loadTasks()
        libraryFilter = .tasks
        focusedFolder = nil
        selectedMeeting = nil
        selectedTask = task
        if let source {
            statusMessage = "Task created (linked to \(source.kindLabel.lowercased()))"
        } else {
            statusMessage = "Task created"
        }
    }

    /// AI extract action items from the open note/meeting into Tasks.
    func extractTasksFromCurrent(force: Bool = false) {
        guard let m = selectedMeeting else { return }
        extractTasks(from: m, force: force)
    }

    func extractTasks(from meeting: Meeting, force: Bool = false) {
        let content = [meeting.summary, meeting.manualNotes, meeting.transcript]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !content.isEmpty else {
            statusMessage = "Nothing to extract tasks from"
            return
        }
        if isExtractingTasks { return }
        isExtractingTasks = true
        statusMessage = "Extracting tasks…"
        let model = selectedModel == "custom" ? customModelName : selectedModel

        Task {
            do {
                let extracted = try await ollama.extractTasks(
                    title: meeting.title,
                    summary: meeting.summary,
                    notes: meeting.manualNotes,
                    transcript: meeting.transcript,
                    model: model
                )
                await MainActor.run {
                    var added = 0
                    for item in extracted {
                        let t = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }
                        if !force, db.hasOpenTask(title: t, sourceMeetingId: meeting.id) {
                            continue
                        }
                        let task = QuernTask.fromExtract(title: t, notes: item.notes, source: meeting)
                        db.saveTask(task)
                        added += 1
                    }
                    loadTasks()
                    isExtractingTasks = false
                    if added == 0 {
                        statusMessage = extracted.isEmpty ? "No tasks found" : "No new tasks (duplicates skipped)"
                    } else {
                        statusMessage = "Added \(added) task\(added == 1 ? "" : "s")"
                    }
                }
            } catch {
                await MainActor.run {
                    isExtractingTasks = false
                    statusMessage = "Task extract failed: \(error.localizedDescription)"
                }
            }
        }
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
        // Debounced RAG index so Ask everything sees notes/summaries
        RAGEngine.shared.scheduleIndex(meeting: m)
        CompanionSyncManager.shared.schedulePush(reason: "save")
    }

    /// Persist + index immediately (imports, enhance, folder summary).
    func saveMeetingAndIndex(_ m: Meeting) {
        db.saveMeeting(m)
        if let idx = meetings.firstIndex(where: { $0.id == m.id }) {
            meetings[idx] = m
        } else if selectedMeeting?.id == m.id {
            selectedMeeting = m
        }
        RAGEngine.shared.indexMeetingNow(m)
        CompanionSyncManager.shared.schedulePush(reason: "save")
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

    /// Create a meeting from a detected call and start recording immediately.
    func startMeetingFromDetection(appName: String?) {
        if isRecording {
            statusMessage = "Already recording"
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showQuernWindowRequested, object: nil)

        let label = appName ?? MeetingDetector.shared.pendingPrompt?.appName ?? "Meeting"
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let title = "\(label) · \(df.string(from: Date()))"

        let payload = CreateItemPayload(
            kind: .meeting,
            title: title,
            folderName: nil,
            template: selectedTemplate,
            model: selectedModel == "custom" ? customModelName : selectedModel,
            autoStartRecording: true,
            articleURL: nil
        )
        MeetingDetector.shared.clearPromptAfterRecordingStarted()
        createSession(from: payload)
        statusMessage = "Recording \(label)"
        QuernLog.log("[MeetingDetect] started recording for \(label)")
    }
}
