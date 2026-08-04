import SwiftUI
import AppKit

// MARK: - Data Model

struct Meeting: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var timestamp: Double
    var manualNotes: String
    var transcript: String
    var summary: String
    var template: String
    var groupName: String? = nil
    var isDeleted: Bool = false
    /// Recorded audio length in seconds (0 if unknown / note-only).
    var durationSeconds: Int = 0

    /// Notes created via the Note flow use template `"Note"`.
    var isNoteType: Bool { template == "Note" }

    var kindLabel: String { isNoteType ? "Note" : "Meeting" }

    /// Default titles we may safely replace with an AI title.
    var isPlaceholderTitle: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("Untitled ") { return true }
        if t.hasPrefix("Meeting ") { return true }
        if t.hasPrefix("Note ") { return true }
        return false
    }

    var formattedCreated: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: timestamp))
    }

    var formattedDuration: String? {
        guard durationSeconds > 0 else { return nil }
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        if m >= 60 {
            return String(format: "%dh %02dm", m / 60, m % 60)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct MeetingGroup: Identifiable {
    var id: String { name }
    let name: String
    let meetings: [Meeting]
}

/// What the user is creating from the Create sheet.
enum CreateKind: String, CaseIterable, Identifiable, Hashable {
    case meeting
    case note
    case article

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .article: return "Article"
        }
    }

    var subtitle: String {
        switch self {
        case .meeting: return "Record mic + system audio, then AI summary"
        case .note: return "Write freely — no recording required"
        case .article: return "Paste one or more URLs — pages or YouTube"
        }
    }

    var icon: String {
        switch self {
        case .meeting: return "waveform.circle.fill"
        case .note: return "note.text"
        case .article: return "link.circle.fill"
        }
    }

    var accent: Color {
        switch self {
        case .meeting: return .red
        case .note: return .blue
        case .article: return .orange
        }
    }
}

/// Sheet presentation token so the create UI always opens with the correct kind.
struct CreateSheetRequest: Identifiable, Hashable {
    let id: UUID
    let kind: CreateKind

    init(kind: CreateKind) {
        self.id = UUID()
        self.kind = kind
    }
}

/// Result handed back from the create sheet (kind is explicit — never inferred from parent state).
struct CreateItemPayload {
    let kind: CreateKind
    let title: String
    let folderName: String?
    let template: String
    let model: String
    let autoStartRecording: Bool
    /// Used when kind == .article
    let articleURL: String?
}

/// Sidebar library scope (fills the lower-left with real navigation).
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case unfiled
    case meetings
    case notes
    case tasks
    case askEverything

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .unfiled: return "Unfiled"
        case .meetings: return "Meetings"
        case .notes: return "Notes"
        case .tasks: return "Tasks"
        case .askEverything: return "Ask everything"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .unfiled: return "tray"
        case .meetings: return "waveform"
        case .notes: return "note.text"
        case .tasks: return "checklist"
        case .askEverything: return "sparkles.rectangle.stack"
        }
    }
}

/// Presets for “Summarize folder” — user can also type free-form specs.
enum FolderSummarizePreset: String, CaseIterable, Identifiable {
    case actionItems
    case executive
    case themes
    case research
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actionItems: return "Action items & decisions"
        case .executive: return "Executive brief"
        case .themes: return "Themes & insights"
        case .research: return "Research synthesis"
        case .custom: return "Custom instructions"
        }
    }

    var defaultSpecs: String {
        switch self {
        case .actionItems:
            return """
            Produce:
            1) Key decisions (if any)
            2) Concrete action items (bullet list; owner/deadline when mentioned)
            3) Open questions / risks
            4) One-paragraph overview of the folder
            """
        case .executive:
            return """
            Write a short executive brief for a busy reader:
            - Bottom line up front (3–5 sentences)
            - Why it matters
            - Main takeaways (bullets)
            - Recommended next steps
            """
        case .themes:
            return """
            Cluster content into themes across all items. For each theme: summary, supporting points with source titles, contradictions if any.
            End with overall insights.
            """
        case .research:
            return """
            Research synthesis: claims vs evidence, key facts, sources cited by item title, gaps, and suggested follow-up reading/questions.
            """
        case .custom:
            return ""
        }
    }
}

// MARK: - Root View (Handles Sheet + Keyboard)

