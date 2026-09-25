import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Import

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

    /// Pick local .md / .txt / .pdf files and append their text into the open note/meeting body.
    @MainActor
    func attachFilesToCurrentNote() {
        guard selectedMeeting != nil else {
            statusMessage = "Select a note or meeting first"
            return
        }
        guard !isAttachingFiles else { return }

        let panel = NSOpenPanel()
        panel.title = "Attach files to note"
        panel.message = "Choose Markdown, text, or PDF files. Their text is appended so Enhance and Chat can read it."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = NoteFileImporter.allowedContentTypes
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        isAttachingFiles = true
        statusMessage = panel.urls.count == 1 ? "Attaching file…" : "Attaching \(panel.urls.count) files…"

        let urls = panel.urls
        let meetingId = selectedMeeting?.id

        // Extract off the main actor so large PDFs don’t freeze the UI.
        Task.detached(priority: .userInitiated) {
            var blocks: [(name: String, block: String)] = []
            var failures: [String] = []

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let body = try NoteFileImporter.extractText(from: url)
                    let block = NoteFileImporter.attachmentBlock(filename: url.lastPathComponent, body: body)
                    blocks.append((url.lastPathComponent, block))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    QuernLog.log("[Attach] failed \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                guard meetingId == nil || selectedMeeting?.id == meetingId else {
                    isAttachingFiles = false
                    statusMessage = "Attach cancelled (note changed)"
                    return
                }
                for item in blocks {
                    selectedMeeting?.manualNotes = (selectedMeeting?.manualNotes ?? "") + item.block
                }
                let attached = blocks.count
                if attached > 0 {
                    saveMeeting()
                    selectedTab = "notes"
                    if selectedMeeting?.isNoteType == true {
                        noteShowPreview = false
                    }
                    if let m = selectedMeeting {
                        RAGEngine.shared.scheduleIndex(meeting: m, delayNanoseconds: 8_000_000_000)
                    }
                }
                isAttachingFiles = false
                if attached > 0, failures.isEmpty {
                    statusMessage = attached == 1 ? "File attached" : "\(attached) files attached"
                } else if attached > 0 {
                    statusMessage = "Attached \(attached); \(failures.count) failed"
                    importErrorMessage = failures.joined(separator: "\n")
                    importErrorOpenURL = nil
                    showingImportErrorAlert = true
                } else {
                    statusMessage = "Attach failed"
                    importErrorMessage = failures.joined(separator: "\n")
                    importErrorOpenURL = nil
                    showingImportErrorAlert = true
                }
            }
        }
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
            QuernLog.log("[Enhance] byId abort: meeting \(id) not found")
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
            QuernLog.log("[Enhance] byId abort: empty source id=\(id)")
            return
        }

        let model = await MainActor.run { selectedModel == "custom" ? customModelName : selectedModel }
        guard !model.isEmpty else {
            QuernLog.log("[Enhance] byId abort: empty model id=\(id)")
            return
        }

        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = await MainActor.run {
            customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        }
        let applyTitle = m.isPlaceholderTitle
        let existingSummaryLen = m.summary.trimmingCharacters(in: .whitespacesAndNewlines).count

        QuernLog.log("[Enhance] byId start id=\(id) title=\(m.title.prefix(60))")
        QuernLog.log("[Enhance] byId model=\(model) template=\(templateName) re-enhance=\(existingSummaryLen > 0) existingSummaryChars=\(existingSummaryLen)")
        QuernLog.log("[Enhance] byId feeds ORIGINAL content only (never existing summary)")
        QuernLog.log("[Enhance] byId primaryField=\(usedTranscriptField ? "transcript" : "manualNotes") primaryChars=\(transcriptSource.count) notesChars=\(notesSource.count)")

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
                QuernLog.log("[Enhance] byId done id=\(id) \(String(format: "%.1f", elapsed))s newSummaryChars=\(result.summary.count) title=\(result.title ?? "(none)")")
            }
        } catch {
            let elapsed = Date().timeIntervalSince(t0)
            QuernLog.log("[Enhance] byId FAILED id=\(id) after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
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
}
