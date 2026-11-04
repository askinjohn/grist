import Foundation
import WidgetKit

extension TodayWidgetSnapshot {
    @MainActor static func make(database: Database, now: Date = .now, calendar: Calendar = .current, scheduledMeetings: [Row] = []) -> TodayWidgetSnapshot {
        let items = database.fetchActiveMeetings()
        let open = database.fetchTasks(includeDone: false)
            .filter(\.isOpen)
            .sorted { ($0.dueAt ?? .infinity) < ($1.dueAt ?? .infinity) }
        let today = items.filter { calendar.isDate(Date(timeIntervalSince1970: $0.timestamp), inSameDayAs: now) }
        return TodayWidgetSnapshot(
            updatedAt: now,
            openTaskCount: open.count,
            overdueCount: open.filter { $0.overdue(at: now, calendar: calendar) }.count,
            todayMeetingCount: today.filter { !$0.isNoteType }.count,
            todayNoteCount: today.filter(\.isNoteType).count,
            tasks: Array(open.prefix(4).map { Row(id: $0.id, title: $0.title, subtitle: $0.isOverdue ? "Overdue" : ($0.dueAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "Task")) }),
            scheduledMeetings: scheduledMeetings,
            recentNotes: Array(items.filter(\.isNoteType).prefix(2).map { Row(id: $0.id, title: $0.title, subtitle: "Note") })
        )
    }

    @MainActor static func publish(database: Database) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let now = Date()
        let scheduled = UpcomingMeetings.shared.events
            .filter { Calendar.current.isDate($0.startDate, inSameDayAs: now) && $0.endDate > now }
            .map { Row(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Meeting", subtitle: $0.startDate.formatted(date: .omitted, time: .shortened)) }
        let snapshot = make(database: database, now: now, scheduledMeetings: scheduled)
        do {
            try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent(fileName), options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "QuernTodayWidget")
        } catch {
            NSLog("Quern widget snapshot failed: %@", error.localizedDescription)
        }
    }
}
