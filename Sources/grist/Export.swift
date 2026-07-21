import Foundation
import AppKit
import UniformTypeIdentifiers

/// Build Markdown documents from notes/meetings and write them via save panel or folder export.
enum NoteExporter {

    /// Full Markdown for one item (title, metadata, summary, notes, transcript).
    static func markdown(for meeting: Meeting) -> String {
        var lines: [String] = []
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : meeting.title
        lines.append("# \(title)")
        lines.append("")
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

        let sources = extractURLs(from: meeting.manualNotes)
        if !sources.isEmpty {
            lines.append("## Sources")
            lines.append("")
            for url in sources {
                lines.append("- \(url)")
            }
            lines.append("")
        }

        let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        let notes = meeting.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        let transcript = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            lines.append(transcript)
            lines.append("")
        }

        lines.append("---")
        lines.append("*Exported from Grist*")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Combined Markdown for many items (folder export / index).
    static func markdownBundle(meetings: [Meeting], folderTitle: String?) -> String {
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
            let doc = markdown(for: m)
            // Downgrade only the document H1 so the bundle keeps a single top title
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
    static func saveFolderPanel(meetings: [Meeting], suggestedName: String) -> URL? {
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
                try markdown(for: m).write(to: url, atomically: true, encoding: .utf8)
            }
            // Index
            let index = markdownBundle(meetings: meetings, folderTitle: suggestedName)
            try index.write(to: sub.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)
            return sub
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    private static func extractURLs(from notes: String) -> [String] {
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
