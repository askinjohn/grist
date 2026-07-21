import Foundation
import AppKit
import UniformTypeIdentifiers

/// User-chosen sections for Markdown export (nothing is forced).
struct ExportOptions: Equatable {
    var includeMetadata: Bool = true
    var includeSources: Bool = true
    var includeSummary: Bool = true
    var includeNotes: Bool = true
    var includeTranscript: Bool = true

    static let `default` = ExportOptions()

    static let summaryOnly = ExportOptions(
        includeMetadata: false,
        includeSources: false,
        includeSummary: true,
        includeNotes: false,
        includeTranscript: false
    )

    static let full = ExportOptions(
        includeMetadata: true,
        includeSources: true,
        includeSummary: true,
        includeNotes: true,
        includeTranscript: true
    )

    /// At least one content section selected.
    var hasContentSelection: Bool {
        includeSummary || includeNotes || includeTranscript || includeSources || includeMetadata
    }

    /// Disable toggles for sections that are empty on this item.
    func availability(for meeting: Meeting) -> ExportAvailability {
        ExportAvailability(
            hasSummary: !meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasNotes: !meeting.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasTranscript: !meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasSources: !NoteExporter.extractURLs(from: meeting.manualNotes).isEmpty
        )
    }

    /// Clamp options so empty sections aren't required (keeps user intent for non-empty ones).
    func resolved(for meeting: Meeting) -> ExportOptions {
        let a = availability(for: meeting)
        var o = self
        if !a.hasSummary { o.includeSummary = false }
        if !a.hasNotes { o.includeNotes = false }
        if !a.hasTranscript { o.includeTranscript = false }
        if !a.hasSources { o.includeSources = false }
        return o
    }
}

struct ExportAvailability: Equatable {
    var hasSummary: Bool
    var hasNotes: Bool
    var hasTranscript: Bool
    var hasSources: Bool
}

/// Build Markdown documents from notes/meetings and write them via save panel or folder export.
enum NoteExporter {

    /// Markdown for one item using the user's section choices.
    static func markdown(for meeting: Meeting, options: ExportOptions = .default) -> String {
        let opts = options.resolved(for: meeting)
        var lines: [String] = []
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : meeting.title
        lines.append("# \(title)")
        lines.append("")

        if opts.includeMetadata {
            lines.append("| | |")
            lines.append("|---|---|")
            lines.append("| Type | \(meeting.kindLabel) |")
            lines.append("| Created | \(meeting.formattedCreated) |")
            if let folder = meeting.groupName, !folder.isEmpty {
                lines.append("| Folder | \(folder) |")
            }
            if let dur = meeting.formattedDuration {
                lines.append("| Duration | \(dur) |")
            }
            lines.append("| Id | `\(meeting.id)` |")
            lines.append("")
        }

        if opts.includeSources {
            let sources = extractURLs(from: meeting.manualNotes)
            if !sources.isEmpty {
                lines.append("## Sources")
                lines.append("")
                for url in sources {
                    lines.append("- \(url)")
                }
                lines.append("")
            }
        }

        if opts.includeSummary {
            let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                lines.append("## Summary")
                lines.append("")
                lines.append(summary)
                lines.append("")
            }
        }

        if opts.includeNotes {
            let notes = meeting.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                lines.append("## Notes")
                lines.append("")
                lines.append(notes)
                lines.append("")
            }
        }

        if opts.includeTranscript {
            let transcript = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                lines.append("## Transcript")
                lines.append("")
                lines.append(transcript)
                lines.append("")
            }
        }

        // If user turned everything off or all selected sections were empty
        if lines.count <= 2 {
            lines.append("*(No content selected for export, or selected sections are empty.)*")
            lines.append("")
        }

        lines.append("---")
        lines.append("*Exported from Grist*")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Combined Markdown for many items (folder export / index).
    static func markdownBundle(meetings: [Meeting], folderTitle: String?, options: ExportOptions = .default) -> String {
        var parts: [String] = []
        let heading = folderTitle.map { "# Folder: \($0)" } ?? "# Grist export"
        parts.append(heading)
        parts.append("")
        parts.append("\(meetings.count) item(s) · \(ISO8601DateFormatter().string(from: Date()))")
        parts.append("")
        let sorted = meetings.sorted { $0.timestamp > $1.timestamp }
        for (i, m) in sorted.enumerated() {
            if i > 0 {
                parts.append("")
                parts.append("---")
                parts.append("")
            }
            let doc = markdown(for: m, options: options)
            if doc.hasPrefix("# ") {
                parts.append("## " + doc.dropFirst(2))
            } else {
                parts.append(doc)
            }
        }
        return parts.joined(separator: "\n")
    }

    static func safeFilename(for meeting: Meeting) -> String {
        var base = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = meeting.isNoteType ? "Note" : "Meeting" }
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        base = base.components(separatedBy: invalid).joined(separator: "-")
        base = base.replacingOccurrences(of: "\n", with: " ")
        if base.count > 80 { base = String(base.prefix(80)) }
        return "\(base).md"
    }

    /// Show save panel for one Markdown file. Returns path written, or nil if cancelled.
    @MainActor
    static func saveMarkdownPanel(defaultName: String, contents: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultName.hasSuffix(".md") ? defaultName : "\(defaultName).md"
        panel.title = "Export Markdown"
        panel.message = "Choose where to save the Markdown file"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Export many items as individual `.md` files into a chosen directory.
    @MainActor
    static func saveFolderPanel(meetings: [Meeting], suggestedName: String, options: ExportOptions = .default) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Export \(meetings.count) Markdown file(s) into a folder"
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }

        let sub = dir.appendingPathComponent(suggestedName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            var used = Set<String>()
            for m in meetings {
                var name = safeFilename(for: m)
                var n = 2
                while used.contains(name) {
                    let stem = name.replacingOccurrences(of: ".md", with: "")
                    name = "\(stem)-\(n).md"
                    n += 1
                }
                used.insert(name)
                let url = sub.appendingPathComponent(name)
                try markdown(for: m, options: options).write(to: url, atomically: true, encoding: .utf8)
            }
            let index = markdownBundle(meetings: meetings, folderTitle: suggestedName, options: options)
            try index.write(to: sub.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)
            return sub
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    static func extractURLs(from notes: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"'`\[\]{}|\\^)]+"#) else {
            return []
        }
        let ns = notes as NSString
        for m in regex.matches(in: notes, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:)]}>\"'".contains(last) { s.removeLast() }
            if seen.insert(s).inserted { found.append(s) }
        }
        return found
    }
}
