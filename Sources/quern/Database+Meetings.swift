import Foundation
import SQLite3

extension Database {
    func saveMeeting(_ meeting: Meeting) {
        let insertStatementString = """
        INSERT OR REPLACE INTO meetings (id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement, 1, (meeting.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 2, (meeting.title as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStatement, 3, meeting.timestamp)
            sqlite3_bind_text(insertStatement, 4, (meeting.manualNotes as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 5, (meeting.transcript as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 6, (meeting.summary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 7, (meeting.template as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 8, ((meeting.groupName ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insertStatement, 9, meeting.isDeleted ? 1 : 0)
            sqlite3_bind_int(insertStatement, 10, Int32(meeting.durationSeconds))
            
            if sqlite3_step(insertStatement) != SQLITE_DONE {
                print("Could not insert/replace meeting row.")
            }
        }
        sqlite3_finalize(insertStatement)
    }
    
    func softDeleteMeeting(id: String) {
        let query = "UPDATE meetings SET is_deleted = 1 WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Drop RAG chunks so Ask everything doesn’t surface deleted items.
        deleteChunks(forMeetingId: id)
    }
    
    func getMeeting(id: String) -> Meeting? {
        let queryStatementString = "SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, COALESCE(duration_seconds, 0) FROM meetings WHERE id = ?;"
        var queryStatement: OpaquePointer?
        var meeting: Meeting? = nil
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(queryStatement, 1, (id as NSString).utf8String, -1, nil)
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                meeting = meetingFromRow(queryStatement)
            }
        }
        sqlite3_finalize(queryStatement)
        return meeting
    }
    
    func fetchActiveMeetings() -> [Meeting] {
        let queryStatementString = "SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, COALESCE(duration_seconds, 0) FROM meetings WHERE is_deleted = 0 ORDER BY timestamp DESC;"
        var queryStatement: OpaquePointer?
        var meetings: [Meeting] = []
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                if let meeting = meetingFromRow(queryStatement) {
                    meetings.append(meeting)
                }
            }
        }
        sqlite3_finalize(queryStatement)
        return meetings
    }

    private func meetingFromRow(_ queryStatement: OpaquePointer?) -> Meeting? {
        guard let queryStatement else { return nil }
        let id = String(cString: sqlite3_column_text(queryStatement, 0))
        let title = String(cString: sqlite3_column_text(queryStatement, 1))
        let timestamp = sqlite3_column_double(queryStatement, 2)
        let manualNotes = sqlite3_column_text(queryStatement, 3) != nil ? String(cString: sqlite3_column_text(queryStatement, 3)) : ""
        let transcript = sqlite3_column_text(queryStatement, 4) != nil ? String(cString: sqlite3_column_text(queryStatement, 4)) : ""
        let summary = sqlite3_column_text(queryStatement, 5) != nil ? String(cString: sqlite3_column_text(queryStatement, 5)) : ""
        let template = sqlite3_column_text(queryStatement, 6) != nil ? String(cString: sqlite3_column_text(queryStatement, 6)) : ""
        let groupName = sqlite3_column_text(queryStatement, 7) != nil ? String(cString: sqlite3_column_text(queryStatement, 7)) : ""
        let isDeleted = sqlite3_column_int(queryStatement, 8) == 1
        let durationSeconds = Int(sqlite3_column_int(queryStatement, 9))
        return Meeting(
            id: id,
            title: title,
            timestamp: timestamp,
            manualNotes: manualNotes,
            transcript: transcript,
            summary: summary,
            template: template,
            groupName: groupName.isEmpty ? nil : groupName,
            isDeleted: isDeleted,
            durationSeconds: durationSeconds
        )
    }
}
