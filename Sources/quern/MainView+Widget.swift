import SwiftUI

extension MainView {
    func handleWidgetURL(_ url: URL) {
        guard url.scheme == "quern" else { return }
        searchText = ""
        let id = url.pathComponents.dropFirst().first
        switch url.host {
        case "task":
            loadTasks()
            selectedTask = tasks.first(where: { $0.id == id })
            selectedMeeting = nil
            libraryFilter = .tasks
        case "note", "meeting":
            loadMeetings()
            selectedMeeting = meetings.first(where: { $0.id == id })
            selectedTask = nil
            libraryFilter = .all
        default:
            selectedTask = nil
            selectedMeeting = nil
            libraryFilter = .today
        }
    }
}
