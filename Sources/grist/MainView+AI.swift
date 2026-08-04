import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - AI

    func runEnhance() {
        guard let m = selectedMeeting else {
            GristLog.log("[Enhance] abort: no selected meeting")
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
        GristLog.log("[Enhance] ========== RUN ==========")
        GristLog.log("[Enhance] start id=\(m.id) title=\(m.title.prefix(80))")
        GristLog.log("[Enhance] model=\(modelName) rolePicker=\(modelPickerRole.rawValue) configEnhance=\(AIConfigManager.shared.modelName(for: .enhance))")
        GristLog.log("[Enhance] feeds ORIGINAL content only — never existing AI summary")
        GristLog.log("[Enhance] primaryField=\(usedTranscriptField ? "transcript" : "manualNotes-as-primary")")
        GristLog.log("[Enhance] raw sizes: transcript=\(m.transcript.count) notes=\(m.manualNotes.count) summary=\(existingSummaryLen) (summary NOT sent)")
        GristLog.log("[Enhance] willSend: primaryChars=\(transcriptSource.count) notesChars=\(notesSource.count) re-enhance=\(existingSummaryLen > 0)")
        if transcriptSource.count > 50_000 {
            GristLog.log("[Enhance] WARNING long source (\(transcriptSource.count) chars) — OllamaClient will truncate/de-dupe for context")
        }
        if !transcriptSource.isEmpty {
            let preview = transcriptSource
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            GristLog.log("[Enhance] primaryPreview: \(preview.prefix(200))…")
        }
        if existingSummaryLen > 0 {
            let sp = m.summary.replacingOccurrences(of: "\n", with: " ")
            GristLog.log("[Enhance] OLD summary (will be replaced, not fed): \(sp.prefix(120))…")
        }

        guard !transcriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = m.isNoteType ? "Write something first" : "No transcript yet"
            GristLog.log("[Enhance] abort: empty primary source")
            return
        }
        if m.transcript.hasPrefix("[Error") && m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Transcription failed — fix capture/Whisper, then re-record"
            GristLog.log("[Enhance] abort: transcript error and empty notes")
            return
        }

        let model = selectedModel == "custom" ? customModelName : selectedModel
        guard !model.isEmpty else {
            statusMessage = "Enter model name"
            GristLog.log("[Enhance] abort: empty model name")
            return
        }

        statusMessage = "Enhancing…"
        // Notes: use a readable summary style even if template is the type marker "Note"
        let templateName = (m.template == "Note" || m.template.isEmpty) ? "Standard Summary" : m.template
        let customPrompt = customTemplates.first(where: { $0.name == m.template || $0.name == templateName })?.prompt
        let applyTitle = m.isPlaceholderTitle
        let meetingId = m.id
        GristLog.log("[Enhance] calling Ollama template=\(templateName) customPrompt=\(customPrompt != nil) applyTitle=\(applyTitle)")

        Task {
            let t0 = Date()
            do {
                // Single model call: TITLE: … + markdown summary from original content
                let result = try await ollama.enhance(
                    transcript: transcriptSource,
                    notes: notesSource,
                    template: templateName,
                    customPrompt: customPrompt,
                    model: model
                )
                let elapsed = Date().timeIntervalSince(t0)
                await MainActor.run {
                    // Reassign whole struct so SwiftUI + DB both see the new summary
                    guard var updated = selectedMeeting, updated.id == meetingId else {
                        // Selection changed mid-flight — still persist by id
                        if var m2 = db.getMeeting(id: meetingId) {
                            m2.summary = result.summary
                            if applyTitle, let title = result.title, !title.isEmpty, m2.isPlaceholderTitle {
                                m2.title = title
                            }
                            db.saveMeeting(m2)
                            RAGEngine.shared.indexMeetingNow(m2)
                            GristLog.log("[Enhance] done (selection changed) id=\(meetingId) \(String(format: "%.1f", elapsed))s summaryChars=\(result.summary.count)")
                        }
                        statusMessage = "Done"
                        return
                    }
                    let oldSummaryChars = updated.summary.count
                    updated.summary = result.summary
                    if applyTitle, let title = result.title, !title.isEmpty, updated.isPlaceholderTitle {
                        updated.title = title
                    }
                    selectedMeeting = updated
                    saveMeeting()
                    RAGEngine.shared.indexMeetingNow(updated)
                    if autoExtractTasks {
                        extractTasks(from: updated)
                    }
                    // Optional: push Markdown into Obsidian vault after Enhance
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
                    selectedTab = "summary"
                    GristLog.log("[Enhance] done id=\(meetingId) \(String(format: "%.1f", elapsed))s model=\(model)")
                    GristLog.log("[Enhance] summaryChars \(oldSummaryChars) → \(result.summary.count) title=\(result.title ?? "(none)")")
                    let sumPreview = result.summary.replacingOccurrences(of: "\n", with: " ")
                    GristLog.log("[Enhance] summaryPreview: \(sumPreview.prefix(160))…")
                }
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                GristLog.log("[Enhance] FAILED after \(String(format: "%.1f", elapsed))s model=\(model): \(error.localizedDescription)")
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
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

                    var updated = m
                    var parts: [String] = []

                    if needsTitle, let t = result.title, !t.isEmpty {
                        updated.title = t
                        parts.append("titled “\(t)”")
                    }
                    if needsFolder, let f = result.folder, !f.isEmpty {
                        updated.groupName = f
                        await MainActor.run { db.saveFolder(f) }
                        parts.append("filed in “\(f)”")
                    }

                    if parts.isEmpty {
                        lines.append("• \(oldTitle) — no change (AI returned KEEP/NONE)")
                    } else {
                        await MainActor.run {
                            db.saveMeeting(updated)
                        }
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
                    if !title.isEmpty {
                        selectedMeeting?.title = title
                        saveMeeting()
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
