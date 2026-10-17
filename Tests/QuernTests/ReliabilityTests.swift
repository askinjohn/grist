import Foundation
import SQLite3
import Testing
@testable import quern

@MainActor
struct ReliabilityTests {
    private func meeting() -> Meeting {
        Meeting(id: UUID().uuidString, title: "Untitled Note", timestamp: 1,
                manualNotes: "original", transcript: "", summary: "", template: "Note")
    }

    @Test func metadataUpdatePreservesNewerEditsAndOtherItems() throws {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        let original = meeting()
        var edited = original
        edited.manualNotes = "Edited while AI was running"
        edited.summary = "New summary"
        let other = meeting()
        #expect(db.saveMeeting(edited))
        #expect(db.saveMeeting(other))
        let result = try #require(db.modifyMeeting(id: original.id) { $0.title = "AI title" })
        #expect(result.manualNotes == edited.manualNotes)
        #expect(result.summary == edited.summary)
        #expect(db.getMeeting(id: other.id) == other)
    }

    @Test func deletedItemCannotBeRevivedByAI() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        let note = meeting()
        db.saveMeeting(note)
        db.softDeleteMeeting(id: note.id)
        #expect(db.modifyMeeting(id: note.id) { $0.title = "Late AI result" } == nil)
        #expect(db.getMeeting(id: note.id)?.isDeleted == true)
    }

    @Test func indexReplacementRollsBackOnInsertFailure() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        let note = meeting()
        db.saveMeeting(note)
        let old = TranscriptChunk(id: "old", meetingId: note.id, text: "searchable", embedding: [1, 0])
        #expect(db.saveChunk(old))
        #expect(db.execute("CREATE TRIGGER fail_chunk BEFORE INSERT ON chunks WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'test failure'); END;"))
        let replacement = [
            TranscriptChunk(id: "good", meetingId: note.id, text: "new", embedding: [0, 1]),
            TranscriptChunk(id: "bad", meetingId: note.id, text: "fails", embedding: [0, 1])
        ]
        #expect(!db.replaceChunks(replacement, for: note))
        #expect(db.fetchChunks(forMeetingIds: [note.id]).map(\.id) == ["old"])
        #expect(db.execute("DROP TRIGGER fail_chunk;"))
        #expect(db.replaceChunks([replacement[0]], for: note))
        #expect(db.fetchChunks(forMeetingIds: [note.id]).map(\.id) == ["good"])
    }

    @Test func staleIndexCannotReplaceCurrentIndex() {
        let db = Database(path: ":memory:")
        defer { sqlite3_close(db.db) }
        let note = meeting()
        db.saveMeeting(note)
        db.saveChunk(TranscriptChunk(id: "old", meetingId: note.id, text: "searchable", embedding: [1]))
        _ = db.modifyMeeting(id: note.id) { $0.manualNotes = "new content" }
        #expect(!db.replaceChunks([], for: note))
        #expect(db.chunkCount() == 1)
        db.softDeleteMeeting(id: note.id)
        #expect(!db.replaceChunks([TranscriptChunk(id: "late", meetingId: note.id, text: "stale", embedding: [1])], for: note))
        #expect(db.chunkCount() == 0)
    }

    @Test func recordingSessionsPreserveOriginalBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        let first = Data("first recording".utf8)
        try first.write(to: mic)
        try RecordingArchive.preservePreviousSession(in: folder)
        let second = Data("second recording".utf8)
        try second.write(to: mic)
        try RecordingArchive.preservePreviousSession(in: folder)
        let archives = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)
        let contents = try archives.map { try Data(contentsOf: $0.appendingPathComponent("mic.m4a")) }
        #expect(contents.count == 2)
        #expect(contents.contains(first) && contents.contains(second))
        #expect(!FileManager.default.fileExists(atPath: mic.path))
    }

    @Test func archiveFailureKeepsOriginalAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.m4a")
        let audio = Data("precious recording".utf8)
        try audio.write(to: mic)
        try Data().write(to: folder.appendingPathComponent("recordings"))
        #expect(throws: (any Error).self) { try RecordingArchive.preservePreviousSession(in: folder) }
        #expect(try Data(contentsOf: mic) == audio)
    }
}
