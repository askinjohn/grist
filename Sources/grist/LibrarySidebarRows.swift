import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct TaskSidebarRow: View {
    let task: GristTask
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(task.isDone ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(task.isDone)
                    .lineLimit(2)
                if let src = task.sourceTitle, !src.isEmpty {
                    Text(src)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.purple.opacity(0.12) : Color.clear)
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let meeting: Meeting
    let isSelected: Bool
    var searchQuery: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: meeting.isNoteType ? "note.text" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(meeting.isNoteType ? .blue : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let snippet = matchSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Text(meeting.kindLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(meeting.isNoteType ? .blue : .secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(relativeTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let dur = meeting.formattedDuration {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(dur)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let folder = meeting.groupName, !folder.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if !meeting.summary.isEmpty {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        } else if !meeting.transcript.isEmpty {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                // Export is handled by parent when available; post so MainView can listen — use Notification
                NotificationCenter.default.post(name: .exportMeetingRequested, object: meeting.id)
            } label: {
                Label("Export Markdown…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Database.shared.softDeleteMeeting(id: meeting.id)
                NotificationCenter.default.post(name: .meetingDeleted, object: nil)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Short excerpt around the first search hit (title hits skip snippet).
    private var matchSnippet: String? {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if meeting.title.localizedCaseInsensitiveContains(q) {
            if let folder = meeting.groupName, !folder.isEmpty {
                return "\(meeting.kindLabel) · \(folder)"
            }
            return meeting.kindLabel
        }
        for field in [meeting.summary, meeting.manualNotes, meeting.transcript] {
            if let snip = Self.snippet(in: field, around: q) {
                return snip
            }
        }
        return nil
    }

    private static func snippet(in text: String, around query: String, radius: Int = 42) -> String? {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        return prefix + s + suffix
    }

    var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: meeting.timestamp), relativeTo: Date())
    }
}

// MARK: - Chat View (item / global / selection)

