import SwiftUI
import EventKit

@MainActor final class UpcomingMeetings: ObservableObject {
    static let shared = UpcomingMeetings()
    private let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var status = "Connect Calendar to show upcoming meetings."
    var enabled: Bool { UserDefaults.standard.bool(forKey: "showCalendarEvents") }

    func connect() async {
        do {
            if try await store.requestFullAccessToEvents() {
                UserDefaults.standard.set(true, forKey: "showCalendarEvents")
                refresh()
            } else { status = "Calendar access was not granted. You can change it in System Settings → Privacy & Security → Calendars." }
        } catch { status = error.localizedDescription }
    }
    func disconnect() {
        UserDefaults.standard.set(false, forKey: "showCalendarEvents")
        events = []; status = "Calendar disconnected."
        TodayWidgetSnapshot.publish(database: Database.shared)
    }
    func refresh() {
        guard enabled else { events = []; return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            status = "Calendar access is unavailable. Enable it in System Settings → Privacy & Security → Calendars."
            return
        }
        let now = Date(), end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        status = events.isEmpty ? "No upcoming events in the next 7 days." : "Upcoming events from your Mac’s calendars."
        TodayWidgetSnapshot.publish(database: Database.shared)
    }
}

struct UpcomingMeetingsView: View {
    @ObservedObject private var calendar = UpcomingMeetings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Upcoming meetings", systemImage: "calendar").font(.headline)
                Spacer()
                if calendar.enabled { Button("Refresh") { calendar.refresh() } }
                else { Button("Connect Calendar") { Task { await calendar.connect() } } }
            }
            Text(calendar.status).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(calendar.events.prefix(8).enumerated()), id: \.offset) { _, event in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title ?? "Untitled meeting")
                        Text(event.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = event.url, ["https", "http"].contains(url.scheme ?? "") { Link("Open", destination: url) }
                }
            }
        }.onAppear { calendar.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in calendar.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in calendar.refresh() }
    }
}

struct SearchDataSettings: View {
    @ObservedObject private var calendar = UpcomingMeetings.shared
    @State private var busy = false
    @State private var status = ""
    @State private var count = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox("Search index") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(count) passages indexed. Search uses keywords when embeddings are unavailable.")
                        Text("New notes are indexed automatically. Rebuild after changing your embedding model.").font(.caption).foregroundStyle(.secondary)
                        Button(busy ? "Rebuilding…" : "Rebuild index") {
                            busy = true
                            Task {
                                let result = await RAGEngine.shared.reindexAll(meetings: Database.shared.fetchActiveMeetings())
                                count = result.chunks; status = result.error ?? "Index rebuilt"; busy = false
                            }
                        }.disabled(busy)
                        if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Calendar") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show events from calendars configured on this Mac. Quern reads events and does not modify them.")
                        Text(calendar.status).font(.caption).foregroundStyle(.secondary)
                        if calendar.enabled { Button("Disconnect Calendar") { calendar.disconnect() } }
                        else { Button("Connect Calendar") { Task { await calendar.connect() } } }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }.onAppear { count = Database.shared.chunkCount(); calendar.refresh() }
    }
}
