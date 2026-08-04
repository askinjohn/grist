import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Model picker ↔ ai-config.json

    /// Role the current UI context should edit (Ask everything / Chat tab / Enhance).
    func currentModelPickerRole() -> AIRole {
        if libraryFilter == .askEverything, focusedFolder == nil {
            return .askEverything
        }
        if selectedTab == "chat" {
            return .chat
        }
        return .enhance
    }

    /// Make sure every role model from ai-config.json appears as a picker option.
    func ensureConfigModelsInPicker() {
        for role in AIRole.allCases {
            let name = AIConfigManager.shared.modelName(for: role)
            guard !name.isEmpty else { continue }
            if !presetModels.contains(name) {
                // Prefer front of list so the selection is visible before Ollama responds.
                presetModels.insert(name, at: 0)
            }
        }
    }

    /// Replace picker options with Ollama's list without dropping the current selection mid-update.
    func applyOllamaModelsToPicker(_ models: [String]) {
        if models.isEmpty {
            if presetModels.isEmpty || presetModels == ["Ollama not running"] {
                presetModels = ["No models found"]
            }
            ensureConfigModelsInPicker()
            return
        }

        var next = models
        // Always keep configured role models available (even if not currently pulled).
        for role in AIRole.allCases {
            let name = AIConfigManager.shared.modelName(for: role)
            if !name.isEmpty, !next.contains(name) {
                next.insert(name, at: 0)
            }
        }
        // Keep whatever is currently selected so the Picker doesn't snap to models[0].
        let keep = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keep.isEmpty,
           keep != "custom",
           keep != "No models found",
           keep != "Ollama not running",
           !next.contains(keep) {
            next.insert(keep, at: 0)
        }
        presetModels = next

        // Create-sheet default: only fall back if its model is missing from Ollama.
        if !models.contains(newModel) {
            newModel = AIConfigManager.shared.modelName(for: .enhance)
            if !models.contains(newModel), let first = models.first {
                newModel = first
            }
        }
    }

    /// Dropdown shows the model stored for this role in ai-config.json.
    func syncModelPickerFromConfig(for role: AIRole) {
        modelPickerRole = role
        let name = AIConfigManager.shared.modelName(for: role)
        guard !name.isEmpty else { return }
        if !presetModels.contains(name) {
            presetModels.insert(name, at: 0)
        }
        guard selectedModel != name else { return }
        isApplyingModelFromConfig = true
        selectedModel = name
        // onChange runs in the same turn; clear after the state write settles.
        DispatchQueue.main.async {
            isApplyingModelFromConfig = false
        }
    }

    /// Dropdown change writes back to the active role (keeps backend, updates model name).
    func persistModelPickerToConfig(model: String) {
        guard !isApplyingModelFromConfig else { return }
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, m != "custom", m != "No models found", m != "Ollama not running" else { return }
        let role = modelPickerRole
        let backend = AIConfigManager.shared.config.roles[role.rawValue]?.backend ?? "local"
        let current = AIConfigManager.shared.modelName(for: role)
        guard current != m else { return }
        AIConfigManager.shared.setRole(role, backend: backend, model: m)
        print("[AIConfig] model picker → \(role.rawValue) = \(m)")
    }

    /// Meetings that belong in a folder, respecting Meetings/Notes library filter.
    func meetingsInFolder(_ name: String) -> [Meeting] {
        meetings
            .filter { ($0.groupName ?? "") == name }
            .filter { m in
                switch libraryFilter {
                case .meetings: return !m.isNoteType
                case .notes: return m.isNoteType
                default: return true
                }
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Items with no folder — shown under Today / Yesterday outside the accordion.
    var unfiledMeetingsForSidebar: [Meeting] {
        meetings
            .filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { m in
                switch libraryFilter {
                case .meetings: return !m.isNoteType
                case .notes: return m.isNoteType
                case .unfiled, .all: return true
                case .askEverything, .tasks: return false
                }
            }
    }

    func isFolderExpanded(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(name) },
            set: { open in
                if open {
                    expandedFolders.insert(name)
                    // Expanding a folder clears “focus only this folder” mode
                    if focusedFolder != nil { focusedFolder = nil }
                } else {
                    expandedFolders.remove(name)
                }
            }
        )
    }

    /// Accordion folder: chevron + click expands to list files inside.
    @ViewBuilder
    func folderAccordion(_ name: String) -> some View {
        let items = meetingsInFolder(name)
        let expanded = isFolderExpanded(name)
        let isFocused = focusedFolder == name
        let isDropTarget = folderDropTarget == name

        DisclosureGroup(isExpanded: expanded) {
            if items.isEmpty {
                Text("Drop notes here, or right‑click a note → Move to folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .dropDestination(for: String.self) { dropped, _ in
                        acceptDrop(dropped, toFolder: name)
                    } isTargeted: { hovering in
                        folderDropTarget = hovering ? name : (folderDropTarget == name ? nil : folderDropTarget)
                    }
            } else {
                ForEach(items) { meeting in
                    meetingSidebarRow(meeting, inFolder: name)
                        .padding(.leading, 4)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedFolders.contains(name) ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFocused || isDropTarget || expandedFolders.contains(name) ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.callout.weight(isFocused || expandedFolders.contains(name) ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            // Drop on the folder *label* (works when collapsed)
            .dropDestination(for: String.self) { dropped, _ in
                acceptDrop(dropped, toFolder: name)
            } isTargeted: { hovering in
                folderDropTarget = hovering ? name : (folderDropTarget == name ? nil : folderDropTarget)
            }
        }
        .listRowBackground(
            isDropTarget
                ? Color.accentColor.opacity(0.22)
                : (isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .dropDestination(for: String.self) { dropped, _ in
            acceptDrop(dropped, toFolder: name)
        } isTargeted: { hovering in
            folderDropTarget = hovering ? name : (folderDropTarget == name ? nil : folderDropTarget)
        }
        .contextMenu {
            Button(expanded.wrappedValue ? "Collapse" : "Expand") {
                withAnimation { expanded.wrappedValue.toggle() }
            }
            Button("Show only this folder") {
                focusedFolder = name
                expandedFolders.insert(name)
            }
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
                openExportSheet(folder: name)
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

    /// Handle a sidebar drop of meeting id(s) into a folder (or unfiled if nil).
    @discardableResult
    func acceptDrop(_ ids: [String], toFolder folder: String?) -> Bool {
        let ok = moveMeetings(ids, toFolder: folder)
        if ok, let folder {
            expandedFolders.insert(folder)
            statusMessage = "Moved to “\(folder)”"
        } else if ok {
            statusMessage = "Moved to Unfiled"
        }
        return ok
    }

    @ViewBuilder
    func meetingSidebarRow(_ meeting: Meeting, inFolder: String?) -> some View {
        // List selection via `.tag` — avoid onTapGesture (it blocks drag-and-drop on macOS).
        SidebarRow(meeting: meeting, isSelected: selectedMeeting?.id == meeting.id)
            .tag(meeting)
            .contentShape(Rectangle())
            .draggable(meeting.id) {
                Label(
                    meeting.title.isEmpty ? "Item" : meeting.title,
                    systemImage: meeting.isNoteType ? "note.text" : "waveform"
                )
                .padding(8)
            }
            .contextMenu {
                // Reliable alternative when drag-and-drop is flaky in List
                Menu("Move to folder") {
                    Button("Unfiled") {
                        _ = acceptDrop([meeting.id], toFolder: nil)
                    }
                    if !folders.isEmpty {
                        Divider()
                        ForEach(folders.sorted(), id: \.self) { name in
                            Button(name) {
                                _ = acceptDrop([meeting.id], toFolder: name)
                            }
                            .disabled((meeting.groupName ?? "") == name)
                        }
                    }
                }
                if inFolder != nil {
                    Button("Remove from folder") {
                        _ = acceptDrop([meeting.id], toFolder: nil)
                    }
                }
                Button {
                    openExportSheet(meeting: meeting)
                } label: {
                    Label("Export Markdown…", systemImage: "square.and.arrow.up")
                }
                Button {
                    sendToObsidian(meeting: meeting)
                } label: {
                    Label("Send to Obsidian", systemImage: "book.closed")
                }
                .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                Button(role: .destructive) {
                    Database.shared.softDeleteMeeting(id: meeting.id)
                    NotificationCenter.default.post(name: .meetingDeleted, object: nil)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: - Obsidian

    @MainActor
    func sendToObsidian(meeting: Meeting) {
        do {
            let url = try ObsidianExporter.exportMeeting(meeting)
            statusMessage = "Obsidian: \(url.lastPathComponent)"
            GristLog.log("[Obsidian] send ok \(url.path)")
        } catch {
            statusMessage = "Obsidian: \(error.localizedDescription)"
            GristLog.log("[Obsidian] send failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func sendFolderToObsidian(_ folder: String) {
        let items = meetings.filter { ($0.groupName ?? "") == folder }
        guard !items.isEmpty else {
            statusMessage = "Folder is empty"
            return
        }
        var ok = 0
        var lastName = ""
        for m in items {
            do {
                let url = try ObsidianExporter.exportMeeting(m)
                ok += 1
                lastName = url.lastPathComponent
            } catch {
                statusMessage = "Obsidian: \(error.localizedDescription) (\(ok) saved)"
                return
            }
        }
        statusMessage = "Obsidian: \(ok) file(s) in “\(folder)”" + (lastName.isEmpty ? "" : " · last \(lastName)")
    }

    func confirmDeleteFolder(contents: Database.FolderDeleteContentsMode) {
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

    var importURLSheet: some View {
        let canAppend = selectedMeeting != nil
        let appendTargetTitle = selectedMeeting?.title ?? "current item"
        let n = Self.parseImportURLs(from: importUrlString).count

        return VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: importAppendToSelected && canAppend ? "Add to item" : "Import URL",
                subtitle: importAppendToSelected && canAppend
                    ? "Fetch page or YouTube captions and append to the open note or meeting."
                    : "Paste one or many URLs. Each link becomes its own note.",
                systemImage: importAppendToSelected && canAppend ? "plus.rectangle.on.rectangle" : "link",
                tint: .blue,
                onClose: { showingImportUrlAlert = false }
            )
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                if canAppend {
                    GristLabeledField(label: "Destination") {
                        VStack(alignment: .leading, spacing: 10) {
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
                }

                GristLabeledField(label: n > 1 ? "URLs (\(n))" : "URL(s)") {
                    TextEditor(text: $importUrlString)
                        .font(.body)
                        .frame(minHeight: 88, maxHeight: 140)
                        .gristFieldStyle(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if importUrlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("One per line (or space-separated)\nhttps://…\nhttps://youtube.com/…")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                let parsed = Self.parseImportURLs(from: importUrlString)
                let ytCount = parsed.filter { YouTubeImporter.isYouTubeURL($0) }.count
                if ytCount > 0 {
                    GristInfoCard(tint: YouTubeImporter.resolveYtDlpPath() == nil ? .orange : .red) {
                        HStack(spacing: 8) {
                            Image(systemName: YouTubeImporter.resolveYtDlpPath() == nil ? "exclamationmark.triangle.fill" : "play.rectangle.fill")
                                .foregroundStyle(YouTubeImporter.resolveYtDlpPath() == nil ? .orange : .red)
                            Text(YouTubeImporter.resolveYtDlpPath() == nil
                                 ? "\(ytCount) YouTube — install yt-dlp: brew install yt-dlp"
                                 : "\(ytCount) YouTube — will pull captions via yt-dlp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if parsed.count > 1 {
                    Text(importAppendToSelected && canAppend
                         ? "All \(parsed.count) pages will be appended to this item"
                         : "Will import \(parsed.count) pages as separate notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !(importAppendToSelected && canAppend) {
                    GristLabeledField(label: "Folder") {
                        VStack(alignment: .leading, spacing: 10) {
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
                                    .gristFieldStyle()
                                    .onChange(of: importNewFolderName) { _, val in
                                        importFolderSelection = val.trimmingCharacters(in: .whitespaces)
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Spacer(minLength: 8)

            GristSheetFooter {
                Button("Cancel") { showingImportUrlAlert = false }
            } trailing: {
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
        }
        .frame(width: 520, height: canAppend ? 500 : 440)
    }

    func openImportSheet(appendToCurrent: Bool = false) {
        importUrlString = ""
        importIsCreatingFolder = false
        importNewFolderName = ""
        // Always start Unfiled for new notes — don't inherit sidebar focus.
        importFolderSelection = ""
        importAppendToSelected = appendToCurrent && selectedMeeting != nil
        showingImportUrlAlert = true
    }

    func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: return meetings.count
        case .unfiled: return meetings.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        case .meetings: return meetings.filter { !$0.isNoteType }.count
        case .notes: return meetings.filter { $0.isNoteType }.count
        case .tasks: return tasks.filter { $0.isOpen }.count
        case .askEverything: return meetings.count
        }
    }

    var filteredTasks: [GristTask] {
        var list = tasks
        switch taskListFilter {
        case "open": list = list.filter { $0.isOpen }
        case "done": list = list.filter { $0.isDone }
        default: break
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.notes.localizedCaseInsensitiveContains(q)
                || ($0.sourceTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var shouldShowHealthBanner: Bool {
        // Re-show banner after 24h if still unhealthy
        Date().timeIntervalSince1970 - healthBannerDismissedAt > 86_400
    }

    func refreshHealthCheck(showSheetIfNeeded: Bool) {
        isCheckingHealth = true
        Task {
            let report = await GristHealth.check()
            await MainActor.run {
                healthReport = report
                isCheckingHealth = false
                let blocking = report.issues.contains(where: \.isBlocking)
                if showSheetIfNeeded, blocking, shouldShowHealthBanner {
                    showingHealthSheet = true
                }
            }
        }
    }

    @ViewBuilder
    func healthBanner(_ report: GristHealthReport) -> some View {
        let n = report.issues.count
        Button {
            showingHealthSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(n == 1
                     ? report.issues[0].title
                     : "\(n) setup items need attention")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("Fix")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Check Ollama, models, Whisper, yt-dlp")
    }

    var healthChecklistSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "Setup checklist",
                subtitle: "Grist works best with local Ollama models and optional capture tools.",
                systemImage: "stethoscope",
                tint: .orange,
                onClose: { showingHealthSheet = false }
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report = healthReport {
                        healthRow(
                            ok: report.ollamaReachable,
                            title: "Ollama",
                            detail: report.ollamaReachable
                                ? "Reachable · \(report.ollamaModels.count) model(s)"
                                : "Not reachable at configured URL"
                        )
                        healthRow(
                            ok: report.hasChatModel,
                            title: "Chat / enhance model",
                            detail: report.hasChatModel
                                ? "At least one non-embed model available"
                                : "Pull gemma2:2b or qwen2.5:7b"
                        )
                        healthRow(
                            ok: report.hasEmbedModel,
                            title: "Embeddings (RAG)",
                            detail: report.hasEmbedModel
                                ? "nomic-embed (or similar) present"
                                : "ollama pull nomic-embed-text"
                        )
                        healthRow(
                            ok: report.ytDlpInstalled,
                            title: "yt-dlp (YouTube)",
                            detail: report.ytDlpInstalled ? "Found" : "brew install yt-dlp"
                        )
                        healthRow(
                            ok: report.whisperAvailable,
                            title: "Whisper",
                            detail: report.whisperAvailable
                                ? "Setup folder or binary found"
                                : "Re-run ./setup.sh Whisper step"
                        )

                        if !report.issues.isEmpty {
                            Text("Next steps")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(report.issues) { issue in
                                GristInfoCard(tint: issue.isBlocking ? .orange : .blue) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: issue.systemImage)
                                            .foregroundStyle(issue.isBlocking ? .orange : .blue)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(issue.title)
                                                .font(.callout.weight(.semibold))
                                            Text(issue.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    } else if isCheckingHealth {
                        ProgressView("Checking…")
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(22)
            }

            GristSheetFooter {
                Button("Dismiss for today") {
                    healthBannerDismissedAt = Date().timeIntervalSince1970
                    showingHealthSheet = false
                }
            } trailing: {
                Button {
                    refreshHealthCheck(showSheetIfNeeded: false)
                } label: {
                    if isCheckingHealth {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isCheckingHealth)
            }
        }
        .frame(width: 480, height: 520)
    }

    func healthRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func dropFolder(fromSection name: String) -> String? {
        if name == "Today" || name == "Yesterday" || name == "Last 7 Days" || name == "Older" || name == "Items" {
            return nil
        }
        if name.hasPrefix("📁 ") { return String(name.dropFirst(2)) }
        return name
    }

    @discardableResult
    func moveMeetings(_ ids: [String], toFolder folder: String?) -> Bool {
        // Accept full drag payloads (sometimes includes whitespace / multiple)
        let cleaned = ids
            .flatMap { $0.split(whereSeparator: { $0.isNewline || $0 == "," }).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return false }

        var moved = 0
        for meetingId in cleaned {
            guard var m = db.getMeeting(id: meetingId) ?? meetings.first(where: { $0.id == meetingId }) else {
                continue
            }
            m.groupName = folder
            db.saveMeeting(m)
            moved += 1
            if selectedMeeting?.id == meetingId {
                selectedMeeting = m
            }
        }
        guard moved > 0 else { return false }
        if let folder { db.saveFolder(folder) }
        loadMeetings()
        // Keep selection in sync after reload
        if let id = selectedMeeting?.id {
            selectedMeeting = meetings.first(where: { $0.id == id }) ?? selectedMeeting
        }
        return true
    }

}
