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

            List(selection: $selectedMeeting) {
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
                if !isSearching && libraryFilter != .tasks && libraryFilter != .askEverything {
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

                // ITEMS — Tasks list, search results, or unfiled (Today / Yesterday / …)
                if libraryFilter == .tasks && focusedFolder == nil && !isSearching {
                    Section {
                        if filteredTasks.isEmpty {
                            Text("No tasks yet — extract from a note or create one")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(filteredTasks) { task in
                                TaskSidebarRow(task: task, isSelected: selectedTask?.id == task.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedTask = task
                                        selectedMeeting = nil
                                    }
                                    .contextMenu {
                                        Button {
                                            toggleTaskDone(task)
                                        } label: {
                                            Label(task.isDone ? "Mark open" : "Mark done", systemImage: task.isDone ? "circle" : "checkmark.circle")
                                        }
                                        Button(role: .destructive) {
                                            db.deleteTask(id: task.id)
                                            loadTasks()
                                            if selectedTask?.id == task.id { selectedTask = nil }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Tasks")
                            Spacer()
                            Picker("", selection: $taskListFilter) {
                                Text("Open").tag("open")
                                Text("Done").tag("done")
                                Text("All").tag("all")
                            }
                            .labelsHidden()
                            .frame(width: 72)
                            .controlSize(.small)
                            Button {
                                newTaskTitle = ""
                                newTaskNotes = ""
                                newTaskLinkToOpenItem = selectedMeeting != nil
                                showingNewTaskSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .help("New task")
                        }
                    }
                } else if isSearching {
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
                } else if libraryFilter != .askEverything && libraryFilter != .tasks {
                    // Outside folders: only unfiled items, grouped by Today / Yesterday / …
                    // (Unless a folder is “focused” via context menu — then show only that folder’s items.)
                    if let folder = focusedFolder {
                        Section {
                            let items = meetingsInFolder(folder)
                            if items.isEmpty {
                                Text("Empty folder")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(items) { meeting in
                                    meetingSidebarRow(meeting, inFolder: folder)
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(folder)
                                Spacer()
                                Button("Show all") {
                                    focusedFolder = nil
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        let unfiledGroups = timeGrouped(unfiledMeetingsForSidebar, headerPrefix: nil)
                        if unfiledGroups.isEmpty {
                            Section {
                                Text(libraryFilter == .unfiled
                                     ? "No unfiled items"
                                     : "No unfiled items — open a folder above")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } header: {
                                Text(libraryFilter == .unfiled ? "Unfiled" : "Unfiled")
                            }
                        } else {
                            ForEach(unfiledGroups) { group in
                                Section(group.name) {
                                    ForEach(group.meetings) { meeting in
                                        meetingSidebarRow(meeting, inFolder: nil)
                                    }
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    // Drop onto Today/Yesterday → unfiled
                                    moveMeetings(items, toFolder: nil)
                                }
                            }
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
        .sheet(isPresented: $showingExportOptionsSheet) {
            exportOptionsSheet
        }
        .sheet(isPresented: $showingNewTaskSheet) {
            newTaskSheet
        }
    }

    // MARK: - Tasks UI

    var canCreateNewTask: Bool {
        !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var newTaskSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "New task",
                subtitle: "Track something to do — optionally link it to the open note.",
                systemImage: "checklist",
                tint: .purple,
                onClose: { showingNewTaskSheet = false }
            )
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                GristLabeledField(label: "Task") {
                    TextField("What needs doing?", text: $newTaskTitle)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .gristFieldStyle()
                        .focused($newTaskTitleFocused)
                        .onSubmit {
                            if canCreateNewTask { createManualTask() }
                        }
                }

                GristLabeledField(label: "Notes") {
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

            GristSheetFooter {
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
                            if let mid = task.sourceMeetingId,
                               let m = meetings.first(where: { $0.id == mid }) {
                                Button("Open source note") {
                                    libraryFilter = .all
                                    selectedMeeting = m
                                    selectedTask = nil
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
                    Text("No tasks yet")
                        .font(.title2.weight(.semibold))
                    Text("Extract action items after Enhance, or create one by hand.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                HStack(spacing: 12) {
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
