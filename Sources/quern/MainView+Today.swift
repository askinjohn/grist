import SwiftUI

/// A compact daily dashboard. Its data model is intentionally local and simple so a future widget
/// and view-only companion can render the same tasks and items from a synced snapshot.
extension MainView {
    var todayMeetings: [Meeting] {
        meetings.filter { !$0.isNoteType && Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.timestamp)) }
    }

    var todayNotes: [Meeting] {
        meetings.filter { $0.isNoteType && Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.timestamp)) }
    }

    var todayOpenTasks: [QuernTask] {
        tasks.filter(\.isOpen).sorted { ($0.dueAt ?? .infinity) < ($1.dueAt ?? .infinity) }
    }

    var overdueTasks: [QuernTask] { todayOpenTasks.filter(\.isOverdue) }

    var todayDetailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Today")
                        .font(.largeTitle.weight(.bold))
                    Text(Date.now.formatted(date: .complete, time: .omitted))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    todayMetric(title: "Open tasks", value: todayOpenTasks.count, icon: "checklist", tint: .purple)
                    todayMetric(title: "Meetings", value: todayMeetings.count, icon: "video", tint: .blue)
                    todayMetric(title: "Notes", value: todayNotes.count, icon: "note.text", tint: .orange)
                }

                if !overdueTasks.isEmpty {
                    todaySection("Overdue", icon: "exclamationmark.circle") {
                        ForEach(overdueTasks) { task in
                            todayTaskRow(task)
                        }
                    }
                }

                UpcomingMeetingsView()

                todaySection("Open tasks", icon: "checklist") {
                    if todayOpenTasks.allSatisfy(\.isOverdue) {
                        todayEmpty(todayOpenTasks.isEmpty ? "No open tasks. Extract action items after a meeting or create one by hand." : "Your remaining open tasks are listed under Overdue.")
                    } else {
                        ForEach(todayOpenTasks.filter { !$0.isOverdue }.prefix(8)) { task in
                            todayTaskRow(task)
                        }
                    }
                }

                todaySection("Today’s meetings", icon: "video") {
                    todayItems(todayMeetings, empty: "No meetings recorded today.")
                }

                todaySection("Recent notes", icon: "note.text") {
                    todayItems(Array(meetings.filter(\.isNoteType).sorted { $0.timestamp > $1.timestamp }.prefix(5)), empty: "No notes yet.")
                }
                Button("View all tasks") { libraryFilter = .tasks; selectedTask = nil }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    func todayTaskRow(_ task: QuernTask) -> some View {
        HStack(spacing: 10) {
            Button { toggleTaskDone(task) } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(task.title) done")
            Button {
                searchText = ""
                libraryFilter = .tasks
                selectedTask = task
                selectedMeeting = nil
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).foregroundStyle(task.isOverdue ? Color.red : Color.primary)
                    if let source = task.sourceTitle, !source.isEmpty {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.buttonStyle(.plain)
        }
    }

    func todayMetric(title: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title2.weight(.bold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    func todaySection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(18)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }

    func todayItems(_ items: [Meeting], empty: String) -> some View {
        Group {
            if items.isEmpty {
                todayEmpty(empty)
            } else {
                ForEach(items) { item in
                    Button {
                        libraryFilter = .all
                        selectedMeeting = item
                        selectedTask = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(.primary)
                                Text(item.formattedCreated).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func todayEmpty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
