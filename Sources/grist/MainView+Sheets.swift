import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Export options sheet

    var exportOptionsSheet: some View {
        let isFolder = exportTargetFolder != nil
        let folderCount = exportTargetFolder.map { name in meetings.filter { ($0.groupName ?? "") == name }.count } ?? 0
        let availability = exportTargetMeeting.map { exportOptions.availability(for: $0) }

        let subtitle: String = {
            if let folder = exportTargetFolder {
                return "Folder “\(folder)” · \(folderCount) item\(folderCount == 1 ? "" : "s")"
            }
            if let m = exportTargetMeeting {
                return m.title.isEmpty ? "Untitled" : m.title
            }
            return "Choose sections for the Markdown file"
        }()

        return VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "Export Markdown",
                subtitle: subtitle,
                systemImage: "square.and.arrow.up",
                tint: .blue,
                onClose: { showingExportOptionsSheet = false }
            )
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Choose what goes into the file. Empty sections are skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    exportToggle("Metadata (type, date, folder)", isOn: $exportOptions.includeMetadata, enabled: true)
                    Divider().padding(.leading, 16)
                    exportToggle(
                        "AI Summary",
                        isOn: $exportOptions.includeSummary,
                        enabled: isFolder || (availability?.hasSummary ?? true),
                        emptyHint: !(availability?.hasSummary ?? true) && !isFolder
                    )
                    Divider().padding(.leading, 16)
                    exportToggle(
                        "Notes / article body",
                        isOn: $exportOptions.includeNotes,
                        enabled: isFolder || (availability?.hasNotes ?? true),
                        emptyHint: !(availability?.hasNotes ?? true) && !isFolder
                    )
                    Divider().padding(.leading, 16)
                    exportToggle(
                        "Transcript / captions",
                        isOn: $exportOptions.includeTranscript,
                        enabled: isFolder || (availability?.hasTranscript ?? true),
                        emptyHint: !(availability?.hasTranscript ?? true) && !isFolder
                    )
                    Divider().padding(.leading, 16)
                    exportToggle(
                        "Source links",
                        isOn: $exportOptions.includeSources,
                        enabled: isFolder || (availability?.hasSources ?? true),
                        emptyHint: !(availability?.hasSources ?? true) && !isFolder
                    )
                }
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button("Summary only") { exportOptions = .summaryOnly }
                        .buttonStyle(.bordered)
                    Button("Full item") { exportOptions = .full }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Spacer(minLength: 8)

            GristSheetFooter {
                Button("Cancel") { showingExportOptionsSheet = false }
            } trailing: {
                if !isFolder {
                    Button {
                        performExport(copyOnly: true)
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!exportOptions.hasContentSelection)
                }
                Button {
                    performExport(copyOnly: false)
                } label: {
                    Label(isFolder ? "Export folder…" : "Save…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!exportOptions.hasContentSelection)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 480, height: 460)
    }

    func exportToggle(_ title: String, isOn: Binding<Bool>, enabled: Bool, emptyHint: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(title)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if emptyHint {
                    Text("(empty)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    func openExportSheet(meeting: Meeting) {
        exportTargetMeeting = meeting
        exportTargetFolder = nil
        // Sensible default: summary on if present, else notes
        var opts = ExportOptions.default
        let a = opts.availability(for: meeting)
        if a.hasSummary && !a.hasNotes && !a.hasTranscript {
            opts = .summaryOnly
        }
        exportOptions = opts
        showingExportOptionsSheet = true
    }

    func openExportSheet(folder: String) {
        exportTargetMeeting = nil
        exportTargetFolder = folder
        exportOptions = .default
        showingExportOptionsSheet = true
    }

    func performExport(copyOnly: Bool) {
        let opts = exportOptions
        if let folder = exportTargetFolder {
            showingExportOptionsSheet = false
            exportFolder(folder, options: opts)
            return
        }
        guard let m = exportTargetMeeting else {
            showingExportOptionsSheet = false
            return
        }
        let md = NoteExporter.markdown(for: m, options: opts)
        if copyOnly {
            copyToPasteboard(md)
            statusMessage = "Copied Markdown"
            showingExportOptionsSheet = false
            return
        }
        showingExportOptionsSheet = false
        if let url = NoteExporter.saveMarkdownPanel(defaultName: NoteExporter.safeFilename(for: m), contents: md) {
            statusMessage = "Exported \(url.lastPathComponent)"
        }
    }

    // MARK: - Folder summarize sheet

    var folderSummarizeSheet: some View {
        let count = meetings.filter { ($0.groupName ?? "") == folderSummarizeName }.count
        return VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "Summarize folder",
                subtitle: "“\(folderSummarizeName)” · \(count) item\(count == 1 ? "" : "s")",
                systemImage: "sparkles.rectangle.stack",
                tint: .purple,
                onClose: { showingFolderSummarizeSheet = false },
                closeDisabled: isFolderSummarizing
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Collect blogs, videos, meetings, and notes into one summary. Pick a style or write your own specs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    GristLabeledField(label: "Style") {
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
                                            .foregroundStyle(folderSummarizePreset == preset ? Color.purple : .secondary)
                                        Text(preset.title)
                                            .font(.callout.weight(folderSummarizePreset == preset ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding(12)
                                    .background(folderSummarizePreset == preset ? Color.purple.opacity(0.12) : Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(folderSummarizePreset == preset ? Color.purple.opacity(0.25) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    GristLabeledField(label: "Instructions") {
                        TextEditor(text: $folderSummarizeCustomSpecs)
                            .font(.body)
                            .frame(minHeight: 120, maxHeight: 180)
                            .gristFieldStyle(minHeight: 120)
                    }

                    HStack {
                        Text("Model")
                            .font(.callout.weight(.medium))
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
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            GristSheetFooter {
                Button("Cancel") { showingFolderSummarizeSheet = false }
                    .disabled(isFolderSummarizing)
            } trailing: {
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
                .tint(.purple)
                .disabled(isFolderSummarizing || count == 0
                          || folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520, height: 580)
        .onAppear {
            if folderSummarizeCustomSpecs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                folderSummarizeCustomSpecs = folderSummarizePreset.defaultSpecs
            }
        }
    }

    func openFolderSummarize(name: String) {
        folderSummarizeName = name
        folderSummarizePreset = .actionItems
        folderSummarizeCustomSpecs = FolderSummarizePreset.actionItems.defaultSpecs
        showingFolderSummarizeSheet = true
    }

    func runFolderSummarize() {
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
                    RAGEngine.shared.indexMeetingNow(note)
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
    var deleteFolderSheet: some View {
        let name = folderPendingDelete ?? ""
        let count = meetings.filter { ($0.groupName ?? "") == name }.count

        VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "Delete folder",
                subtitle: name.isEmpty ? nil : "“\(name)”",
                systemImage: "folder.badge.minus",
                tint: .red,
                onClose: {
                    showingDeleteFolderConfirm = false
                    folderPendingDelete = nil
                }
            )
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                if count == 0 {
                    GristInfoCard(tint: .orange) {
                        Text("This folder is empty. Deleting it only removes the folder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                            )
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.red.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Spacer(minLength: 8)
            GristSheetFooter {
                Button("Cancel") {
                    showingDeleteFolderConfirm = false
                    folderPendingDelete = nil
                }
                .keyboardShortcut(.cancelAction)
            } trailing: {
                if count == 0 {
                    Button("Delete folder", role: .destructive) {
                        confirmDeleteFolder(contents: .moveToUnfiled)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .frame(width: 460, height: count == 0 ? 280 : 400)
    }

    var organizeReportSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: organizeReportTitle,
                subtitle: "Untitled items got names; unfiled items got folders when the AI found a fit.",
                systemImage: "sparkles.rectangle.stack",
                tint: .purple,
                onClose: { showingOrganizeReport = false }
            )
            Divider()

            if organizeReportLines.isEmpty {
                GristEmptyState(
                    systemImage: "checkmark.circle",
                    title: "All set",
                    message: "Nothing needed organizing.",
                    tint: .green,
                    badgeSize: 56
                )
                .frame(maxWidth: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(organizeReportLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(line)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
            }

            GristSheetFooter {
                EmptyView()
            } trailing: {
                Button("Done") { showingOrganizeReport = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 500, height: 440)
    }

    var sidebarFooter: some View {
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

    func libraryFilterRow(_ filter: LibraryFilter) -> some View {
        let selected = focusedFolder == nil && libraryFilter == filter
        let count = count(for: filter)
        return Button {
            focusedFolder = nil
            libraryFilter = filter
            if filter == .askEverything || filter == .tasks {
                selectedMeeting = nil
            }
            if filter == .tasks {
                loadTasks()
            }
            if filter == .askEverything {
                syncModelPickerFromConfig(for: .askEverything)
            } else if filter != .tasks {
                syncModelPickerFromConfig(for: currentModelPickerRole())
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? (filter == .askEverything || filter == .tasks ? .purple : Color.accentColor) : .secondary)
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
        .listRowBackground(selected ? ((filter == .askEverything || filter == .tasks) ? Color.purple.opacity(0.12) : Color.accentColor.opacity(0.12)) : Color.clear)
    }

    @ViewBuilder
    var globalChatDetail: some View {
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
                .frame(width: 160)
                .help("Synced with Settings → AI Models → Ask everything")
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
        .onAppear {
            syncModelPickerFromConfig(for: .askEverything)
        }
    }

}
