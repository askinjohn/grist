import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Computed Data

    var isSearching: Bool {
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
            case .all, .askEverything, .tasks:
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

    func handleSearchQueryChange(_ query: String) {
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
    func revealSearchMatch(in m: Meeting) {
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

    func exportFolder(_ name: String, options: ExportOptions = .default) {
        let items = meetings.filter { ($0.groupName ?? "") == name }
        guard !items.isEmpty else {
            statusMessage = "Folder is empty"
            return
        }
        if let dir = NoteExporter.saveFolderPanel(meetings: items, suggestedName: name, options: options) {
            statusMessage = "Exported \(items.count) files → \(dir.lastPathComponent)"
            NSWorkspace.shared.open(dir)
        }
    }

    /// Unfiled (or filter-scoped) items for the sidebar timeline. Folder contents live in the accordion.
    var groupedMeetings: [MeetingGroup] {
        if focusedFolder != nil {
            return timeGrouped(filteredMeetings, headerPrefix: nil)
        }
        // Prefer unfiled-only timeline; accordion owns folder files.
        switch libraryFilter {
        case .all, .unfiled:
            return timeGrouped(unfiledMeetingsForSidebar, headerPrefix: nil)
        case .meetings, .notes:
            // Meetings/Notes filter: unfiled of that kind only (filed items under accordion)
            return timeGrouped(unfiledMeetingsForSidebar, headerPrefix: nil)
        case .askEverything, .tasks:
            return []
        }
    }

    func timeGrouped(_ items: [Meeting], headerPrefix: String?) -> [MeetingGroup] {
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
                            RAGEngine.shared.indexMeetingNow(m)
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
                            RAGEngine.shared.indexMeetingNow(newMeeting)
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
            GristLog.log("[Enhance] byId abort: meeting \(id) not found")
            return
        }

        let usedTranscriptField = !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error")
        let transcriptSource: String = {
            if usedTranscriptField { return m.transcript }
            return m.manualNotes
        }()
        let notesSource: String = {
            if !usedTranscriptField { return "" }
            return m.manualNotes
        }()
        guard !transcriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            GristLog.log("[Enhance] byId abort: empty source id=\(id)")
            return
        }

        let model = await MainActor.run { selectedModel == "custom" ? customModelName : selectedModel }
        guard !model.isEmpty else {
            GristLog.log("[Enhance] byId abort: empty model id=\(id)")
            return
        }

        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = await MainActor.run {
            customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        }
        let applyTitle = m.isPlaceholderTitle
        let existingSummaryLen = m.summary.trimmingCharacters(in: .whitespacesAndNewlines).count

        GristLog.log("[Enhance] byId start id=\(id) title=\(m.title.prefix(60))")
        GristLog.log("[Enhance] byId model=\(model) template=\(templateName) re-enhance=\(existingSummaryLen > 0) existingSummaryChars=\(existingSummaryLen)")
        GristLog.log("[Enhance] byId feeds ORIGINAL content only (never existing summary)")
        GristLog.log("[Enhance] byId primaryField=\(usedTranscriptField ? "transcript" : "manualNotes") primaryChars=\(transcriptSource.count) notesChars=\(notesSource.count)")

        await MainActor.run {
            if selectedMeeting?.id == id {
                statusMessage = "Enhancing…"
            }
        }

        let t0 = Date()
        do {
            let result = try await ollama.enhance(
                transcript: transcriptSource,
                notes: notesSource,
                template: templateName,
                customPrompt: customPrompt,
                model: model
            )
            let elapsed = Date().timeIntervalSince(t0)
            await MainActor.run {
                m.summary = result.summary
                if applyTitle, let title = result.title, !title.isEmpty, m.isPlaceholderTitle {
                    m.title = title
                }
                db.saveMeeting(m)
                RAGEngine.shared.indexMeetingNow(m)
                if let idx = meetings.firstIndex(where: { $0.id == id }) {
                    meetings[idx] = m
                }
                if selectedMeeting?.id == id {
                    selectedMeeting = m
                    statusMessage = "Done"
                }
                GristLog.log("[Enhance] byId done id=\(id) \(String(format: "%.1f", elapsed))s newSummaryChars=\(result.summary.count) title=\(result.title ?? "(none)")")
            }
        } catch {
            let elapsed = Date().timeIntervalSince(t0)
            GristLog.log("[Enhance] byId FAILED id=\(id) after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
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
                    RAGEngine.shared.indexMeetingNow(m)
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
        loadTasks()
        if selectedMeeting == nil { selectedMeeting = meetings.first }
    }

    func loadTasks() {
        tasks = db.fetchTasks(includeDone: true)
        if let id = selectedTask?.id {
            selectedTask = tasks.first(where: { $0.id == id })
        }
    }

    func toggleTaskDone(_ task: GristTask) {
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
        let task = GristTask.manual(
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
                        let task = GristTask.fromExtract(title: t, notes: item.notes, source: meeting)
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

                let transcriptToRAG = transcript
                if let m = selectedMeeting {
                    RAGEngine.shared.indexMeetingNow(m)
                }

                if autoEnhance {
                    runEnhance()
                } else if !(transcriptToRAG.hasPrefix("[Error")) {
                    // Still name the item even if summary is skipped
                    generateAutoTitle(force: false)
                }
            }
        }
    }

}
