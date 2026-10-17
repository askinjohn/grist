import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
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

            if let health = healthReport, !health.issues.isEmpty, shouldShowHealthBanner {
                healthBanner(health)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Navigation only; item and task rows live in the main pane.
            List {
                // LIBRARY
                Section {
                    ForEach(LibraryFilter.allCases) { filter in
                        libraryFilterRow(filter)
                    }
                } header: {
                    Text("Library")
                }

                // FOLDERS — accordion (always visible when browsing items, including Unfiled,
                // so you can drop or “Move to…” unfiled notes into a folder).
                Group {
                    Section {
                        if folders.isEmpty {
                            Text("No folders yet — use + to create one")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(folders.sorted(), id: \.self) { name in
                                folderAccordion(name)
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
                }

            }

            // AppKit can retain an NSOutlineView selection after a filter removes its
            // tagged row, then render that old row over the new content. Rebuild the
            // list whenever its structural scope changes so it cannot keep that state.
            .id(sidebarListContentIdentity)
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes & meetings")
            .onSubmit(of: .search) {
                if let first = filteredMeetings.first {
                    openSearchResult(first)
                }
            }
        }
        .navigationTitle("Quern")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .alert("Quern", isPresented: $showingImportErrorAlert) {
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
                    // Expand in the accordion only — do not enter “focused folder”
                    // mode. Focusing an empty folder while a meeting is open hid that
                    // meeting from the List while selection stayed set, which made
                    // macOS paint a floating ghost row over “Empty folder”.
                    expandedFolders.insert(name)
                    if focusedFolder != nil {
                        focusedFolder = nil
                    }
                    libraryFilter = .all
                    statusMessage = "Folder “\(name)” created"
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename Folder", isPresented: $showingRenameFolderAlert) {
            TextField("Folder name", text: $renameFolderDraft)
            Button("Rename") {
                commitRenameFolder()
            }
            .disabled(renameFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                folderPendingRename = nil
            }
        } message: {
            if let old = folderPendingRename {
                Text("Rename “\(old)” and update all notes in this folder.")
            }
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
        .sheet(isPresented: $showingExportOptionsSheet) {
            exportOptionsSheet
        }
        .sheet(isPresented: $showingNewTaskSheet) {
            newTaskSheet
        }
    }

    var sidebarListContentIdentity: String { libraryFilter.rawValue + (focusedFolder ?? "") }

    // MARK: - Tasks UI

    var canCreateNewTask: Bool {
        !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var newTaskSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuernSheetHeader(
                title: "New task",
                subtitle: "Track something to do — optionally link it to the open note.",
                systemImage: "checklist",
                tint: .purple,
                onClose: { showingNewTaskSheet = false }
            )
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                QuernLabeledField(label: "Task") {
                    TextField("What needs doing?", text: $newTaskTitle)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .gristFieldStyle()
                        .focused($newTaskTitleFocused)
                        .onSubmit {
                            if canCreateNewTask { createManualTask() }
                        }
                }

                QuernLabeledField(label: "Notes") {
                    TextField("Context, owner, deadline…", text: $newTaskNotes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(4...8)
                        .gristFieldStyle(minHeight: 96)
                }

                if let m = selectedMeeting {
                    Toggle(isOn: $newTaskLinkToOpenItem) {
                        HStack(spacing: 10) {
                            Image(systemName: m.isNoteType ? "note.text" : "waveform")
                                .foregroundStyle(m.isNoteType ? .blue : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link to open \(m.isNoteType ? "note" : "meeting")")
                                    .font(.callout.weight(.medium))
                                Text(m.title.isEmpty ? "Untitled" : m.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Spacer(minLength: 0)

            QuernSheetFooter {
                Button("Cancel") { showingNewTaskSheet = false }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button {
                    createManualTask()
                } label: {
                    Label("Create task", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!canCreateNewTask)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460, height: selectedMeeting == nil ? 360 : 420)
        .onAppear {
            newTaskTitleFocused = true
            newTaskLinkToOpenItem = selectedMeeting != nil
        }
    }

    @ViewBuilder
    var tasksDetailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskPageHeader
            Divider()

            if let task = selectedTask {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        toggleTaskDone(task)
                    } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title)
                            .foregroundStyle(task.isDone ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    TextField("Task", text: Binding(
                        get: { selectedTask?.title ?? "" },
                        set: { v in
                            selectedTask?.title = v
                            if var t = selectedTask {
                                t.title = v
                                db.saveTask(t)
                                loadTasks()
                                selectedTask = t
                            }
                        }
                    ))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)

                    Spacer()
                    Button {
                        if let t = selectedTask {
                            db.deleteTask(id: t.id)
                            loadTasks()
                            selectedTask = nil
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)

                Divider()

                Form {
                    Section("Plan") {
                        TextField("Assignee", text: taskBinding(\.assignee, fallback: ""))
                        Toggle("Has due date", isOn: Binding(get: { selectedTask?.dueAt != nil }, set: { enabled in
                            updateSelectedTask { $0.dueAt = enabled ? Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 : nil }
                        }))
                        if selectedTask?.dueAt == nil { Text("No due date").foregroundStyle(.secondary) }
                        Picker("Priority", selection: Binding(
                            get: { selectedTask?.priority ?? "none" },
                            set: { value in
                                guard var t = selectedTask else { return }
                                t.priority = value; selectedTask = t; db.saveTask(t); loadTasks()
                            }
                        )) {
                            Text("No priority").tag("none")
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                        if selectedTask?.dueAt != nil {
                        DatePicker("Due", selection: Binding(
                            get: { Date(timeIntervalSince1970: selectedTask?.dueAt ?? Date().timeIntervalSince1970) },
                            set: { value in
                                guard var t = selectedTask else { return }
                                t.dueAt = Calendar.current.startOfDay(for: value).timeIntervalSince1970
                                selectedTask = t; db.saveTask(t); loadTasks()
                            }
                        ), displayedComponents: .date)
                        }
                        if selectedTask?.dueAt != nil {
                            Button("Clear due date") {
                                guard var t = selectedTask else { return }
                                t.dueAt = nil; selectedTask = t; db.saveTask(t); loadTasks()
                            }
                        }
                    }
                    Section("Notes") {
                        TextEditor(text: Binding(
                            get: { selectedTask?.notes ?? "" },
                            set: { v in
                                guard var t = selectedTask else { return }
                                t.notes = v
                                selectedTask = t
                                db.saveTask(t)
                                loadTasks()
                                selectedTask = tasks.first(where: { $0.id == t.id })
                            }
                        ))
                        .font(.body)
                        .frame(minHeight: 120)
                    }
                    if let src = task.sourceTitle, !src.isEmpty {
                        Section("Source") {
                            Text(src)
                            if !task.evidence.isEmpty {
                                Text("“\(task.evidence)”")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let mid = task.sourceMeetingId,
                               let m = meetings.first(where: { $0.id == mid }) {
                                Button(task.evidence.isEmpty ? "Open source note" : "Review source evidence") {
                                    libraryFilter = .all
                                    selectedMeeting = m
                                    selectedTask = nil
                                    transcriptEvidenceQuery = task.evidence.isEmpty ? nil : task.evidence
                                    selectedTab = m.transcript.isEmpty ? "notes" : "transcript"
                                }
                            }
                        }
                    }
                    Section("Status") {
                        Text(task.isDone ? "Done" : "Open")
                        if let c = task.completedAt {
                            Text("Completed \(Date(timeIntervalSince1970: c).formatted())")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !filteredTasks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredTasks) { task in
                            HStack(spacing: 14) {
                                Button { toggleTaskDone(task) } label: {
                                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(task.isDone ? .green : .secondary)
                                }.buttonStyle(.plain).help(task.isDone ? "Mark open" : "Mark done")
                                Button {
                                    selectedTask = task; selectedMeeting = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(task.title).strikethrough(task.isDone).foregroundStyle(.primary)
                                        Text([task.sourceTitle, task.assignee.isEmpty ? nil : task.assignee, task.priority == "none" ? nil : task.priority.capitalized + " priority", task.dueAt.map { "Due " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(task.isOverdue ? .red : .secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(20)
                }
            } else {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "checklist")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.purple)
                }
                VStack(spacing: 6) {
                    Text(tasks.isEmpty ? "No tasks yet" : noTasksTitle)
                        .font(.title2.weight(.semibold))
                    Text(noTasksMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                HStack(spacing: 12) {
                    if !tasks.isEmpty, taskListFilter == "open", tasks.contains(where: \.isDone) {
                        Button("Show completed") {
                            taskListFilter = "done"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Button {
                        newTaskTitle = ""
                        newTaskNotes = ""
                        newTaskLinkToOpenItem = selectedMeeting != nil
                        showingNewTaskSheet = true
                    } label: {
                        Label("New task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.large)

                    if selectedMeeting != nil {
                        Button {
                            extractTasksFromCurrent()
                        } label: {
                            Label(
                                "Extract from open \(selectedMeeting?.isNoteType == true ? "note" : "meeting")",
                                systemImage: "wand.and.stars"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func updateSelectedTask(_ edit: (inout QuernTask) -> Void) {
        guard var task = selectedTask else { return }; edit(&task); db.saveTask(task); loadTasks(); selectedTask = task
    }

    func taskBinding(_ key: WritableKeyPath<QuernTask, String>, fallback: String) -> Binding<String> {
        Binding(get: { selectedTask?[keyPath: key] ?? fallback }, set: { value in updateSelectedTask { $0[keyPath: key] = value } })
    }

    var taskFilterTitle: String {
        switch taskListFilter {
        case "done": return "Completed"
        case "all": return "All"
        default: return "Open"
        }
    }

    var noTasksTitle: String {
        switch taskListFilter {
        case "done": return "No completed tasks"
        case "all": return "No matching tasks"
        default: return "No open tasks"
        }
    }

    var noTasksMessage: String {
        if tasks.isEmpty {
            return "Extract action items after Enhance, or create one by hand."
        }
        switch taskListFilter {
        case "done": return "Completed tasks will appear here."
        case "all": return "Try a different task view."
        default: return "Your completed tasks are still available in the Completed view."
        }
    }

    var taskFilterMenu: some View {
        Menu {
            Button("Open") { taskListFilter = "open" }
            Button("Completed") { taskListFilter = "done" }
            Button("All tasks") { taskListFilter = "all" }
        } label: {
            Label(taskFilterTitle, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .help("Choose open, completed, or all tasks")
    }

    var taskPageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selectedTask != nil { Button("Back to tasks") { selectedTask = nil } }
                Text("Tasks").font(.title2.weight(.semibold))
                Spacer()
                Menu {
                    Button("Update Obsidian task list") {
                        do {
                            let file = try ObsidianExporter.exportTasks(tasks)
                            statusMessage = "Tasks saved to \(file.lastPathComponent)"
                        } catch { statusMessage = error.localizedDescription }
                    }
                    .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                    Button("Update Notion task list") {
                        isExportingTasks = true
                        statusMessage = "Syncing tasks to Notion…"
                        Task {
                            do {
                                try await NotionExporter.exportTasks(tasks)
                                statusMessage = "Tasks synced to Notion"
                            } catch { statusMessage = error.localizedDescription }
                            isExportingTasks = false
                        }
                    }
                    .disabled(!IntegrationsConfigManager.shared.config.notion.isConfigured || IntegrationsConfigManager.shared.config.notion.taskPageID.isEmpty)
                } label: { Label("Export tasks", systemImage: "square.and.arrow.up") }
                .disabled(isExportingTasks)
                Button {
                    newTaskTitle = ""
                    newTaskNotes = ""
                    newTaskLinkToOpenItem = selectedMeeting != nil
                    showingNewTaskSheet = true
                } label: { Label("New task", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(.purple)
            }
            HStack {
                Picker("Show tasks", selection: $taskListFilter) {
                    Text("Open").tag("open")
                    Text("Completed").tag("done")
                    Text("All").tag("all")
                }.pickerStyle(.segmented).frame(maxWidth: 290)
                Spacer()
                Picker("Sort", selection: $taskSort) {
                    Text("Due date").tag("due")
                    Text("Priority").tag("priority")
                    Text("Recently completed").tag("completed")
                    Text("Newest").tag("newest")
                }.frame(maxWidth: 190)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
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

}
