import Testing
import SQLite3
@testable import quern

@MainActor
struct TaskEvidenceTests {
    @Test func taskEvidenceSurvivesDatabaseRoundTrip() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        var task = QuernTask.manual(title: "Send proposal")
        task.evidence = "I will send the proposal tomorrow."
        db.saveTask(task)
        #expect(db.fetchTasks().first?.evidence == task.evidence)
    }
}
