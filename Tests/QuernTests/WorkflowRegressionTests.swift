import Foundation
import Testing
import SQLite3
@testable import quern

@MainActor struct WorkflowRegressionTests {
    private func meeting(_ id: String, title: String = "Test", body: String = "", folder: String? = nil, timestamp: Double = 100) -> Meeting {
        Meeting(id: id, title: title, timestamp: timestamp, manualNotes: body, transcript: "", summary: "", template: "Note", groupName: folder)
    }

    @Test func hybridOverlapDoesNotCrashAndConsensusRanksFirst() {
        let a = meeting("a"), b = meeting("b"), c = meeting("c")
        let result = RAGEngine.mergeMeetings(keyword: [a, b], semantic: [b, c], topK: 3)
        #expect(result.map(\.id) == ["b", "a", "c"])
        #expect(EvidenceRanking.fuse([["a", "a"], ["b"]], limit: 3) == ["a", "b"])
        #expect(EvidenceRanking.fuse([["a"]], limit: 0).isEmpty)
    }

    @Test func dateOnlyTaskIsNotOverdueUntilFollowingDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = Date(timeIntervalSince1970: 1790744400)
        var task = QuernTask.manual(title: "Send proposal")
        task.dueAt = calendar.startOfDay(for: now).timeIntervalSince1970
        #expect(!task.overdue(at: now, calendar: calendar))
        #expect(task.overdue(at: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar))
        task.status = "done"
        #expect(!task.overdue(at: now.addingTimeInterval(172800), calendar: calendar))
    }

    @Test func widgetSnapshotExcludesCompletedTasksAndSeparatesToday() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var open = QuernTask.manual(title: "Follow up")
        open.dueAt = calendar.date(byAdding: .day, value: -1, to: now)?.timeIntervalSince1970
        var done = QuernTask.manual(title: "Already done")
        done.status = "done"
        db.saveTask(open)
        db.saveTask(done)
        db.saveMeeting(meeting("note", title: "Today note", timestamp: now.timeIntervalSince1970))
        var recorded = meeting("meeting", title: "Today meeting", timestamp: now.timeIntervalSince1970)
        recorded.template = "Standard Summary"
        db.saveMeeting(recorded)
        db.saveMeeting(meeting("old", title: "Earlier note", timestamp: now.addingTimeInterval(-86400).timeIntervalSince1970))

        let scheduled = [TodayWidgetSnapshot.Row(id: "event", title: "Planning call", subtitle: "10:00 AM")]
        let snapshot = TodayWidgetSnapshot.make(database: db, now: now, calendar: calendar, scheduledMeetings: scheduled)
        #expect(snapshot.openTaskCount == 1)
        #expect(snapshot.overdueCount == 1)
        #expect(snapshot.todayNoteCount == 1)
        #expect(snapshot.todayMeetingCount == 1)
        #expect(snapshot.tasks.map(\.title) == ["Follow up"])
        #expect(snapshot.recentNotes.first?.title == "Today note")
        #expect(snapshot.scheduledMeetings.first?.title == "Planning call")
    }

    @Test func taskPlanningAndCitationsSurviveDatabaseRoundTrip() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        var task = QuernTask.manual(title: "Verify migration")
        task.assignee = "Sam"; task.priority = "high"; task.dueAt = 123456
        db.saveTask(task)
        #expect(db.fetchTasks().first == task)
        let conversation = db.createConversation(scopeKey: "__global__")
        let evidence = AskEvidence(id: "S1", meetingID: "m1", title: "Duplicate title", timestamp: 1, section: "notes", quote: "Exact source text")
        let message = ChatMessage(id: "answer", groupName: "__global__", role: "assistant", content: "Exact source text [S1]", timestamp: 1, conversationId: conversation.id, evidence: [evidence])
        db.saveChatMessage(message)
        #expect(db.fetchChatMessages(conversationId: conversation.id).first?.evidence == [evidence])
    }

    @Test func oldTaskTableMigratesWithoutLosingRows() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: path) }
        var handle: OpaquePointer?
        sqlite3_open(path.path, &handle)
        sqlite3_exec(handle, "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, notes TEXT, source_meeting_id TEXT, source_title TEXT, status TEXT, created_at REAL, completed_at REAL, is_deleted INTEGER); INSERT INTO tasks VALUES ('old','Existing task','',NULL,NULL,'done',1,2,0);", nil, nil, nil)
        sqlite3_close(handle)
        let db = Database(path: path.path)
        defer { sqlite3_close(db.db) }
        let task = db.fetchTasks().first
        #expect(task?.title == "Existing task")
        #expect(task?.status == "done")
        #expect(task?.dueAt == nil)
        #expect(task?.assignee == "")
        #expect(task?.priority == "none")
    }

    @Test func scopeExcludesOtherFoldersOldAndDeletedNotes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = meeting("r", folder: "Work", timestamp: now.timeIntervalSince1970)
        let old = meeting("o", folder: "Work", timestamp: now.addingTimeInterval(-8 * 86400).timeIntervalSince1970)
        let other = meeting("x", folder: "Personal", timestamp: now.timeIntervalSince1970)
        var deleted = recent; deleted.id = "d"; deleted.isDeleted = true
        #expect(EvidenceRanking.scoped([recent, old, other, deleted], folder: "Work", days: 7, now: now).map(\.id) == ["r"])
    }

    @Test func offlineRetrievalFixturesAndUnsupportedQuestion() {
        let sources = [
            AskEvidence(id: "S1", meetingID: "1", title: "Onboarding", timestamp: 1, section: "notes", quote: "The onboarding checklist owner is Sam."),
            AskEvidence(id: "S2", meetingID: "2", title: "Budget", timestamp: 1, section: "notes", quote: "The budget review deadline is Friday."),
            AskEvidence(id: "S3", meetingID: "3", title: "Release", timestamp: 1, section: "transcript", quote: "Release is blocked by validation failures.")
        ]
        for (query, expected) in [("Who owns the onboarding checklist?", "S1"), ("What is the budget deadline?", "S2"), ("Why is release blocked?", "S3")] {
            #expect(EvidenceRanking.lexical(sources, query: query).first?.id == expected)
        }
        #expect(EvidenceRanking.lexical(sources, query: "Mars orbital velocity").isEmpty)
        #expect(EvidenceRanking.unknownCitations("Sam owns it [S1]", evidence: sources).isEmpty)
        #expect(EvidenceRanking.unknownCitations("Someone owns it [S99]", evidence: sources) == ["[S99]"])
    }

    @Test func evidenceIsVerbatimAndParagraphsStayBounded() {
        let item = meeting("id", body: "First line.\nDecision: launch next week.\nThird line.")
        let hit = SearchEvidence.match(item, query: "launch")
        #expect(hit?.section == "notes")
        #expect(item.manualNotes.contains(hit!.quote))
        let chunks = EvidenceRanking.passages(String(repeating: "a", count: 2501))
        #expect(chunks.map(\.count) == [1200, 1200, 101])
        #expect(chunks.joined() == String(repeating: "a", count: 2501))
    }

    @Test func notionLongExportsAreBatchedAndIDsValidated() throws {
        let blocks = NotionBlock.paragraph(text: String(repeating: "x", count: 200_000))
        let batches = NotionExporter.batches(blocks)
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { $0.count <= 50 })
        #expect(batches.flatMap { $0 } == blocks)
        #expect(try NotionExporter.normalizedID("https://www.notion.so/Title-123456781234123412341234567890ab?v=ignored") == "123456781234123412341234567890ab")
        #expect(throws: NotionExportError.self) { try NotionExporter.normalizedID("not an id") }
    }

    @Test func meetTitlePrefillsButMicrophoneFallbackDoesNot() {
        #expect(MeetingDetector.Detection(appName: "Google Meet", detail: "Planning - Meet - Google Chrome").suggestedTitle == "Planning")
        #expect(MeetingDetector.Detection(appName: "Google Chrome", detail: "Browser microphone", requiresConfirmation: true).suggestedTitle == nil)
    }
}
