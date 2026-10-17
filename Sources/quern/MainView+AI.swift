import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - AI

    func runEnhance() {
        guard !isEnhancing else { return }
        guard let m = selectedMeeting else {
            QuernLog.log("[Enhance] abort: no selected meeting")
            return
        }

        // Prefer original transcript / captions; for notes fall back to written body.
        // Existing AI summary is NEVER fed back in (re-Enhance rewrites from source content).
        let usedTranscriptField = !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error")
        let transcriptSource: String = {
            if usedTranscriptField { return m.transcript }
            return m.manualNotes
        }()
        let notesSource: String = {
            // If we're enhancing from note body, don't double-send as both fields
            if !usedTranscriptField { return "" }
            return m.manualNotes
        }()

        let existingSummaryLen = m.summary.trimmingCharacters(in: .whitespacesAndNewlines).count
        let modelName = selectedModel == "custom" ? customModelName : selectedModel
        QuernLog.log("[Enhance] ========== RUN ==========")
        QuernLog.log("[Enhance] start id=\(m.id)")
        QuernLog.log("[Enhance] model=\(modelName) rolePicker=\(modelPickerRole.rawValue) configEnhance=\(AIConfigManager.shared.modelName(for: .enhance))")
        QuernLog.log("[Enhance] feeds ORIGINAL content only — never existing AI summary")
        QuernLog.log("[Enhance] primaryField=\(usedTranscriptField ? "transcript" : "manualNotes-as-primary")")
        QuernLog.log("[Enhance] raw sizes: transcript=\(m.transcript.count) notes=\(m.manualNotes.count) summary=\(existingSummaryLen) (summary NOT sent)")
        QuernLog.log("[Enhance] willSend: primaryChars=\(transcriptSource.count) notesChars=\(notesSource.count) re-enhance=\(existingSummaryLen > 0)")
        if transcriptSource.count > 50_000 {
            QuernLog.log("[Enhance] WARNING long source (\(transcriptSource.count) chars) — OllamaClient will truncate/de-dupe for context")
        }
        guard !transcriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = m.isNoteType ? "Write something first" : "No transcript yet"
            QuernLog.log("[Enhance] abort: empty primary source")
            return
        }
        if m.transcript.hasPrefix("[Error") && m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Transcription failed — fix capture/Whisper, then re-record"
            QuernLog.log("[Enhance] abort: transcript error and empty notes")
            return
        }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else {
            statusMessage = "Enter model name"
            QuernLog.log("[Enhance] abort: empty model name")
            return
        }

        isEnhancing = true
        statusMessage = transcriptSource.count > 12_000
            ? "Enhancing long note (chunked)…"
            : "Enhancing…"
        // Notes: use a readable summary style even if template is the type marker "Note"
        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        let applyTitle = m.isPlaceholderTitle
        let meetingId = m.id
        QuernLog.log("[Enhance] calling Ollama template=\(templateName) customPrompt=\(customPrompt != nil) applyTitle=\(applyTitle)")

        // Free Ollama from RAG embeds while Enhance runs (large Attach files reindex heavily).
        RAGEngine.shared.pauseIndexingForEnhance()

        Task {
            let t0 = Date()
            defer {
                Task { @MainActor in
                    isEnhancing = false
                    RAGEngine.shared.resumeIndexingAfterEnhance()
                }
            }
            do {
                // Single model call (or map-reduce for long Attach / notes): TITLE + markdown
                let result = try await ollama.enhance(
                    transcript: transcriptSource,
                    notes: notesSource,
                    template: templateName,
                    customPrompt: customPrompt,
                    model: model,
                    onProgress: { msg in
                        Task { @MainActor in
                            statusMessage = msg
                        }
                    }
                )
                let elapsed = Date().timeIntervalSince(t0)
                await MainActor.run {
                    guard let updated = db.modifyMeeting(id: meetingId, { current in
                        current.summary = result.summary
                        if applyTitle, let title = result.title, !title.isEmpty, current.isPlaceholderTitle {
                            current.title = title
                        }
                    }) else {
                        statusMessage = "Could not save summary; item may have been deleted"
                        return
                    }
                    if selectedMeeting?.id == meetingId { selectedMeeting = updated }
                    if let index = meetings.firstIndex(where: { $0.id == meetingId }) { meetings[index] = updated }
                    RAGEngine.shared.indexMeetingNow(updated)
                    if autoExtractTasks {
                        extractTasks(from: updated)
                    }
                    // Optional: push results into user-configured destinations after Enhance.
                    if IntegrationsConfigManager.shared.config.obsidian.isConfigured,
                       IntegrationsConfigManager.shared.config.obsidian.autoExportAfterEnhance {
                        do {
                            let url = try ObsidianExporter.exportMeeting(updated)
                            statusMessage = "Done · Obsidian \(url.lastPathComponent)"
                        } catch {
                            statusMessage = "Done · Obsidian failed: \(error.localizedDescription)"
                        }
                    } else {
                        statusMessage = "Done"
                    }
                    if IntegrationsConfigManager.shared.config.notion.isConfigured,
                       IntegrationsConfigManager.shared.config.notion.autoExportAfterEnhance {
                        Task {
                            do {
                                try await NotionExporter.exportMeeting(updated)
                                await MainActor.run {
                                    if statusMessage == "Done" { statusMessage = "Done · Notion" }
                                }
                            } catch {
                                await MainActor.run {
                                    statusMessage = "Done · Notion failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                    if selectedMeeting?.id == meetingId { selectedTab = "summary" }
                    QuernLog.log("[Enhance] done id=\(meetingId) \(String(format: "%.1f", elapsed))s model=\(model)")
                    QuernLog.log("[Enhance] summaryChars=\(result.summary.count)")
                }
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                QuernLog.log("[Enhance] FAILED after \(String(format: "%.1f", elapsed))s model=\(model): \(error.localizedDescription)")
                await MainActor.run {
                    let msg = error.localizedDescription
                    if msg.localizedCaseInsensitiveContains("timed out") {
                        statusMessage = "Enhance timed out — large note; try again (chunked) or free Ollama"
                    } else {
                        statusMessage = "Error: \(msg)"
                    }
                }
            }
        }
    }

    /// Items missing a real title and/or a folder, with enough content to organize.
    var itemsNeedingOrganize: [Meeting] {
        meetings.filter { m in
            let unfiled = (m.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let untitled = m.isPlaceholderTitle
            guard unfiled || untitled else { return false }
            let content = organizeContent(for: m)
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !content.hasPrefix("[Error")
        }
    }

    func organizeContent(for m: Meeting) -> String {
        if !m.transcript.isEmpty && !m.transcript.hasPrefix("[Error") { return m.transcript }
        if !m.manualNotes.isEmpty { return m.manualNotes }
        return m.summary
    }

    /// Single-button: fix missing titles + folders, then show a report popup.
    func runAutoOrganize() {
        let targets = itemsNeedingOrganize
        guard !targets.isEmpty else {
            organizeReportTitle = "Auto-organize"
            organizeReportLines = ["Nothing to do — every item already has a name and folder (or no content yet)."]
            showingOrganizeReport = true
            return
        }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else {
            statusMessage = "Pick an AI model first"
            return
        }

        isOrganizing = true
        statusMessage = "Organizing \(targets.count)…"
        let folderSnapshot = folders

        Task {
            var lines: [String] = []
            var success = 0
            var failed = 0

            for m in targets {
                let needsTitle = m.isPlaceholderTitle
                let needsFolder = (m.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                let content = organizeContent(for: m)
                let oldTitle = m.title

                do {
                    let result = try await ollama.organizeMetadata(
                        content: content,
                        kind: m.kindLabel.lowercased(),
                        existingFolders: folderSnapshot,
                        needsTitle: needsTitle,
                        needsFolder: needsFolder,
                        model: model
                    )

                    var parts: [String] = []
                    guard let updated = db.modifyMeeting(id: m.id, { current in
                        if needsTitle, current.title == m.title, let t = result.title, !t.isEmpty {
                            current.title = t
                            parts.append("titled “\(t)”")
                        }
                        if needsFolder, current.groupName == m.groupName, let f = result.folder, !f.isEmpty {
                            current.groupName = f
                            parts.append("filed in “\(f)”")
                        }
                    }) else {
                        failed += 1
                        lines.append("• \(oldTitle) — could not save; item may have been deleted")
                        continue
                    }
                    if let folder = updated.groupName { db.saveFolder(folder) }
                    if selectedMeeting?.id == updated.id { selectedMeeting = updated }
                    if parts.isEmpty {
                        lines.append("• \(oldTitle) — no change")
                    } else {
                        RAGEngine.shared.indexMeetingNow(updated)
                        success += 1
                        let label = needsTitle ? oldTitle : updated.title
                        lines.append("• \(label) → " + parts.joined(separator: ", "))
                    }
                } catch {
                    failed += 1
                    lines.append("• \(oldTitle) — failed: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                loadMeetings()
                isOrganizing = false
                statusMessage = "Organized \(success)"
                organizeReportTitle = failed == 0
                    ? "Organized \(success) item\(success == 1 ? "" : "s")"
                    : "Organized \(success), \(failed) failed"
                organizeReportLines = lines
                showingOrganizeReport = true
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
                    if !title.isEmpty, let updated = db.modifyMeeting(id: m.id, { current in
                        if current.title == m.title { current.title = title }
                    }) {
                        if selectedMeeting?.id == m.id { selectedMeeting = updated }
                        if let index = meetings.firstIndex(where: { $0.id == m.id }) { meetings[index] = updated }
                        RAGEngine.shared.indexMeetingNow(updated)
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
