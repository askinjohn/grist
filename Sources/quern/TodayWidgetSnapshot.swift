import Foundation
import Security

struct TodayWidgetSnapshot: Codable {
    struct Row: Codable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }

    let updatedAt: Date
    let openTaskCount: Int
    let overdueCount: Int
    let todayMeetingCount: Int
    let todayNoteCount: Int
    let tasks: [Row]
    let scheduledMeetings: [Row]
    let recentNotes: [Row]

    static var appGroup: String {
        // Both targets use the group from their locally generated signature.
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first(where: { $0.hasSuffix("com.quern.meetingassistant") }) else {
            return "group.com.quern.meetingassistant"
        }
        return group
    }
    static let fileName = "today-widget.json"

    static func read() -> TodayWidgetSnapshot? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

}
