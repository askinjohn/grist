import Foundation

/// Action item extracted from a meeting/note or created manually.
struct QuernTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var notes: String
    /// Short verbatim source returned by task extraction. Empty for manual tasks.
    var evidence: String
    /// Source meeting/note id (nil if manual-only).
    var sourceMeetingId: String?
    var sourceTitle: String?
    /// open | done
    var status: String
    var createdAt: Double
    var completedAt: Double?
    var dueAt: Double?
    /// none | low | medium | high
    var priority: String
    var assignee: String = ""
    var isDeleted: Bool

    var isOpen: Bool { status == "open" && !isDeleted }
    var isDone: Bool { status == "done" }

    static func manual(title: String, notes: String = "", source: Meeting? = nil) -> QuernTask {
        QuernTask(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            evidence: "",
            sourceMeetingId: source?.id,
            sourceTitle: source?.title,
            status: "open",
            createdAt: Date().timeIntervalSince1970,
            completedAt: nil,
            dueAt: nil,
            priority: "none",
            isDeleted: false
        )
    }

    static func fromExtract(
        title: String,
        notes: String,
        evidence: String,
        source: Meeting
    ) -> QuernTask {
        QuernTask(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            evidence: evidence,
            sourceMeetingId: source.id,
            sourceTitle: source.title,
            status: "open",
            createdAt: Date().timeIntervalSince1970,
            completedAt: nil,
            dueAt: nil,
            priority: "none",
            isDeleted: false
        )
    }

    var isOverdue: Bool { overdue(at: Date()) }

    func overdue(at now: Date, calendar: Calendar = .current) -> Bool {
        isOpen && (dueAt ?? .infinity) < calendar.startOfDay(for: now).timeIntervalSince1970
    }
}
