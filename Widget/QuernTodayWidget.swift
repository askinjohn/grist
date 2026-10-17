import SwiftUI
import WidgetKit

private struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: TodayWidgetSnapshot?
}

private struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: .now, snapshot: TodayWidgetSnapshot.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let next = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [TodayEntry(date: .now, snapshot: TodayWidgetSnapshot.read())], policy: .after(next)))
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Quern Today", systemImage: "sun.max.fill")
                    .font(.headline).foregroundStyle(.purple)
                Spacer()
                Text(Date.now, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = entry.snapshot {
                if !Calendar.current.isDateInToday(snapshot.updatedAt) {
                    Text("Open Quern to refresh today’s activity")
                        .font(.caption2).foregroundStyle(.orange)
                }
                HStack(spacing: 14) {
                    metric("\(snapshot.openTaskCount)", "tasks", icon: "checklist", url: "quern://tasks")
                    metric("\(snapshot.scheduledMeetings.isEmpty ? snapshot.todayMeetingCount : snapshot.scheduledMeetings.count)", snapshot.scheduledMeetings.isEmpty ? "recorded" : "upcoming", icon: "video", url: "quern://today")
                    metric("\(snapshot.todayNoteCount)", "notes", icon: "note.text", url: "quern://today")
                }
                if !snapshot.tasks.isEmpty {
                    ForEach(snapshot.tasks.prefix(family == .systemSmall ? 1 : family == .systemMedium ? 2 : 3)) { task in
                        Link(destination: URL(string: "quern://task/\(task.id)")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "circle").foregroundStyle(.purple)
                                Text(task.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if task.subtitle == "Overdue" { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                            }.font(.caption)
                        }
                    }
                } else {
                    Text("No open tasks").font(.caption).foregroundStyle(.secondary)
                }
                if family != .systemSmall, let meeting = snapshot.scheduledMeetings.first {
                    Link(destination: URL(string: "quern://today")!) {
                        Label("\(meeting.subtitle) · \(meeting.title)", systemImage: "calendar").font(.caption).lineLimit(1)
                    }
                }
                if family != .systemSmall, let note = snapshot.recentNotes.first {
                    Link(destination: URL(string: "quern://note/\(note.id)")!) {
                        Label(note.title, systemImage: "note.text").font(.caption).lineLimit(1)
                    }
                }
            } else {
                Text("Open Quern to show today’s tasks and notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .widgetURL(URL(string: "quern://today"))
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private func metric(_ count: String, _ label: String, icon: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 1) {
                Label(count, systemImage: icon).font(.subheadline.weight(.semibold))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

@main struct QuernWidgets: WidgetBundle {
    var body: some Widget { QuernToday() }
}

private struct QuernToday: Widget {
    let kind = "QuernTodayWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in TodayWidgetView(entry: entry) }
            .configurationDisplayName("Quern Today")
            .description("Tasks, meetings, and recent notes from Quern.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
