import Foundation

/// Action item extracted from a meeting/note or created manually.
struct GristTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var notes: String
    /// Source meeting/note id (nil if manual-only).
    var sourceMeetingId: String?
    var sourceTitle: String?
    /// open | done
    var status: String
    var createdAt: Double
    var completedAt: Double?
    var isDeleted: Bool

    var isOpen: Bool { status == "open" && !isDeleted }
    var isDone: Bool { status == "done" }

    static func manual(title: String, notes: String = "") -> GristTask {
        GristTask(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            sourceMeetingId: nil,
            sourceTitle: nil,
            status: "open",
            createdAt: Date().timeIntervalSince1970,
            completedAt: nil,
            isDeleted: false
        )
    }

    static func fromExtract(
        title: String,
        notes: String,
        source: Meeting
    ) -> GristTask {
        GristTask(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            sourceMeetingId: source.id,
            sourceTitle: source.title,
            status: "open",
            createdAt: Date().timeIntervalSince1970,
            completedAt: nil,
            isDeleted: false
        )
    }
}
